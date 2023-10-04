import AVFoundation
import os

class H264Subscription: Subscription {
    private static let logger = DecimusLogger(H264Subscription.self)

    private actor _Measurement: Measurement {
        var name: String = "H264Subscription"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0
        private var decoded: UInt64 = 0

        init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
            tags["namespace"] = namespace
            Task(priority: .utility) {
                await submitter.register(measurement: self)
            }
        }

        func receivedFrame(timestamp: Date?) {
            self.frames += 1
            record(field: "receivedFrames", value: self.frames as AnyObject, timestamp: timestamp)
        }

        func decodedFrame(timestamp: Date?) {
            self.decoded += 1
            record(field: "decodedFrames", value: self.decoded as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: Int, timestamp: Date?) {
            self.bytes += UInt64(received)
            record(field: "receivedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
        }

        func receiveDelta(delta: Double, timestamp: Date?) {
            record(field: "receiveDelta", value: delta as AnyObject, timestamp: timestamp)
        }

        func decodeDelta(delta: Double, timestamp: Date?) {
            record(field: "decodeDelta", value: delta as AnyObject, timestamp: timestamp)
        }
    }

    internal let namespace: QuicrNamespace
    private var decoder: H264Decoder?
    private unowned let participants: VideoParticipants
    private let measurement: _Measurement?
    private var lastGroup: UInt32?
    private var lastObject: UInt16?
    private let namegate: NameGate
    private let reliable: Bool
    private var jitterBuffer: VideoJitterBuffer?
    private var lastReceive: Date?
    private var lastDecode: Date?
    private let granularMetrics: Bool
    private var dequeueTask: Task<(), Never>?
    private var dequeueBehaviour: VideoDequeuer?
    private let jitterBufferConfig: VideoJitterBuffer.Config
    private let config: VideoCodecConfig
    private var orientation: AVCaptureVideoOrientation?
    private var verticalMirror: Bool = false
    private var currentFormat: CMFormatDescription?

    private lazy var seiCallback: H264Utilities.SEICallback = { [weak self] data in
        guard let self = self else { return }
        let seiType = data[5]
        switch seiType {
        case 0x2f:
            // Video orientation.
            assert(data[6] == 2)
            self.orientation = .init(rawValue: .init(data[7]))
            self.verticalMirror = data[8] == 1
        default:
            Self.logger.info("Unhandled SEI App type: \(seiType)")
        }
    }

    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config) {
        self.namespace = namespace
        self.config = config
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.namegate = namegate
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig

        // Create the video jitter buffer if requested.
        if jitterBufferConfig.mode != .none {
            let duration = 1 / Double(config.fps)
            if jitterBufferConfig.mode == .pid {
                self.dequeueBehaviour = PIDDequeuer(targetDepth: jitterBufferConfig.minDepth,
                                                    frameDuration: duration,
                                                    kp: 0.01,
                                                    ki: 0.001,
                                                    kd: 0.001)
            }
            self.jitterBuffer = .init(namespace: namespace,
                                      frameDuration: duration,
                                      metricsSubmitter: metricsSubmitter,
                                      sort: !reliable,
                                      minDepth: jitterBufferConfig.minDepth)
        }

        // Create the H264 decoder.
        self.decoder = .init(config: config, callback: { [weak self] sample in
            guard let self = self else { return }
            self.showDecodedImage(decoded: sample,
                                  orientation: self.orientation,
                                  verticalMirror: self.verticalMirror)
        })

        Self.logger.info("Subscribed to H264 stream")
    }

    deinit {
        try? participants.removeParticipant(identifier: namespace)
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 qualityProfile: String!,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return SubscriptionError.None.rawValue
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.NoDecoder.rawValue
    }

    func subscribedObject(_ data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32 {
        // Metrics.
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? .now : nil
            let delta: Double?
            if granularMetrics {
                if let last = lastReceive {
                    delta = now!.timeIntervalSince(last) * 1000
                } else {
                    delta = nil
                }
                lastReceive = now
            } else {
                delta = nil
            }

            Task(priority: .utility) {
                if let delta = delta {
                    await measurement.receiveDelta(delta: delta, timestamp: now)
                }
                await measurement.receivedFrame(timestamp: now)
                await measurement.receivedBytes(received: length, timestamp: now)
            }
        }

        // Update keep alive timer for showing video.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            participant.lastUpdated = .now()
        }

