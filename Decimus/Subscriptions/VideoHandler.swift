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
    private let measurement: VideoHandlerMeasurement?
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
    var timestampTimeDiff: TimeInterval?
    private var lastFps: UInt16?
    private var lastDimensions: CMVideoDimensions?

    private var duration: TimeInterval? = 0

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
         simulreceive: SimulreceiveMode) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.namespace = namespace
        self.config = config
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            let measurement = VideoHandler.VideoHandlerMeasurement(namespace: namespace)
            Task(priority: .utility) {
                await metricsSubmitter.register(measurement: measurement)
            }
            self.measurement = measurement
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

        if jitterBufferConfig.mode != .layer {
            // Create the decoder.
            self.decoder = .init(config: self.config) { [weak self] sample in
                guard let self = self else { return }
                if simulreceive != .none {
                    self.lastDecodedImageLock.lock()
                    defer { self.lastDecodedImageLock.unlock() }
                    self.lastDecodedImage = .init(image: sample, fps: UInt(self.config.fps), discontinous: sample.discontinous)
                }
                if simulreceive != .enable {
                    // Enqueue for rendering.
                    do {
                        try self.enqueueSample(sample: sample,
                                               orientation: self.orientation,
                                               verticalMirror: self.verticalMirror)
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
        if let metricsSubmitter = self.metricsSubmitter,
           let measurement = self.measurement {
            let id = measurement.id
            Task(priority: .utility) {
                await metricsSubmitter.unregister(id: id)
            }
        }
        self.dequeueTask?.cancel()
    }

    /// Pass an encoded video frame to this video handler.
    /// - Parameter data Encoded H264 frame data.
    /// - Parameter groupId The group.
    /// - Parameter objectId The object in the group.
    func submitEncodedData(_ data: Data, groupId: UInt32, objectId: UInt16) throws {
        // Do we need to create a jitter buffer?
        var frame: DecimusVideoFrame?
        if self.jitterBuffer == nil,
           self.jitterBufferConfig.mode != .layer,
           self.jitterBufferConfig.mode != .none {
            // Create the video jitter buffer.
            do {
                frame = try createJitterBuffer(data: data, groupId: groupId, objectId: objectId)
                assert(self.dequeueTask == nil)
                createDequeueTask()
            } catch {
                Self.logger.error("Failed to create jitter buffer: \(error.localizedDescription)")
            }
        }

        // Either write the frame to the jitter buffer or otherwise decode it.
        if let jitterBuffer = self.jitterBuffer {
            if frame == nil {
                frame = try depacketize(data, groupId: groupId, objectId: objectId, copy: true)
            }
            if let frame = frame {
                do {
                    try jitterBuffer.write(videoFrame: frame)
                } catch {
                    Self.logger.warning("Failed to enqueue video frame: \(error.localizedDescription)")
                }
            }
        } else {
            if let frame = try depacketize(data,
                                           groupId: groupId,
                                           objectId: objectId,
                                           copy: self.jitterBufferConfig.mode == .layer) {
                try decode(sample: frame)
            }
        }

        // Metrics.
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.receivedFrame(timestamp: now, idr: objectId == 0)
                await measurement.receivedBytes(received: data.count, timestamp: now)
            }
        }
    }

    /// Calculates the time until the next frame would be expected, or nil if there is no next frame.
    /// - Parameter from: The time to calculate from.
    /// - Returns Time to wait in seconds, if any.
    func calculateWaitTime(from: Date = .now) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else { fatalError("Shouldn't use calculateWaitTime with no jitterbuffer") }
        guard let diff = self.timestampTimeDiff else { return nil }
        return jitterBuffer.calculateWaitTime(from: from, offset: diff)
    }

    private func createJitterBuffer(data: Data, groupId: UInt32, objectId: UInt16) throws -> DecimusVideoFrame {
        guard let frame = try depacketize(data, groupId: groupId, objectId: objectId, copy: true) else {
            throw "Failed to depacketize frame"
        }
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
                                      minDepth: self.jitterBufferConfig.minDepth,
                                      capacity: Int(ceil(self.jitterBufferConfig.minDepth / duration) * 10))
        self.duration = duration
        return frame
    }

    private func createDequeueTask() {
        // Start the frame dequeue task.
        self.dequeueTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }

                // Wait until we expect to have a frame available.
                let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                let waitTime: TimeInterval
                if let pid = self.dequeueBehaviour as? PIDDequeuer {
                    pid.currentDepth = jitterBuffer.getDepth()
                    waitTime = self.dequeueBehaviour!.calculateWaitTime()
                } else {
                    guard let duration = self.duration else {
                        Self.logger.error("Missing duration")
                        return
                    }
                    waitTime = calculateWaitTime() ?? duration
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
                if let sample = jitterBuffer.read() {
                    do {
                        try self.decode(sample: sample)
                    } catch {
                        Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func depacketize(_ data: Data, groupId: UInt32, objectId: UInt16, copy: Bool) throws -> DecimusVideoFrame? {
        let buffers: [CMBlockBuffer]?
        var seis: [ApplicationSEI] = []
        switch self.config.codec {
        case .h264:
            buffers = try H264Utilities.depacketize(data,
                                                    format: &self.currentFormat,
                                                    copy: copy) {
                do {
                    let parser = ApplicationSeiParser(ApplicationH264SEIs())
                    if let sei = try parser.parse(encoded: $0) {
                        seis.append(sei)
                    }
                } catch {
                    Self.logger.error("Failed to parse custom SEI: \(error.localizedDescription)")
                }
            }
        case .hevc:
            buffers = try HEVCUtilities.depacketize(data,
                                                    format: &self.currentFormat,
                                                    copy: copy) {
                do {
                    let parser = ApplicationSeiParser(ApplicationHEVCSEIs())
                    if let sei = try parser.parse(encoded: $0) {
                        seis.append(sei)
                    }
                } catch {
                    Self.logger.error("Failed to parse custom SEI: \(error.localizedDescription)")
                }
            }
        default:
            throw "Unsupported codec: \(self.config.codec)"
        }

        let sei: ApplicationSEI?
        if seis.count == 0 {
            sei = nil
        } else {
            sei = seis.reduce(ApplicationSEI(timestamp: nil, orientation: nil)) { result, next in
                let timestamp = next.timestamp ?? result.timestamp
                let orientation = next.orientation ?? result.orientation
                return .init(timestamp: timestamp, orientation: orientation)
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
                                              formatDescription: self.currentFormat,
                                              numSamples: 1,
                                              sampleTimings: [timeInfo],
                                              sampleSizes: [buffer.dataLength]))
        }

        // Do we need to update the label?
        if let first = samples.first {
            let resolvedFps: UInt16
            if let fps = sei?.timestamp?.fps {
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

        return .init(samples: samples,
                     groupId: groupId,
                     objectId: objectId,
                     sequenceNumber: sei?.timestamp?.sequenceNumber,
                     fps: sei?.timestamp?.fps,
                     orientation: sei?.orientation?.orientation,
                     verticalMirror: sei?.orientation?.verticalMirror)
    }

    private func decode(sample: DecimusVideoFrame) throws {
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
                try self.enqueueSample(sample: sampleBuffer, orientation: sample.orientation, verticalMirror: sample.verticalMirror)
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
                               verticalMirror: Bool?) throws {
        if let measurement = self.measurement,
           self.jitterBufferConfig.mode != .layer {
            let now: Date? = self.granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.decodedFrame(timestamp: now)
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
        default:
            break
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
