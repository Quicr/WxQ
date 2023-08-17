import Foundation
import AVFoundation

actor VideoMeasurement: Measurement {
    var name: String = "VideoPublication"
    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    private var bytes: UInt64 = 0
    private var pixels: UInt64 = 0

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

    required init(namespace: QuicrNamespace,
                  publishDelegate: QPublishObjectDelegateObjC,
                  sourceID: SourceIDType,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter,
                  errorWriter: ErrorWriter) throws {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))
        self.errorWriter = errorWriter

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
        
        let onEncodedData: H264Encoder.EncodedCallback = { [weak publishDelegate, measurement, namespace] data, datalength, flag in
            let timestamp = Date.now
            Task(priority: .utility) {
                await measurement.sentBytes(sent: UInt64(datalength), timestamp: timestamp)
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

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32 {
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
        Task(priority: .utility) {
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
