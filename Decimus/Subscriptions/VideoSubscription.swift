import AVFoundation

enum SimulreceiveMode: Codable, CaseIterable, Identifiable {
    case none
    case visualizeOnly
    case enable
    var id: Self { self }
}

class VideoSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(VideoSubscription.self)

    private let sourceId: SourceIDType
    private let participants: VideoParticipants
    private let submitter: MetricsSubmitter?
    private let namegate: NameGate
    private let reliable: Bool
    private let granularMetrics: Bool
    private let jitterBufferConfig: VideoJitterBuffer.Config
    private var videoHandlers: [QuicrNamespace: VideoHandler] = [:]
    private var renderTask: Task<(), Never>?
    private let simulreceive: SimulreceiveMode
    private var lastTime: CMTime?
    private var qualityMisses = 0
    private var lastQuality: Int32?
    private let qualityMissThreshold: Int
    private var lastVideoHandler: VideoHandler?
    private var cleanupTask: Task<(), Never>?
    private var lastUpdateTimes: [QuicrNamespace: Date] = [:]
    private var handlerLock = NSLock()
    private let profiles: [QuicrNamespace: VideoCodecConfig]
    private let cleanupTimer: TimeInterval = 1.5
    private var timestampTimeDiff: TimeInterval?

    init(sourceId: SourceIDType,
         profileSet: QClientProfileSet,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         hevcOverride: Bool,
         simulreceive: SimulreceiveMode,
         qualityMissThreshold: Int) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.sourceId = sourceId
        self.participants = participants
        self.submitter = metricsSubmitter
        self.namegate = namegate
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.qualityMissThreshold = qualityMissThreshold

        // Adjust and store expected quality profiles.
        var createdProfiles: [QuicrNamespace: VideoCodecConfig] = [:]
        for profileIndex in 0..<profileSet.profilesCount {
            let profile = profileSet.profiles.advanced(by: profileIndex).pointee
            let config = CodecFactory.makeCodecConfig(from: .init(cString: profile.qualityProfile))
            guard let config = config as? VideoCodecConfig else {
                throw "Codec mismatch"
            }
            let adjustedConfig = hevcOverride ? .init(codec: .hevc,
                                                      bitrate: config.bitrate,
                                                      fps: config.fps,
                                                      width: config.width,
                                                      height: config.height) : config
            let namespace = QuicrNamespace(cString: profile.quicrNamespace)
            createdProfiles[namespace] = adjustedConfig
        }

        // Make all the video handlers upfront.
        self.profiles = createdProfiles
        for namespace in createdProfiles.keys {
            try makeHandler(namespace: namespace)
        }

        // Make task to do simulreceive.
        if self.simulreceive != .none {
            startRenderTask()
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
                           self.lastVideoHandler == video {
                            self.lastVideoHandler = nil
                        }
                    }

                    // If there are no handlers left and we're simulreceive, we should remove our video render.
                    if self.videoHandlers.isEmpty && self.simulreceive == .enable {
                        self.participants.removeParticipant(identifier: self.sourceId)
                    }
                }
                try? await Task.sleep(for: .seconds(self.cleanupTimer), tolerance: .seconds(self.cleanupTimer), clock: .continuous)
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
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return SubscriptionError.none.rawValue
    }

    func update(_ sourceId: String!, label: String!, profileSet: QClientProfileSet) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ name: String!, data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32 {
        let zeroCopiedData = Data(bytesNoCopy: .init(mutating: data), count: length, deallocator: .none)

        if self.timestampTimeDiff == nil {
            self.timestampTimeDiff = self.getTimestamp(data: zeroCopiedData,
                                                       namespace: name,
                                                       groupId: groupId,
                                                       objectId: objectId)
        }

        self.handlerLock.withLock {
            self.lastUpdateTimes[name] = Date.now
            do {
                if self.videoHandlers[name] == nil {
                    try makeHandler(namespace: name)
                    if let task = self.renderTask,
                       task.isCancelled {
                        startRenderTask()
                    }
                }
                guard let handler = self.videoHandlers[name] else {
                    throw "Unknown namespace"
                }
                if handler.timestampTimeDiff == nil {
                    handler.timestampTimeDiff = self.timestampTimeDiff
                }
                try handler.submitEncodedData(zeroCopiedData, groupId: groupId, objectId: objectId)
            } catch {
                Self.logger.error("Failed to handle video data: \(error.localizedDescription)")
            }
        }
        return SubscriptionError.none.rawValue
    }

    private func startRenderTask() {
        self.renderTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                var cancel = false
                let duration = self.handlerLock.withLock {
                    guard !self.videoHandlers.isEmpty else {
                        cancel = true
                        return TimeInterval.nan
                    }
                    return try! self.makeSimulreceiveDecision()
                }
                guard !cancel else {
                    self.renderTask?.cancel()
                    return
                }
                if duration > 0 {
                    try? await Task.sleep(for: .seconds(duration))
                }
            }
        }
    }

    private func makeHandler(namespace: QuicrNamespace) throws {
        guard let config = self.profiles[namespace] else {
            throw "Missing config for: \(namespace)"
        }
        self.videoHandlers[namespace] = try .init(namespace: namespace,
                                                  config: config,
                                                  participants: self.participants,
                                                  metricsSubmitter: self.submitter,
                                                  namegate: self.namegate,
                                                  reliable: self.reliable,
                                                  granularMetrics: self.granularMetrics,
                                                  jitterBufferConfig: self.jitterBufferConfig,
                                                  simulreceive: self.simulreceive)
    }

    private func makeSimulreceiveDecision() throws -> TimeInterval {
        guard !self.videoHandlers.isEmpty else {
            throw "No handlers"
        }

        // Get available decoded frames from all handlers.
        var retrievedFrames: [VideoHandler: CMSampleBuffer] = [:]
        var highestFps: UInt16?
        for handler in self.videoHandlers.values {
            // Is a frame available?
            if highestFps == nil || handler.config.fps > highestFps! {
                highestFps = handler.config.fps
            }

            if let frame = handler.getLastImage() {
                retrievedFrames[handler] = frame
            }
        }

        guard let highestFps = highestFps else {
            throw "Failed to determine highest FPS"
        }

        // No decision to make.
        guard retrievedFrames.count > 0 else {
            let duration: TimeInterval
            if let lastHandler = self.lastVideoHandler {
                duration = lastHandler.calculateWaitTime() ?? 1 / TimeInterval(highestFps)
            } else {
                duration = 1 / TimeInterval(highestFps)
            }
            return duration
        }

        // Oldest should be the oldest value that hasn't already been shown.
        var oldest: CMTime?
        for (handler, frame) in retrievedFrames {
            if let lastTime = self.lastTime,
               frame.presentationTimeStamp < lastTime {
                // This would be backwards in time, so we'll never use it.
                handler.removeLastImage(sample: frame)
                continue
            }

            // Take the oldest frame.
            if oldest == nil || frame.presentationTimeStamp < oldest! {
                oldest = frame.presentationTimeStamp
            }
        }

        // Filter out any frames that don't match the desired point in time.
        retrievedFrames = retrievedFrames.filter {
            $0.value.presentationTimeStamp == oldest
        }

        // Now we've decided our point in time,
        // pop off the ones for the time we're using so we don't get them next time.
        for pair in retrievedFrames {
            pair.key.removeLastImage(sample: pair.value)
        }

        // We'll use the highest quality frame of the selected ones.
        let sorted = retrievedFrames.sorted {
            $0.0.config.width > $1.0.config.width
        }

        guard let first = sorted.first else { fatalError() }

        self.lastVideoHandler = first.key
        let sample = first.value
        let width = sample.formatDescription!.dimensions.width
        if let lastQuality = self.lastQuality,
           width < lastQuality {
            self.qualityMisses += 1
        }

        // We only want to step down in quality if we've missed a few hits.
        if let lastQuality = self.lastQuality,
           width < lastQuality && self.qualityMisses < self.qualityMissThreshold {
            if let duration = first.key.calculateWaitTime() {
                return duration
            }
            if sample.duration.isValid {
                return sample.duration.seconds
            }
            return 1 / TimeInterval(highestFps)
        }

        // Proceed with rendering this frame.
        self.qualityMisses = 0
        self.lastQuality = sample.formatDescription!.dimensions.width

        if self.simulreceive == .enable {
            // Set to display immediately.
            if sample.sampleAttachments.count > 0 {
                sample.sampleAttachments[0][.displayImmediately] = true
            } else {
                Self.logger.warning("Couldn't set display immediately attachment")
            }

            // Enqueue the sample on the main thread.
            DispatchQueue.main.async {
                let participant = self.participants.getOrMake(identifier: self.sourceId)
                participant.label = .init(describing: first.key)
                do {
                    try participant.view.enqueue(sample, transform: CATransform3DIdentity)
                } catch {
                    Self.logger.error("Could not enqueue sample: \(error)")
                }
            }
        } else if self.simulreceive == .visualizeOnly {
            DispatchQueue.main.async {
                for participant in self.participants.participants {
                    participant.value.view.highlight = participant.key == first.key.namespace
                }
            }
        }

        // Wait until we have expect to have the next frame available.
        if let duration = first.key.calculateWaitTime() {
            return duration
        }
        if sample.duration.isValid {
            return sample.duration.seconds
        }
        return 1 / TimeInterval(highestFps)
    }

    // TODO: Clean this up.
    private func getTimestamp(data: Data, namespace: QuicrNamespace, groupId: UInt32, objectId: UInt16) -> TimeInterval {
        // Save starting time.
        var format: CMFormatDescription?
        var orientation: AVCaptureVideoOrientation?
        var verticalMirror: Bool?
        let config = self.profiles[namespace]
        let samples: [CMSampleBuffer]?
        switch config?.codec {
        case .h264:
            samples = try! H264Utilities.depacketize(data,
                                                     groupId: groupId,
                                                     objectId: objectId,
                                                     format: &format,
                                                     orientation: &orientation,
                                                     verticalMirror: &verticalMirror,
                                                     copy: true)
        case .hevc:
            samples = try! HEVCUtilities.depacketize(data,
                                                     groupId: groupId,
                                                     objectId: objectId,
                                                     format: &format,
                                                     orientation: &orientation,
                                                     verticalMirror: &verticalMirror,
                                                     copy: true)
        default:
            fatalError()
        }
        if let samples = samples {
            for sample in samples {
                return Date.now.timeIntervalSinceReferenceDate - sample.presentationTimeStamp.seconds
            }
        }
        assert(false)
    }
}
