import AVFoundation
import Atomics
import os

// swiftlint:disable type_body_length

enum DecimusVideoRotation: UInt8 {
    case portrait = 1
    case portraitUpsideDown = 2
    case landscapeRight = 3
    case landscapeLeft = 4
}

/// Handles decoding, jitter, and rendering of a video stream.
class VideoHandler: CustomStringConvertible {
    private static let logger = DecimusLogger(VideoHandler.self)

    /// The current configuration in use.
    let config: VideoCodecConfig
    /// A description of the video handler.
    var description: String
    /// The namespace identifying this stream.
    let namespace: QuicrNamespace

    private var decoder: VTDecoder?
    private let participants: VideoParticipants
    private let measurement: MeasurementRegistration<VideoHandlerMeasurement>?
    private var lastGroup: UInt32?
    private var lastObject: UInt16?
    private let namegate = SequentialObjectBlockingNameGate()
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private var jitterBuffer: VideoJitterBuffer?
    private let granularMetrics: Bool
    private var dequeueTask: Task<(), Never>?
    private var dequeueBehaviour: VideoDequeuer?
    private let jitterBufferConfig: VideoJitterBuffer.Config
    var orientation: DecimusVideoRotation? {
        let result = atomicOrientation.load(ordering: .acquiring)
        return result == 0 ? nil : .init(rawValue: result)
    }
    var verticalMirror: Bool {
        atomicMirror.load(ordering: .acquiring)
    }
    private var atomicOrientation = ManagedAtomic<UInt8>(0)
    private var atomicMirror = ManagedAtomic<Bool>(false)
    private var currentFormat: CMFormatDescription?
    private var startTimeSet = false
    private let metricsSubmitter: MetricsSubmitter?
    private let simulreceive: SimulreceiveMode
    var lastDecodedImage: AvailableImage?
    let lastDecodedImageLock = OSAllocatedUnfairLock()
    private var timestampTimeDiffUs = ManagedAtomic(UInt64.zero)
    private var lastFps: UInt16?
    private var lastDimensions: CMVideoDimensions?

    private var duration: TimeInterval? = 0
    private let variances: VarianceCalculator
    private var currentTargetDepth: TimeInterval

