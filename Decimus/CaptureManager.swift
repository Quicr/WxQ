import AVFoundation
import UIKit
import os

public extension AVCaptureDevice {
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

protocol FrameListener: AVCaptureVideoDataOutputSampleBufferDelegate {
    var queue: DispatchQueue { get }
    var device: AVCaptureDevice { get }
    var codec: VideoCodecConfig? { get }
}

fileprivate extension FrameListener {
    func isEqual(_ other: FrameListener) -> Bool {
        self.queue == other.queue &&
        self.device == other.device &&
        self.codec == other.codec
    }
}

enum CaptureManagerError: Error {
    case multicamNotSuported
    case badSessionState
    case missingInput(AVCaptureDevice)
    case couldNotAdd(AVCaptureDevice)
    case noAudio
    case mainThread
}

/// Manages local media capture.
class CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private actor _Measurement: Measurement {
        var name: String = "CaptureManager"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var capturedFrames: UInt64 = 0
        private var dropped: UInt64 = 0
        private var captureDelay: Double = 0

        init(submitter: MetricsSubmitter) {
            Task {
                await submitter.register(measurement: self)
            }
        }

        func droppedFrame(timestamp: Date?) {
            self.dropped += 1
            record(field: "droppedFrames", value: self.dropped as AnyObject, timestamp: timestamp)
        }

        func capturedFrame(delayMs: Double?, timestamp: Date?) {
            self.capturedFrames += 1
            record(field: "capturedFrames", value: self.capturedFrames as AnyObject, timestamp: timestamp)
            if let delayMs = delayMs {
                record(field: "captureDelay", value: delayMs as AnyObject, timestamp: timestamp)
            }
        }
    }

    private static let logger = DecimusLogger(CaptureManager.self)

    /// Describe events that can happen to devices.
    enum DeviceEvent { case added; case removed }

    /// Callback of a device event.
    typealias DeviceChangeCallback = (AVCaptureDevice, DeviceEvent) -> Void