        if let jitterBuffer = self.jitterBuffer {
            let videoFrame: VideoFrame = .init(groupId: groupId, objectId: objectId, data: .init(bytes: data, count: length))
            _ = jitterBuffer.write(videoFrame: videoFrame)
            if self.dequeueTask == nil {
                // We know everything to create the interval dequeuer at this point.
                if self.dequeueBehaviour == nil && self.jitterBufferConfig.mode == .interval {
                    self.dequeueBehaviour = IntervalDequeuer(minDepth: self.jitterBufferConfig.minDepth,
                                                             frameDuration: 1 / Double(self.config.fps),
                                                             firstWriteTime: .now)
                }

                // Start the frame dequeue task.
                self.dequeueTask = .init(priority: .high) { [weak self] in
                    while !Task.isCancelled {
                        guard let self = self else { return }

                        // Wait until we expect to have a frame available.
                        let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                        if let pid = self.dequeueBehaviour! as? PIDDequeuer {
                            pid.currentDepth = jitterBuffer.getDepth()
                        }
                        let waitTime = self.dequeueBehaviour!.calculateWaitTime() // Dequeue behaviour must exist at this point.
                        let ns = waitTime * 1_000_000_000
                        if ns > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(ns))
                        }

                        // Attempt to dequeue a frame.
                        if let frame = jitterBuffer.read() {
                            // Interval dequeuer needs to know where we are.
                            // TODO: With frame timestamps, we won't need this.
                            if self.jitterBufferConfig.mode == .interval {
                                let interval = self.dequeueBehaviour as! IntervalDequeuer
                                interval.dequeuedCount += 1
                            }
                            self.decode(frame: frame)
                        }
                    }
                }
            }
        } else {
            let zeroCopy: Data = .init(bytesNoCopy: .init(mutating: data), count: length, deallocator: .none)
            let videoFrame: VideoFrame = .init(groupId: groupId, objectId: objectId, data: zeroCopy)
            decode(frame: videoFrame)
        }
        return SubscriptionError.None.rawValue
    }

    private func decode(frame: VideoFrame) {
        // Should we feed this frame to the decoder?
        guard namegate.handle(groupId: frame.groupId,
                              objectId: frame.objectId,
                              lastGroup: lastGroup,
                              lastObject: lastObject) else {
            var group: String = "None"
            if let lastGroup = lastGroup {
                group = String(lastGroup)
            }
            var object: String = "None"
            if let lastObject = lastObject {
                object = String(lastObject)
            }
            // Self.logger.warning("[\(frame.groupId)] (\(frame.objectId)) Ignoring blocked object. Had: [\(group)] (\(object))")

            // If we've thrown away a frame, we should flush to the next group.
            let targetGroup = frame.groupId + 1
            self.jitterBuffer?.flushTo(targetGroup: targetGroup)
            return
        }

        lastGroup = frame.groupId
        lastObject = frame.objectId

        // Decode.
        do {
            let timeInfo = CMSampleTimingInfo(duration: .init(value: 1, timescale: CMTimeScale(self.config.fps)),
                                              presentationTimeStamp: .invalid,
                                              decodeTimeStamp: .invalid)
            var mutable = frame
            let depacketized = try H264Utilities.depacketize(&mutable.data,
                                                             timeInfo: timeInfo,
                                                             format: &self.currentFormat,
                                                             sei: self.seiCallback)
            for sample in depacketized {
                try decoder!.write(sample)
            }
        } catch {
            Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
        }
    }

    private func showDecodedImage(decoded: CMSampleBuffer,
                                  orientation: AVCaptureVideoOrientation?,
                                  verticalMirror: Bool) {
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? .now : nil
            let delta: Double?
            if self.granularMetrics {
                if let last = lastDecode {
                    delta = now!.timeIntervalSince(last) * 1000
                } else {
                    delta = nil
                }
                lastDecode = now
            } else {
                delta = nil
            }
            Task(priority: .utility) {
                if let delta = delta {
                    await measurement.decodeDelta(delta: delta, timestamp: now)
                }
                await measurement.decodedFrame(timestamp: now)
            }
        }

        // FIXME: Driving from proper timestamps probably preferable.
        let array: CFArray! = CMSampleBufferGetSampleAttachmentsArray(decoded, createIfNecessary: true)
        let dictionary: CFMutableDictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0),
                                                            to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())

        // Enqueue the buffer.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            guard let layer = participant.view.layer else {
                fatalError()
            }
            guard layer.status != .failed else {
                Self.logger.error("Layer failed: \(layer.error!)")
                layer.flush()
                return
            }
            layer.transform = orientation?.toTransform(verticalMirror) ?? CATransform3DIdentity
            layer.enqueue(decoded)
            participant.lastUpdated = .now()
        }
    }
}

extension AVCaptureVideoOrientation {
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