    /// Create a new video handler.
    /// - Parameters:
    ///     - namespace: The namespace for this video stream.
    ///     - config: Codec configuration for this video stream.
    ///     - participants: Video participants dependency for rendering.
    ///     - metricsSubmitter: If present, a submitter to record metrics through.
    ///     - videoBehaviour: Behaviour mode used for making decisions about valid group/object values.
    ///     - reliable: True if this stream should be considered to be reliable (in order, no loss).
    ///     - granularMetrics: True to record per frame / operation metrics at a performance cost.
    ///     - jitterBufferConfig: Requested configuration for jitter handling.
    ///     - simulreceive: The mode to operate in if any sibling streams are present.
    /// - Throws: Simulreceive cannot be used with a jitter buffer mode of `layer`.
    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         variances: VarianceCalculator) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.namespace = namespace
        self.config = config
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            let measurement = VideoHandler.VideoHandlerMeasurement(namespace: namespace)
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.videoBehaviour = videoBehaviour
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.metricsSubmitter = metricsSubmitter
        self.description = self.namespace
        self.variances = variances
        self.currentTargetDepth = jitterBufferConfig.minDepth

        if jitterBufferConfig.mode != .layer {
            // Create the decoder.
            self.decoder = .init(config: self.config) { [weak self] sample in
                guard let self = self else { return }
                let now = Date.now
                if simulreceive != .none {
                    _ = self.variances.calculateSetVariance(timestamp: sample.presentationTimeStamp.seconds,
                                                            now: now)
                    self.lastDecodedImageLock.lock()
                    defer { self.lastDecodedImageLock.unlock() }
                    self.lastDecodedImage = .init(image: sample,
                                                  fps: UInt(self.config.fps),
                                                  discontinous: sample.discontinous)
                }
                if simulreceive != .enable {
                    // Enqueue for rendering.
                    do {
                        try self.enqueueSample(sample: sample,
                                               orientation: self.orientation,
                                               verticalMirror: self.verticalMirror,
                                               from: now)
                    } catch {
                        Self.logger.error("Failed to enqueue decoded sample: \(error)")
                    }
                }
            }
        }
    }

    deinit {
        if self.simulreceive != .enable {
            self.participants.removeParticipant(identifier: namespace)
        }
        self.dequeueTask?.cancel()
    }

    /// Pass an encoded video frame to this video handler.
    /// - Parameter data Encoded H264 frame data.
    /// - Parameter groupId The group.
    /// - Parameter objectId The object in the group.
    func submitEncodedData(_ frame: DecimusVideoFrame, from: Date) throws {
        // Do we need to create a jitter buffer?
        if self.jitterBuffer == nil,
           self.jitterBufferConfig.mode != .layer,
           self.jitterBufferConfig.mode != .none {
            // Create the video jitter buffer.
            try createJitterBuffer(frame: frame)
            assert(self.dequeueTask == nil)
            createDequeueTask()
        }

        // Do we need to copy the frame data?
        let copy = self.jitterBuffer != nil || self.jitterBufferConfig.mode == .layer
        let frame: DecimusVideoFrame = copy ? try .init(copy: frame) : frame

        // Either write the frame to the jitter buffer or otherwise decode it.
        if let jitterBuffer = self.jitterBuffer {
            try jitterBuffer.write(videoFrame: frame, from: from)
        } else {
            try decode(sample: frame, from: from)
        }

        // Do we need to update the label?
        if let first = frame.samples.first {
            let resolvedFps: UInt16
            if let fps = frame.fps {
                resolvedFps = UInt16(fps)
            } else {
                resolvedFps = self.config.fps
            }

            if resolvedFps != self.lastFps || first.formatDescription?.dimensions != self.lastDimensions {
                self.lastFps = resolvedFps
                self.lastDimensions = first.formatDescription?.dimensions
                DispatchQueue.main.async {
                    do {
                        self.description = try self.labelFromSample(sample: first, fps: resolvedFps)
                        guard self.simulreceive != .enable else { return }
                        let participant = self.participants.getOrMake(identifier: self.namespace)
                        participant.label = .init(describing: self)
                    } catch {
                        Self.logger.error("Failed to set label: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Metrics.
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? from : nil
            Task(priority: .utility) {
                if let captureDate = frame.captureDate,
                   let now = now {
                    let age = now.timeIntervalSince(captureDate)
                    await measurement.measurement.age(age: age, timestamp: now)
                }
                await measurement.measurement.receivedFrame(timestamp: now, idr: frame.objectId == 0)
                let bytes = frame.samples.reduce(into: 0) { $0 += $1.totalSampleSize }
                await measurement.measurement.receivedBytes(received: bytes, timestamp: now)
            }
        }
    }

    /// Calculates the time until the next frame would be expected, or nil if there is no next frame.
    /// - Parameter from: The time to calculate from.
    /// - Returns Time to wait in seconds, if any.
    func calculateWaitTime(from: Date) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else {
            fatalError("Shouldn't use calculateWaitTime with no jitterbuffer")
        }
        let diffUs = self.timestampTimeDiffUs.load(ordering: .acquiring)
        guard diffUs > 0 else { fatalError("This must be set prior to dequeueing") }
        let diff = TimeInterval(diffUs) / 1_000_000.0
        return jitterBuffer.calculateWaitTime(from: from, offset: diff)
    }

    func calculateWaitTime(frame: DecimusVideoFrame, from: Date = .now) -> TimeInterval {
        guard let jitterBuffer = self.jitterBuffer else {
            fatalError("Shouldn't use calculateWaitTime with no jitterbuffer")
        }
        let diffUs = self.timestampTimeDiffUs.load(ordering: .acquiring)
        guard diffUs > 0 else { fatalError("This must be set prior to dequeueing") }
        let diff = TimeInterval(diffUs) / 1_000_000.0
        return jitterBuffer.calculateWaitTime(frame: frame, from: from, offset: diff)
    }

    private func createJitterBuffer(frame: DecimusVideoFrame) throws {
        let remoteFPS: UInt16
        if let fps = frame.fps {
            remoteFPS = UInt16(fps)
        } else {
            remoteFPS = self.config.fps
        }

        // We have what we need to configure the PID dequeuer if using.
        let duration = 1 / Double(remoteFPS)
        assert(self.dequeueBehaviour == nil)
        if jitterBufferConfig.mode == .pid {
            self.dequeueBehaviour = PIDDequeuer(targetDepth: jitterBufferConfig.minDepth,
                                                frameDuration: duration,
                                                kp: 0.01,
                                                ki: 0.001,
                                                kd: 0.001)
        }

        // Create the video jitter buffer.
        self.jitterBuffer = try .init(namespace: self.namespace,
                                      metricsSubmitter: self.metricsSubmitter,
                                      sort: !self.reliable,
                                      minDepth: self.currentTargetDepth,
                                      capacity: self.jitterBufferConfig.capacity,
                                      duration: duration)
        self.duration = duration
    }

    private func createDequeueTask() {
        // Start the frame dequeue task.
        self.dequeueTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let now = Date.now

                // Wait until we expect to have a frame available.
                let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                let waitTime: TimeInterval
                if let pid = self.dequeueBehaviour as? PIDDequeuer {
                    pid.currentDepth = jitterBuffer.getDepth()
                    waitTime = self.dequeueBehaviour!.calculateWaitTime(from: now)
                } else {
                    guard let duration = self.duration else {
                        Self.logger.error("Missing duration")
                        return
                    }
                    waitTime = calculateWaitTime(from: now) ?? duration
                }
                if waitTime > 0 {
                    do {
                        try await Task.sleep(for: .seconds(waitTime),
                                             tolerance: .seconds(waitTime / 2),
                                             clock: .continuous)
                        guard let task = self.dequeueTask,
                              !task.isCancelled else {
                            return
                        }
                    } catch {
                        Self.logger.error("Exception during sleep: \(error.localizedDescription)")
                        continue
                    }
                }

                // Attempt to dequeue a frame.
                if let sample = jitterBuffer.read(from: now) {
                    if self.granularMetrics,
                       let measurement = self.measurement?.measurement {
                        let time = self.calculateWaitTime(frame: sample)
                        Task(priority: .utility) {
                            await measurement.frameDelay(delay: time, metricsTimestamp: now)
                        }
                    }

                    do {
                        try self.decode(sample: sample, from: now)
                    } catch {
                        Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func setTimeDiff(diff: TimeInterval) {
        assert(diff > (1 / 1_000_000))
        let diffUs = UInt64(diff * 1_000_000)
        _ = self.timestampTimeDiffUs.compareExchange(expected: 0,
                                                     desired: diffUs,
                                                     ordering: .acquiringAndReleasing)
    }

    /// Update the target depth of this handler's jitter buffer, if any.
    /// - Parameter depth: Target depth in seconds.
    func setTargetDepth(_ depth: TimeInterval, from: Date) {
        self.currentTargetDepth = depth
        guard let buffer = self.jitterBuffer else {
            Self.logger.warning("Set target depth on nil buffer!?")
            return
        }
        buffer.setTargetDepth(depth, from: from)
    }

    private func decode(sample: DecimusVideoFrame, from: Date) throws {
        // Should we feed this frame to the decoder?
        // get groupId and objectId from the frame (1st frame)
        let groupId = sample.groupId
        let objectId = sample.objectId
        let gateResult = namegate.handle(groupId: groupId,
                                         objectId: objectId,
                                         lastGroup: self.lastGroup,
                                         lastObject: self.lastObject)
        guard gateResult || self.videoBehaviour != .freeze else {
            // If there's a discontinuity and we want to freeze, we're done.
            return
        }

        if gateResult {
            // Update to track continuity.
            self.lastGroup = groupId
            self.lastObject = objectId
        } else {
            // Mark discontinous.
            for sample in sample.samples {
                sample.discontinous = true
            }
        }

        // Decode.
        for sampleBuffer in sample.samples {
            if self.jitterBufferConfig.mode == .layer {
                try self.enqueueSample(sample: sampleBuffer,
                                       orientation: sample.orientation,
                                       verticalMirror: sample.verticalMirror,
                                       from: from)
            } else {
                if let orientation = sample.orientation {
                    self.atomicOrientation.store(orientation.rawValue, ordering: .releasing)
                }
                if let verticalMirror = sample.verticalMirror {
                    self.atomicMirror.store(verticalMirror, ordering: .releasing)
                }
                try decoder!.write(sampleBuffer)
            }
        }
    }

    private func enqueueSample(sample: CMSampleBuffer,
                               orientation: DecimusVideoRotation?,
                               verticalMirror: Bool?,
                               from: Date) throws {
        if let measurement = self.measurement,
           self.jitterBufferConfig.mode != .layer {
            let now: Date? = self.granularMetrics ? from : nil
            Task(priority: .utility) {
                await measurement.measurement.decodedFrame(timestamp: now)
            }
        }

        if self.jitterBufferConfig.mode != .layer {
            // We're taking care of time already, show immediately.
            if sample.sampleAttachments.count > 0 {
                sample.sampleAttachments[0][.displayImmediately] = true
            } else {
                Self.logger.warning("Couldn't set display immediately attachment")
            }
        }

        // Enqueue the sample on the main thread.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            do {
                // Set the layer's start time to the first sample's timestamp minus the target depth.
                if !self.startTimeSet {
                    try self.setLayerStartTime(layer: participant.view.layer!, time: sample.presentationTimeStamp)
                    self.startTimeSet = true
                }
                try participant.view.enqueue(sample, transform: orientation?.toTransform(verticalMirror!))
                if self.granularMetrics,
                   let measurement = self.measurement {
                    let timestamp = sample.presentationTimeStamp.seconds
                    Task(priority: .background) {
                        await measurement.measurement.enqueuedFrame(frameTimestamp: timestamp, metricsTimestamp: from)
                    }
                }
            } catch {
                Self.logger.error("Could not enqueue sample: \(error)")
            }
        }
    }

    private func setLayerStartTime(layer: AVSampleBufferDisplayLayer, time: CMTime) throws {
        guard Thread.isMainThread else {
            throw "Should be called from the main thread"
        }
        let timebase = try CMTimebase(sourceClock: .hostTimeClock)
        let startTime: CMTime
        if self.jitterBufferConfig.mode == .layer {
            let delay = CMTime(seconds: self.jitterBufferConfig.minDepth,
                               preferredTimescale: 1000)
            startTime = CMTimeSubtract(time, delay)
        } else {
            startTime = time
        }
        try timebase.setTime(startTime)
        try timebase.setRate(1.0)
        layer.controlTimebase = timebase
    }

    private func flushDisplayLayer() {
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            do {
                try participant.view.flush()
            } catch {
                Self.logger.error("Could not flush layer: \(error)")
            }
            Self.logger.debug("Flushing display layer")
            self.startTimeSet = false
        }
    }

    private func labelFromSample(sample: CMSampleBuffer, fps: UInt16) throws -> String {
        guard let format = sample.formatDescription else {
            throw "Missing sample format"
        }
        let size = format.dimensions
        return "\(self.namespace): \(String(describing: config.codec)) \(size.width)x\(size.height) \(fps)fps \(Float(config.bitrate) / pow(10, 6))Mbps"
    }
}

extension DecimusVideoRotation {
    func toTransform(_ verticalMirror: Bool) -> CATransform3D {
        var transform = CATransform3DIdentity
        switch self {
        case .portrait:
            transform = CATransform3DRotate(transform, .pi / 2, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        case .landscapeLeft:
            transform = CATransform3DRotate(transform, .pi, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        case .landscapeRight:
            transform = CATransform3DRotate(transform, -.pi, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, -1.0, 1.0, 1.0)
            }
        case .portraitUpsideDown:
            transform = CATransform3DRotate(transform, -.pi / 2, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        }
        return transform
    }
}

extension VideoHandler: Hashable {
    static func == (lhs: VideoHandler, rhs: VideoHandler) -> Bool {
        return lhs.namespace == rhs.namespace
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.namespace)
    }
}

extension CMVideoDimensions: Equatable {
    public static func == (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }
}
