import AVFoundation
import os

enum SimulreceiveMode: Codable, CaseIterable, Identifiable {
    case none
    case visualizeOnly
    case enable
    var id: Self { self }
}

struct AvailableImage {
    let image: CMSampleBuffer
    let fps: UInt
    let discontinous: Bool
}

// swiftlint:disable type_body_length
class VideoSubscription: Subscription {
    private static let logger = DecimusLogger(VideoSubscription.self)

    private let subscription: ManifestSubscription
    private let participants: VideoParticipants
    private let submitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private let granularMetrics: Bool
    private let jitterBufferConfig: VideoJitterBuffer.Config
    private var renderTask: Task<(), Never>?
    private let simulreceive: SimulreceiveMode
    private var lastTime: CMTime?
    private var qualityMisses = 0
    private var last: FullTrackName?
    private var lastImage: AvailableImage?
    private let qualityMissThreshold: Int
    private var cleanupTask: Task<(), Never>?
    private var lastUpdateTimes: [FullTrackName: Date] = [:]
    private var handlerLock = OSAllocatedUnfairLock()
    private let profiles: [FullTrackName: VideoCodecConfig]
    private let cleanupTimer: TimeInterval = 1.5
    private var pauseMissCounts: [FullTrackName: Int] = [:]
    private let pauseMissThreshold: Int
    private let pauseResume: Bool
    private var lastSimulreceiveLabel: String?
    private var lastHighlight: FullTrackName?
    private var lastDiscontinous = false
    private let measurement: MeasurementRegistration<VideoSubscriptionMeasurement>?
    private let variances: VarianceCalculator
    private let decodedVariances: VarianceCalculator
    private var formats: [FullTrackName: CMFormatDescription?] = [:]
    private var timestampTimeDiff: TimeInterval?
    private var videoHandlers: [FullTrackName: VideoHandler] = [:]

    private let callback: ObjectReceived = { handler, timestamp, when, userData in
        let subscription = Unmanaged<VideoSubscription>.fromOpaque(userData).takeUnretainedValue()
        subscription.receivedObject(handler: handler, timestamp: timestamp, when: when)
    }

    init(subscription: ManifestSubscription,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         qualityMissThreshold: Int,
         pauseMissThreshold: Int,
         pauseResume: Bool) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.subscription = subscription
        self.participants = participants
        self.submitter = metricsSubmitter
        if let submitter = metricsSubmitter {
            let measurement = VideoSubscriptionMeasurement(source: self.subscription.sourceID)
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.videoBehaviour = videoBehaviour
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.qualityMissThreshold = qualityMissThreshold
        self.pauseMissThreshold = pauseMissThreshold
        self.pauseResume = pauseResume
        let profiles = subscription.profileSet.profiles
        self.variances = try .init(expectedOccurrences: profiles.count,
                                   submitter: self.granularMetrics ? metricsSubmitter : nil,
                                   source: subscription.sourceID,
                                   stage: "SubscribedObject")
        self.decodedVariances = try .init(expectedOccurrences: profiles.count,
                                          submitter: self.granularMetrics ? metricsSubmitter : nil,
                                          source: subscription.sourceID,
                                          stage: "Decoded")

        // Adjust and store expected quality profiles.
        var createdProfiles: [FullTrackName: VideoCodecConfig] = [:]
        for profile in profiles {
            let config = CodecFactory.makeCodecConfig(from: profile.qualityProfile,
                                                      bitrateType: .average)
            guard let config = config as? VideoCodecConfig else {
                throw "Codec mismatch"
            }
            let fullTrackName = try FullTrackName(namespace: profile.namespace, name: "")
            createdProfiles[fullTrackName] = config
        }

        // Make all the video handlers upfront.
        self.profiles = createdProfiles
        for fullTrackName in createdProfiles.keys {
            self.formats[fullTrackName] = nil
            self.videoHandlers[fullTrackName] = try makeHandler(fullTrackName: fullTrackName)
        }

        // TODO: With MoQ, do we still need this cleanup?
        // TODO: I think the answer is effectively no, because we cannot know to
        // TODO: recreate it. The handler itself should hide its video when we don't get
        // TODO: anything.
        // TODO: This is a change. State in the handler cannot be reused for a new incoming subscription with the same namespace.
        // TODO: Our current approach of reusing the names won't work on receiving new subscribed objects on existing handlers.
        // Make task for cleaning up video handlers.
        self.cleanupTask = .init(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                self.handlerLock.withLock {
                    // Remove any expired handlers.
                    for handler in self.lastUpdateTimes where Date.now.timeIntervalSince(handler.value) >= self.cleanupTimer {
                        self.lastUpdateTimes.removeValue(forKey: handler.key)
                        if let video = self.videoHandlers.removeValue(forKey: handler.key),
                           let last = self.last,
                           video.fullTrackName == last {
                            self.last = nil
                            self.lastImage = nil
                        }
                    }

                    // If there are no handlers left and we're simulreceive, we should remove our video render.
                    if self.videoHandlers.isEmpty && self.simulreceive == .enable {
                        self.participants.removeParticipant(identifier: self.subscription.sourceID)
                    }
                }
                try? await Task.sleep(for: .seconds(self.cleanupTimer),
                                      tolerance: .seconds(self.cleanupTimer),
                                      clock: .continuous)
            }
        }

