import Foundation
import AVFoundation

actor VideoMeasurement: Measurement {
    var name: String = "VideoPublication"
    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    private var bytes: UInt64 = 0
    private var pixels: UInt64 = 0
    private var publishedFrames: UInt64 = 0
    private var capturedFrames: UInt64 = 0
    private var dropped: UInt64 = 0
    private var captureDelay: Double = 0
    private var publishDelay: Double = 0

    init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
        tags["namespace"] = namespace
        Task {
            await submitter.register(measurement: self)
        }
    }

    func sentBytes(sent: UInt64, timestamp: Date?) {
        self.bytes += sent
        record(field: "sentBytes", value: self.bytes as AnyObject, timestamp: timestamp)
    }

    func sentPixels(sent: UInt64, timestamp: Date?) {
        self.pixels += sent
        record(field: "sentPixels", value: self.pixels as AnyObject, timestamp: timestamp)
    }

    func droppedFrame(timestamp: Date?) {
        self.dropped += 1
        record(field: "droppedFrames", value: self.dropped as AnyObject, timestamp: timestamp)
    }

    func publishedFrame(timestamp: Date?) {
        self.publishedFrames += 1
        record(field: "publishedFrames", value: self.publishedFrames as AnyObject, timestamp: timestamp)
    }

    func capturedFrame(timestamp: Date?) {
        self.capturedFrames += 1
        record(field: "capturedFrames", value: self.capturedFrames as AnyObject, timestamp: timestamp)
    }

    func captureDelay(delayMs: Double, timestamp: Date?) {
        record(field: "captureDelay", value: delayMs as AnyObject, timestamp: timestamp)
    }

    func publishDelay(delayMs: Double, timestamp: Date?) {
        record(field: "publishDelay", value: delayMs as AnyObject, timestamp: timestamp)
    }
}

enum H264PublicationError: Error {
    case noCamera(SourceIDType)
}

class H264Publication: NSObject, AVCaptureDevicePublication, FrameListener {
    private let measurement: VideoMeasurement

    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?
    let device: AVCaptureDevice
    let queue: DispatchQueue

    private var encoder: H264Encoder
    private let errorWriter: ErrorWriter
    private let reliable: Bool
    private var lastCapture: Date?
    private var lastPublish: WrappedOptional<Date> = .init(nil)

    required init(namespace: QuicrNamespace,
                  publishDelegate: QPublishObjectDelegateObjC,
                  sourceID: SourceIDType,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter,
                  errorWriter: ErrorWriter,
                  reliable: Bool) throws {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))
        self.errorWriter = errorWriter
        self.reliable = reliable

        // TODO: SourceID from manifest is bogus, do this for now to retrieve valid device
        // guard let device = AVCaptureDevice.init(uniqueID: sourceId) else {
        #if !targetEnvironment(macCatalyst)
        guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,
                                                                          .builtInTelephotoCamera],
                                                            mediaType: .video,
                                                            position: .front).devices.first else {
            throw H264PublicationError.noCamera(sourceID)
        }
        #else
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw H264PublicationError.noCamera(sourceID)
        }
        #endif
        self.device = device

        let onEncodedData: H264Encoder.EncodedCallback = { [weak publishDelegate, measurement, namespace, lastPublish] data, datalength, flag in
            let timestamp = Date.now
            let delay: Double?
            if let last = lastPublish.value {
                delay = timestamp.timeIntervalSince(last) * 1000
            } else {
                delay = nil
            }
            lastPublish.value = timestamp
            Task(priority: .utility) {
                if let delay = delay {
                    await measurement.publishDelay(delayMs: delay, timestamp: timestamp)
                }
                await measurement.sentBytes(sent: UInt64(datalength), timestamp: timestamp)
                await measurement.publishedFrame(timestamp: timestamp)
            }
            publishDelegate?.publishObject(namespace, data: data, length: datalength, group: flag)
        }
        self.encoder = try .init(config: config, verticalMirror: device.position == .front, callback: onEncodedData)
        super.init()

        log("Registered H264 publication for source \(sourceID)")
    }

    deinit {
        log("deinit")
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!, reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    func publish(_ flag: Bool) {}

    /// This callback fires if a frame was dropped.
    @objc(captureOutput:didDropSampleBuffer:fromConnection:)
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var mode: CMAttachmentMode = 0
        let reason = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: &mode)

        log(String(describing: reason))
        let now = Date.now
        Task(priority: .utility) {
            await self.measurement.droppedFrame(timestamp: now)
        }
    }

    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Report pixel metrics.
        guard let buffer = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixels: UInt64 = .init(width * height)
        let date = Date.now
        let delay: Double?
        if let last = self.lastCapture {
            delay = date.timeIntervalSince(last) * 1000
        } else {
            delay = nil
        }
        lastCapture = date
        Task(priority: .utility) {
            if let delay = delay {
                await measurement.captureDelay(delayMs: delay, timestamp: date)
            }
            await measurement.capturedFrame(timestamp: date)
            await measurement.sentPixels(sent: pixels, timestamp: date)
        }

        // Encode.
        do {
            try encoder.write(sample: sampleBuffer)
        } catch {
            self.errorWriter.writeError("Failed to encode frame: \(error.localizedDescription)")
        }
    }
}