    private let session: AVCaptureMultiCamSession
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureOutput: AVCaptureDevice] = [:]
    private var startTime: [AVCaptureOutput: Date] = [:]
    private var connections: [AVCaptureDevice: AVCaptureConnection] = [:]
    private var multiVideoDelegate: [AVCaptureDevice: [FrameListener]] = [:]
    private let queue: DispatchQueue = .init(label: "com.cisco.quicr.Decimus.CaptureManager", qos: .userInteractive)
    private let notifier: NotificationCenter = .default
    private var observer: NSObjectProtocol?
    private let measurement: _Measurement?
    private var lastCapture: Date?
    private let granularMetrics: Bool
    private let warmupTime: TimeInterval = 0.75

    init(metricsSubmitter: MetricsSubmitter?, granularMetrics: Bool) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CaptureManagerError.multicamNotSuported
        }
        session = .init()
        session.automaticallyConfiguresApplicationAudioSession = false
        self.granularMetrics = granularMetrics
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        super.init()
    }

    func devices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(connections.keys)
    }

    func activeDevices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(try connections.keys.filter { try !isMuted(device: $0) })
    }

    func usingInput(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return inputs[device] != nil
    }

    func startCapturing() throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard !session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        assert(observer == nil)
        observer = notifier.addObserver(forName: .AVCaptureSessionRuntimeError,
                                        object: nil,
                                        queue: nil,
                                        using: onStartFailure)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.session.startRunning()
            if let observer = self.observer {
                self.notifier.removeObserver(observer)
            }
        }
    }

    @Sendable
    private nonisolated func onStartFailure(notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            Self.logger.error("AVCaptureSession failed for unknown reason", alert: true)
            return
        }
        Self.logger.error("AVCaptureSession failure: \(error.localizedDescription)", alert: true)
    }

    func stopCapturing() throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        self.session.stopRunning()
    }

    func toggleInput(device: AVCaptureDevice, toggled: @escaping (Bool) -> Void) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = self.connections[device] else { fatalError() }
        queue.async { [weak connection] in
            guard let connection = connection else { return }
            connection.isEnabled.toggle()
            toggled(connection.isEnabled)
        }
    }

    private func setBestDeviceFormat(device: AVCaptureDevice, config: VideoCodecConfig) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let allowableFormats = device.formats.reversed().filter { format in
            var supported = format.isMultiCamSupported &&
                            format.formatDescription.dimensions.width == config.width &&
                            format.formatDescription.dimensions.height == config.height
            if config.codec == .hevc {
                supported = supported && format.isVideoHDRSupported
            }
            return supported
        }

        guard let bestFormat = allowableFormats.first(where: { format in
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate == Float64(config.fps) }
        }) else {
            return
        }

        self.session.beginConfiguration()
        device.activeFormat = bestFormat
        device.automaticallyAdjustsVideoHDREnabled = false
        
        if config.codec == .hevc {
            if device.activeFormat.isVideoHDRSupported {
                device.isVideoHDREnabled = true
            }
            if device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020) {
                device.activeColorSpace = .HLG_BT2020
            }
        } else {
            if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
        }
        self.session.commitConfiguration()
    }

    private func addCamera(listener: FrameListener) throws {
        // Device is already setup, add this delegate.
        let device = listener.device

        if var cameraFrameListeners = self.multiVideoDelegate[device] {
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            guard let maxFramerateRange = ranges.max(by: { $0.maxFrameRate > $1.maxFrameRate }) else {
                throw "No framerate set"
            }

            if let config = listener.codec {
                if maxFramerateRange.maxFrameRate < Float64(config.fps) {
                    try setBestDeviceFormat(device: device, config: config)
                }
            }

            cameraFrameListeners.append(listener)
            self.multiVideoDelegate[device] = cameraFrameListeners
            return
        }

        // Setup device.
        if let config = listener.codec {
            try setBestDeviceFormat(device: device, config: config)
        }

        // Prepare IO.
        let input: AVCaptureDeviceInput = try .init(device: device)
        let output: AVCaptureVideoDataOutput = .init()
        let lossless420 = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
        output.videoSettings = [:]
        if output.availableVideoPixelFormatTypes.contains(where: {
            $0 == lossless420
        }) {
            output.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] = lossless420
        }
        let hdr: Bool
        if let config = listener.codec {
            hdr = config.codec == .hevc
        } else {
            hdr = true
        }
        output.videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        output.setSampleBufferDelegate(self, queue: self.queue)
        guard session.canAddInput(input),
              session.canAddOutput(output) else {
            throw CaptureManagerError.couldNotAdd(device)
        }
        let connection: AVCaptureConnection = .init(inputPorts: input.ports, output: output)

        // Apply these changes.
        session.beginConfiguration()
        session.addOutputWithNoConnections(output)
        session.addInputWithNoConnections(input)
        session.addConnection(connection)

        // Done.
        session.commitConfiguration()
        outputs[output] = device
        inputs[device] = input
        connections[device] = connection
        startTime[output] = .now
        self.multiVideoDelegate[device] = [listener]
    }

    func addInput(_ listener: FrameListener) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        Self.logger.info("Adding capture device: \(listener.device.localizedName)")

        if listener.device.deviceType == .builtInMicrophone {
            throw CaptureManagerError.noAudio
        }

        try addCamera(listener: listener)
    }

    func removeInput(listener: FrameListener) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }

        let device = listener.device
        guard var deviceListeners = self.multiVideoDelegate[device] else {
            throw CaptureManagerError.missingInput(device)
        }

        // Remove this frame listener from the list.
        deviceListeners.removeAll {
            listener.isEqual($0)
        }

        guard deviceListeners.count == 0 else {
            // There are other listeners still, so update and stop.
            self.multiVideoDelegate[device] = deviceListeners
            return
        }

        // There are no more delegates left, we should remove the device.
        self.multiVideoDelegate.removeValue(forKey: device)
        let input = inputs.removeValue(forKey: device)
        assert(input != nil)
        session.beginConfiguration()
        let connection = connections.removeValue(forKey: device)
        if connection != nil {
            session.removeConnection(connection!)
        }
        session.removeInput(input!)
        for output in outputs where output.value == device {
            outputs.removeValue(forKey: output.key)
        }
        session.commitConfiguration()
        Self.logger.info("Removing input for \(device.localizedName)")
    }

    func isMuted(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = connections[device] else {
            throw CaptureManagerError.missingInput(device)
        }
        return !connection.isEnabled
    }

    func addPreview(device: AVCaptureDevice, preview: AVCaptureVideoPreviewLayer) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = connections[device] else {
            throw CaptureManagerError.missingInput(device)
        }
        let previewConnection = AVCaptureConnection(inputPort: connection.inputPorts.first!, videoPreviewLayer: preview)
        guard self.session.canAddConnection(previewConnection) else {
            throw CaptureManagerError.couldNotAdd(device)
        }
        self.session.addConnection(previewConnection)
    }

    private func getDelegate(output: AVCaptureOutput) -> [FrameListener] {
        guard let device = self.outputs[output],
              let subscribers = self.multiVideoDelegate[device] else {
            return []
        }
        return subscribers
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Discard any frames prior to camera warmup.
        if let startTime = self.startTime[output] {
            guard Date.now.timeIntervalSince(startTime) > self.warmupTime else { return }
            self.startTime.removeValue(forKey: output)
        }

        if let measurement = self.measurement {
            let now: Date = .now
            let delay: Double?
            if let last = self.lastCapture {
                delay = now.timeIntervalSince(last) * 1000
            } else {
                delay = nil
            }
            self.lastCapture = now
            Task(priority: .utility) {
                await measurement.capturedFrame(delayMs: self.granularMetrics ? delay : nil,
                                                timestamp: self.granularMetrics ? now : nil)
            }
        }

        let cameraFrameListeners = getDelegate(output: output)
        for listener in cameraFrameListeners {
            listener.queue.async {
                listener.captureOutput?(output, didOutput: sampleBuffer, from: connection)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let cameraFrameListeners = getDelegate(output: output)
        for listener in cameraFrameListeners {
            listener.queue.async {
                listener.captureOutput?(output, didOutput: sampleBuffer, from: connection)
            }
        }
    }
}

extension UIDeviceOrientation {
    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
}