        Self.logger.info("Subscribed to video stream")
    }

    deinit {
        if self.simulreceive == .enable {
            self.participants.removeParticipant(identifier: self.subscription.sourceID)
        }
    }

    func getHandlers() -> [QSubscribeTrackHandlerObjC] {
        var handlers: [QSubscribeTrackHandlerObjC] = []
        for handler in self.videoHandlers {
            handlers.append(handler.value)
        }
        return handlers
    }

    func receivedObject(handler: VideoHandler, timestamp: TimeInterval, when: Date) {
        // Set the timestamp diff from the first recveived object will set the time diff.
        if self.timestampTimeDiff == nil {
            self.timestampTimeDiff = when.timeIntervalSince1970 - timestamp
        }

        // Calculate switching set arrival variance.
        _ = self.variances.calculateSetVariance(timestamp: timestamp, now: when)
        if self.granularMetrics,
           let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.reportTimestamp(namespace: try handler.fullTrackName.getNamespace(),
                                                              timestamp: timestamp,
                                                              at: when)
            }
        }

        // If we're responsible for rendering, start the task.
        if self.simulreceive != .none && (self.renderTask == nil || self.renderTask!.isCancelled) {
            startRenderTask()
        }

        // Record the last time this updated.
        self.lastUpdateTimes[handler.fullTrackName] = when

        // Timestamp diff.
        if let diff = self.timestampTimeDiff {
            handler.setTimeDiff(diff: diff)
        }
    }

    private func startRenderTask() {
        self.renderTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let now = Date.now
                let duration = self.handlerLock.withLock {
                    guard !self.videoHandlers.isEmpty else {
                        self.renderTask?.cancel()
                        return TimeInterval.nan
                    }
                    do {
                        return try self.makeSimulreceiveDecision(at: now)
                    } catch {
                        Self.logger.error("Simulreceive failure: \(error.localizedDescription)")
                        self.renderTask?.cancel()
                        return TimeInterval.nan
                    }
                }
                if duration > 0 {
                    try? await Task.sleep(for: .seconds(duration))
                }
            }
        }
    }

    private func makeHandler(fullTrackName: FullTrackName) throws -> VideoHandler {
        guard let config = self.profiles[fullTrackName] else {
            throw "Missing config for: \(fullTrackName)"
        }
        let refToSelf = Unmanaged.passUnretained(self).toOpaque()
        return try .init(fullTrackName: fullTrackName,
                         config: config,
                         participants: self.participants,
                         metricsSubmitter: self.submitter,
                         videoBehaviour: self.videoBehaviour,
                         reliable: self.reliable,
                         granularMetrics: self.granularMetrics,
                         jitterBufferConfig: self.jitterBufferConfig,
                         simulreceive: self.simulreceive,
                         variances: self.decodedVariances,
                         callback: self.callback,
                         userData: refToSelf)
    }

    struct SimulreceiveItem: Equatable {
        static func == (lhs: VideoSubscription.SimulreceiveItem, rhs: VideoSubscription.SimulreceiveItem) -> Bool {
            lhs.fullTrackName == rhs.fullTrackName
        }
        let fullTrackName: FullTrackName
        let image: AvailableImage
    }

    enum SimulreceiveReason {
        case onlyChoice(item: SimulreceiveItem)
        case highestRes(item: SimulreceiveItem, pristine: Bool)
    }

    internal static func makeSimulreceiveDecision(choices: inout any Collection<SimulreceiveItem>) -> SimulreceiveReason? {
        // Early return.
        guard choices.count > 1 else {
            if let first = choices.first {
                return .onlyChoice(item: first)
            }
            return nil
        }

        // Oldest should be the oldest value that hasn't already been shown.
        let oldest: CMTime = choices.reduce(CMTime.positiveInfinity) { min($0, $1.image.image.presentationTimeStamp) }

        // Filter out any frames that don't match the desired point in time.
        choices = choices.filter { $0.image.image.presentationTimeStamp == oldest }

        // We want the highest non-discontinous frame.
        // If all are non-discontinous, we'll take the highest quality.
        let sorted = choices.sorted { $0.image.image.formatDescription!.dimensions.width > $1.image.image.formatDescription!.dimensions.width }
        let pristine = sorted.filter { !$0.image.discontinous }
        if let pristine = pristine.first {
            return .highestRes(item: pristine, pristine: true)
        } else if let sorted = sorted.first {
            return .highestRes(item: sorted, pristine: false)
        } else {
            return nil
        }
    }

    // Caller must lock handlerLock.
    // swiftlint:disable cyclomatic_complexity
    // swiftlint:disable function_body_length
    private func makeSimulreceiveDecision(at: Date) throws -> TimeInterval {
        guard !self.videoHandlers.isEmpty else {
            throw "No handlers"
        }

        // Gather up what frames we have to choose from.
        var initialChoices: [SimulreceiveItem] = []
        for handler in self.videoHandlers {
            handler.value.lastDecodedImageLock.lock()
            defer { handler.value.lastDecodedImageLock.unlock() }
            if let available = handler.value.lastDecodedImage {
                if let lastTime = self.lastImage?.image.presentationTimeStamp,
                   available.image.presentationTimeStamp <= lastTime {
                    // This would be backwards in time, so we'll never use it.
                    handler.value.lastDecodedImage = nil
                    continue
                }
                initialChoices.append(.init(fullTrackName: handler.key, image: available))
            }
        }

        // Make a decision about which frame to use.
        var choices = initialChoices as any Collection<SimulreceiveItem>
        let decisionTime = self.measurement == nil ? nil : at
        let decision = Self.makeSimulreceiveDecision(choices: &choices)

        guard let decision = decision else {
            // Wait for next.
            let duration: TimeInterval
            if let lastNamespace = self.last,
               let handler = self.videoHandlers[lastNamespace] {
                duration = handler.calculateWaitTime(from: at) ?? (1 / Double(handler.config.fps))
            } else {
                let highestFps = self.videoHandlers.values.reduce(0) { max($0, $1.config.fps) }
                duration = TimeInterval(1 / highestFps)
            }
            return duration
        }

        // Consume all images from our shortlist.
        for choice in choices {
            let handler = self.videoHandlers[choice.fullTrackName]!
            handler.lastDecodedImageLock.withLock {
                let theirTime = handler.lastDecodedImage?.image.presentationTimeStamp
                let ourTime = choice.image.image.presentationTimeStamp
                if theirTime == ourTime {
                    handler.lastDecodedImage = nil
                }
            }
        }

        let selected: SimulreceiveItem
        switch decision {
        case .highestRes(let out, _):
            selected = out
        case .onlyChoice(let out):
            selected = out
        }
        let selectedSample = selected.image.image

        // If we are going down in quality (resolution or to a discontinous image)
        // we will only do so after a few hits.
        let incomingWidth = selectedSample.formatDescription!.dimensions.width
        var wouldStepDown = false
        if let last = self.lastImage,
           incomingWidth < last.image.formatDescription!.dimensions.width || selected.image.discontinous && !last.discontinous {
            wouldStepDown = true
        }

        if wouldStepDown {
            self.qualityMisses += 1
        }

        // We want to record misses for qualities we have already stepped down from, and pause them
        // if they exceed this count.
        if self.pauseResume {
            fatalError("Not supported")
//            for pauseCandidateCount in self.pauseMissCounts {
//                guard let pauseCandidate = self.videoHandlers[pauseCandidateCount.key],
//                      pauseCandidate.config.width > incomingWidth,
//                      let callController = self.callController,
//                      callController.getSubscriptionState(pauseCandidate.namespace) == .ready else {
//                    continue
//                }
//
//                let newValue = pauseCandidateCount.value + 1
//                Self.logger.warning("Incremented pause count for: \(pauseCandidate.config.width), now: \(newValue)/\(self.pauseMissThreshold)")
//                if newValue >= self.pauseMissThreshold {
//                    // Pause this subscription.
//                    Self.logger.warning("Pausing subscription: \(pauseCandidate.config.width)")
//                    callController.setSubscriptionState(pauseCandidate.namespace, transportMode: .pause)
//                    self.pauseMissCounts[pauseCandidate.namespace] = 0
//                } else {
//                    // Increment the pause miss count.
//                    self.pauseMissCounts[pauseCandidate.namespace] = newValue
//                }
//            }
        }

        guard let handler = self.videoHandlers[selected.fullTrackName] else {
            throw "Missing expected handler for namespace: \(selected.fullTrackName)"
        }

        let qualitySkip = wouldStepDown && self.qualityMisses < self.qualityMissThreshold
        if let measurement = self.measurement,
           self.granularMetrics {
            var report: [VideoSubscription.SimulreceiveChoiceReport] = []
            for choice in choices {
                switch decision {
                case .highestRes(let item, let pristine):
                    if choice.fullTrackName == item.fullTrackName {
                        assert(choice.fullTrackName == selected.fullTrackName)
                        report.append(.init(item: choice, selected: true, reason: "Highest \(pristine ? "Pristine" : "Discontinous")", displayed: !qualitySkip))
                        continue
                    }
                case .onlyChoice(let item):
                    if choice.fullTrackName == item.fullTrackName {
                        assert(choice.fullTrackName == selected.fullTrackName)
                        report.append(.init(item: choice, selected: true, reason: "Only choice", displayed: !qualitySkip))
                    }
                    continue
                }
                report.append(.init(item: choice, selected: false, reason: "", displayed: false))
            }
            let completedReport = report
            Task(priority: .utility) {
                await measurement.measurement.reportSimulreceiveChoice(choices: completedReport,
                                                                       timestamp: decisionTime!)
            }
        }

        if qualitySkip {
            // We only want to step down in quality if we've missed a few hits.
            if let duration = handler.calculateWaitTime(from: at) {
                return duration
            }
            if selectedSample.duration.isValid {
                return selectedSample.duration.seconds
            }
            let highestFps = self.videoHandlers.values.reduce(0) { max($0, $1.config.fps) }
            return 1 / TimeInterval(highestFps)
        }

        // Proceed with rendering this frame.
        self.qualityMisses = 0
        self.pauseMissCounts[handler.fullTrackName] = 0
        self.last = handler.fullTrackName
        self.lastImage = selected.image

        if self.simulreceive == .enable {
            // Set to display immediately.
            if selectedSample.sampleAttachments.count > 0 {
                selectedSample.sampleAttachments[0][.displayImmediately] = true
            } else {
                Self.logger.warning("Couldn't set display immediately attachment")
            }

            // Enqueue the sample on the main thread.
            let dispatchLabel: String?
            let description = String(describing: handler)
            if description != self.lastSimulreceiveLabel {
                dispatchLabel = description
            } else {
                dispatchLabel = nil
            }

            DispatchQueue.main.async {
                let participant = self.participants.getOrMake(identifier: self.subscription.sourceID)
                if let dispatchLabel = dispatchLabel {
                    participant.label = dispatchLabel
                }
                do {
                    try participant.view.enqueue(selectedSample,
                                                 transform: handler.orientation?.toTransform(handler.verticalMirror))
                } catch {
                    Self.logger.error("Could not enqueue sample: \(error)")
                }
            }
        } else if self.simulreceive == .visualizeOnly {
            let fullTrackName = handler.fullTrackName
            if fullTrackName != self.lastHighlight {
                Self.logger.debug("Updating highlight to: \(selectedSample.formatDescription!.dimensions.width)")
                self.lastHighlight = fullTrackName
                DispatchQueue.main.async {
                    for participant in self.participants.participants {
                        do {
                            let namespace = try fullTrackName.getNamespace()
                            participant.value.highlight = participant.key == namespace
                        } catch {
                            Self.logger.error("Failed to parse FTN namespace")
                        }
                    }
                }
            }
        }

        // Wait until we have expect to have the next frame available.
        if let duration = handler.calculateWaitTime(from: at) {
            return duration
        }
        if selectedSample.duration.isValid {
            return selectedSample.duration.seconds
        }
        let highestFps = self.videoHandlers.values.reduce(0) { $0 > $1.config.fps ? $0 : $1.config.fps }
        return 1 / TimeInterval(highestFps)
    }
    // swiftlint:enable cyclomatic_complexity
    // swiftlint:enable function_body_length
}
// swiftlint:enable type_body_length
