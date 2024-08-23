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
class VideoSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(VideoSubscription.self)

    private let sourceId: SourceIDType
    private let participants: VideoParticipants
    private let submitter: MetricsSubmitter?
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private let granularMetrics: Bool
    private let jitterBufferConfig: VideoJitterBuffer.Config
    private var videoHandlers: [QuicrNamespace: VideoHandler] = [:]
    private var renderTask: Task<(), Never>?
    private let simulreceive: SimulreceiveMode
    private var lastTime: CMTime?
    private var qualityMisses = 0
    private var last: QuicrNamespace?
    private var lastImage: AvailableImage?
    private let qualityMissThreshold: Int
    private var cleanupTask: Task<(), Never>?
    private var lastUpdateTimes: [QuicrNamespace: Date] = [:]
    private var handlerLock = OSAllocatedUnfairLock()
    private let profiles: [QuicrNamespace: VideoCodecConfig]
    private let cleanupTimer: TimeInterval = 1.5
    private var pauseMissCounts: [QuicrNamespace: Int] = [:]
    private let pauseMissThreshold: Int
    private weak var callController: CallController?
    private let pauseResume: Bool
    private var lastSimulreceiveLabel: String?
    private var lastHighlight: QuicrNamespace?
    private var lastDiscontinous = false
    private let measurement: MeasurementRegistration<VideoSubscriptionMeasurement>?
    private let variances: VarianceCalculator
    private let decodedVariances: VarianceCalculator
    private var formats: [QuicrNamespace: CMFormatDescription?] = [:]
    private var timestampTimeDiff: TimeInterval?
    private var suspension = SlidingTimeWindow(length: 60)
    private var currentMax: TimeInterval?

    init(sourceId: SourceIDType,
         profileSet: QClientProfileSet,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         qualityMissThreshold: Int,
         pauseMissThreshold: Int,
         controller: CallController?,
         pauseResume: Bool) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.sourceId = sourceId
        self.participants = participants
        self.submitter = metricsSubmitter
        if let submitter = metricsSubmitter {
            let measurement = VideoSubscriptionMeasurement(source: self.sourceId)
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
        self.callController = controller
        self.pauseResume = pauseResume
        self.variances = try .init(expectedOccurrences: profileSet.profilesCount,
                                   submitter: self.granularMetrics ? metricsSubmitter : nil,
                                   source: sourceId,
                                   stage: "SubscribedObject")
        self.decodedVariances = try .init(expectedOccurrences: profileSet.profilesCount,
                                          submitter: self.granularMetrics ? metricsSubmitter : nil,
                                          source: sourceId,
                                          stage: "Decoded")

        // Adjust and store expected quality profiles.
        var createdProfiles: [QuicrNamespace: VideoCodecConfig] = [:]
        for profileIndex in 0..<profileSet.profilesCount {
            let profile = profileSet.profiles.advanced(by: profileIndex).pointee
            let config = CodecFactory.makeCodecConfig(from: .init(cString: profile.qualityProfile),
                                                      bitrateType: .average)
            guard let config = config as? VideoCodecConfig else {
                throw "Codec mismatch"
            }
            let namespace = QuicrNamespace(cString: profile.quicrNamespace)
            createdProfiles[namespace] = config
        }

        // Make all the video handlers upfront.
        self.profiles = createdProfiles
        for namespace in createdProfiles.keys {
            self.formats[namespace] = nil
            self.videoHandlers[namespace] = try makeHandler(namespace: namespace)
        }

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
                           video.namespace == last {
                            self.last = nil
                            self.lastImage = nil
                        }
                    }

                    // If there are no handlers left and we're simulreceive, we should remove our video render.
                    if self.videoHandlers.isEmpty && self.simulreceive == .enable {
                        self.participants.removeParticipant(identifier: self.sourceId)
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
            self.participants.removeParticipant(identifier: self.sourceId)
        }
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 profileSet: QClientProfileSet,
                 transportMode: UnsafeMutablePointer<TransportMode>!) -> Int32 {
        transportMode.pointee = self.reliable ? .reliablePerGroup : .unreliable
        return SubscriptionError.none.rawValue
    }

    func update(_ sourceId: String!, label: String!, profileSet: QClientProfileSet) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ name: String!,
                          data: UnsafeRawPointer!,
                          length: Int,
                          groupId: UInt32,
                          objectId: UInt16) -> Int32 {
        // Start processing.
        let now = Date.now
        let zeroCopiedData = Data(bytesNoCopy: .init(mutating: data), count: length, deallocator: .none)

        // Depacketize.
        let frame: DecimusVideoFrame
        do {
            guard let depacketized = try self.depacketize(namespace: name,
                                                          data: zeroCopiedData,
                                                          groupId: groupId,
                                                          objectId: objectId) else {
                throw "Nothing"
            }
            frame = depacketized
        } catch {
            Self.logger.error("Failed to depacketize video frame: \(error.localizedDescription)")
            return 0
        }

        if let timestamp = frame.samples.first?.presentationTimeStamp.seconds {
            if self.timestampTimeDiff == nil {
                self.timestampTimeDiff = now.timeIntervalSinceReferenceDate - timestamp
            }

            // Calculate switching set arrival variance.
            _ = self.variances.calculateSetVariance(timestamp: timestamp, now: now)
            if self.granularMetrics,
               let measurement = self.measurement {
                Task(priority: .utility) {
                    await measurement.measurement.reportTimestamp(namespace: name,
                                                                  timestamp: timestamp,
                                                                  at: now)
                }
            }
        } else {
            Self.logger.error("Failed to get timestamp")
        }

        // If we're responsible for rendering, start the task.
        if self.simulreceive != .none && (self.renderTask == nil || self.renderTask!.isCancelled) {
            startRenderTask()
        }

        // Suspension tracking.
        if self.currentMax == nil {
            // Ensure that we take into account our configured value.
            self.suspension.add(timestamp: now.addingTimeInterval(-self.jitterBufferConfig.minDepth))
        }
        self.suspension.add(timestamp: now)

        let handler: VideoHandler
        do {
            handler = try self.handlerLock.withLock {
                self.lastUpdateTimes[name] = now
                let lookup = self.videoHandlers[name]
                guard let lookup = lookup else {
                    let handler = try makeHandler(namespace: name)
                    self.videoHandlers[name] = handler
                    return handler
                }

                // While we're here, set depth for everyone.
                if self.jitterBufferConfig.adaptive {
                    if let thisMax = self.suspension.max(from: now) {
                        if let currentMax = self.currentMax,
                           thisMax != currentMax {
                            for handler in self.videoHandlers {
                                handler.value.setTargetDepth(thisMax, from: now)
                            }
                        }
                        self.currentMax = thisMax
                    }
                }

                return lookup
            }
        } catch {
            Self.logger.error("Failed to fetch/create handler: \(error.localizedDescription)")
            return SubscriptionError.none.rawValue
        }

        // Set timestamp diff.
        if let diff = self.timestampTimeDiff {
            handler.setTimeDiff(diff: diff)
        }

        // Submit the data.
        do {
            try handler.submitEncodedData(frame, from: now)
        } catch {
            Self.logger.error("Failed to handle video data: \(error.localizedDescription)")
            return SubscriptionError.none.rawValue
        }
        return SubscriptionError.none.rawValue
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

    private func makeHandler(namespace: QuicrNamespace) throws -> VideoHandler {
        guard let config = self.profiles[namespace] else {
            throw "Missing config for: \(namespace)"
        }
        return try .init(namespace: namespace,
                         config: config,
                         participants: self.participants,
                         metricsSubmitter: self.submitter,
                         videoBehaviour: self.videoBehaviour,
                         reliable: self.reliable,
                         granularMetrics: self.granularMetrics,
                         jitterBufferConfig: self.jitterBufferConfig,
                         simulreceive: self.simulreceive,
                         variances: self.decodedVariances)
    }

    struct SimulreceiveItem: Equatable {
        static func == (lhs: VideoSubscription.SimulreceiveItem, rhs: VideoSubscription.SimulreceiveItem) -> Bool {
            lhs.namespace == rhs.namespace
        }
        let namespace: QuicrNamespace
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
                initialChoices.append(.init(namespace: handler.key, image: available))
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
            let handler = self.videoHandlers[choice.namespace]!
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
            for pauseCandidateCount in self.pauseMissCounts {
                guard let pauseCandidate = self.videoHandlers[pauseCandidateCount.key],
                      pauseCandidate.config.width > incomingWidth,
                      let callController = self.callController,
                      callController.getSubscriptionState(pauseCandidate.namespace) == .ready else {
                    continue
                }

                let newValue = pauseCandidateCount.value + 1
                Self.logger.warning("Incremented pause count for: \(pauseCandidate.config.width), now: \(newValue)/\(self.pauseMissThreshold)")
                if newValue >= self.pauseMissThreshold {
                    // Pause this subscription.
                    Self.logger.warning("Pausing subscription: \(pauseCandidate.config.width)")
                    callController.setSubscriptionState(pauseCandidate.namespace, transportMode: .pause)
                    self.pauseMissCounts[pauseCandidate.namespace] = 0
                } else {
                    // Increment the pause miss count.
                    self.pauseMissCounts[pauseCandidate.namespace] = newValue
                }
            }
        }

        guard let handler = self.videoHandlers[selected.namespace] else {
            throw "Missing expected handler for namespace: \(selected.namespace)"
        }

        let qualitySkip = wouldStepDown && self.qualityMisses < self.qualityMissThreshold
        if let measurement = self.measurement,
           self.granularMetrics {
            var report: [VideoSubscription.SimulreceiveChoiceReport] = []
            for choice in choices {
                switch decision {
                case .highestRes(let item, let pristine):
                    if choice.namespace == item.namespace {
                        assert(choice.namespace == selected.namespace)
                        report.append(.init(item: choice, selected: true, reason: "Highest \(pristine ? "Pristine" : "Discontinous")", displayed: !qualitySkip))
                        continue
                    }
                case .onlyChoice(let item):
                    if choice.namespace == item.namespace {
                        assert(choice.namespace == selected.namespace)
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
        self.pauseMissCounts[handler.namespace] = 0
        self.last = handler.namespace
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
                let participant = self.participants.getOrMake(identifier: self.sourceId)
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
            let namespace = handler.namespace
            if namespace != self.lastHighlight {
                Self.logger.debug("Updating highlight to: \(selectedSample.formatDescription!.dimensions.width)")
                self.lastHighlight = namespace
                DispatchQueue.main.async {
                    for participant in self.participants.participants {
                        participant.value.highlight = participant.key == namespace
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

    struct VideoHelpers {
        let utilities: VideoUtilities
        let seiData: ApplicationSeiData
    }

    private func depacketize(namespace: QuicrNamespace,
                             data: Data,
                             groupId: UInt32,
                             objectId: UInt16) throws -> DecimusVideoFrame? {
        let config = self.profiles[namespace]
        let helpers: VideoHelpers = try {
            switch config?.codec {
            case .h264:
                return .init(utilities: H264Utilities(), seiData: ApplicationH264SEIs())
            case .hevc:
                return .init(utilities: HEVCUtilities(), seiData: ApplicationHEVCSEIs())
            default:
                throw "Unsupported codec"
            }
        }()

        // Depacketize.
        var extractedFormat: CMFormatDescription?
        var seis: [ApplicationSEI] = []
        let buffers = try helpers.utilities.depacketize(data, format: &extractedFormat, copy: false) {
            do {
                let parser = ApplicationSeiParser(helpers.seiData)
                if let sei = try parser.parse(encoded: $0) {
                    seis.append(sei)
                }
            } catch {
                Self.logger.warning("Failed to parse custom SEI: \(error.localizedDescription)")
            }
        }
        let format: CMFormatDescription?
        if let extractedFormat = extractedFormat {
            format = extractedFormat
            self.formats[namespace] = format
        } else {
            guard let existing = self.formats[namespace] else {
                throw "Expected format"
            }
            format = existing
        }

        let sei: ApplicationSEI?
        if seis.count == 0 {
            sei = nil
        } else {
            sei = seis.reduce(ApplicationSEI(timestamp: nil, orientation: nil, age: nil)) { result, next in
                let timestamp = next.timestamp ?? result.timestamp
                let orientation = next.orientation ?? result.orientation
                let age = next.age ?? result.age
                return .init(timestamp: timestamp, orientation: orientation, age: age)
            }
        }

        guard let buffers = buffers else { return nil }
        let timeInfo: CMSampleTimingInfo
        if let timestamp = sei?.timestamp {
            timeInfo = .init(duration: .invalid, presentationTimeStamp: timestamp.timestamp, decodeTimeStamp: .invalid)
        } else {
            Self.logger.error("Missing expected frame timestamp")
            timeInfo = .invalid
        }

        var samples: [CMSampleBuffer] = []
        for buffer in buffers {
            samples.append(try CMSampleBuffer(dataBuffer: buffer,
                                              formatDescription: format,
                                              numSamples: 1,
                                              sampleTimings: [timeInfo],
                                              sampleSizes: [buffer.dataLength]))
        }

        let captureDate: Date?
        if let age = sei?.age {
            captureDate = Date(timeIntervalSinceReferenceDate: age.timestamp.seconds)
        } else {
            captureDate = nil
        }

        return .init(samples: samples,
                     groupId: groupId,
                     objectId: objectId,
                     sequenceNumber: sei?.timestamp?.sequenceNumber,
                     fps: sei?.timestamp?.fps,
                     orientation: sei?.orientation?.orientation,
                     verticalMirror: sei?.orientation?.verticalMirror,
                     captureDate: captureDate)
    }
}
// swiftlint:enable type_body_length
