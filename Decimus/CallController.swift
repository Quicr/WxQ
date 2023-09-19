import CoreMedia
import AVFoundation
import os

enum CallError: Error {
    case failedToConnect(Int32)
}

class MutableWrapper<T> {
    var value: T
    init(value: T) {
        self.value = value
    }
}

class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {
    private let engine: AVAudioEngine
    private var blocks: MutableWrapper<[AVAudioSinkNodeReceiverBlock]> = .init(value: [])
    private let config: SubscriptionConfig
    private static let logger = DecimusLogger(CallController.self)
    private static let opusSampleRates: [Double] = [.opus8khz, .opus12khz, .opus16khz, .opus24khz, .opus48khz]

    init(metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         config: SubscriptionConfig,
         engine: AVAudioEngine,
         granularMetrics: Bool) throws {
        try AVAudioSession.configureForDecimus()
        self.engine = engine
        self.config = config

        // Enable voice processing.
        if !engine.outputNode.isVoiceProcessingEnabled {
            try engine.outputNode.setVoiceProcessingEnabled(true)
        }
        guard engine.outputNode.isVoiceProcessingEnabled,
              engine.inputNode.isVoiceProcessingEnabled else {
                  throw "Voice processing missmatch"
        }

        // Ducking.
#if compiler(>=5.9)
        if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, visionOS 1.0, *) {
            let ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true,
                                                                                      duckingLevel: .min)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }
#endif

        // We want to override the format to something usable.
        let current = AVAudioSession.sharedInstance().sampleRate
        let desiredSampleRate: Double = .opus48khz
        guard engine.inputNode.numberOfOutputs == 1 else {
            throw "Input node had >1 output busses. Report this!"
        }
        let commonFormat = engine.inputNode.outputFormat(forBus: 0).commonFormat
        let desiredFormat: AVAudioFormat = .init(commonFormat: commonFormat,
                                  sampleRate: desiredSampleRate,
                                  channels: 1,
                                  interleaved: true)!

        // Capture microphone audio.
        let sink: AVAudioSinkNode = .init { [blocks] timestamp, frames, data in
            var success = true
            for block in blocks.value {
                success = success && block(timestamp, frames, data) == .zero
            }
            return success ? .zero : 1
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: desiredFormat)

        super.init { level, msg, alert in
            CallController.logger.log(level: DecimusLogger.LogLevel(rawValue: level)!, msg!, alert: alert)
        }

        self.subscriberDelegate = SubscriberDelegate(submitter: metricsSubmitter,
                                                     config: config,
                                                     engine: engine,
                                                     granularMetrics: granularMetrics)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager,
                                                   opusWindowSize: config.opusWindowSize,
                                                   reliability: config.mediaReliability,
                                                   blocks: blocks,
                                                   format: desiredFormat,
                                                   granularMetrics: granularMetrics)
    }

    func connect(config: CallConfig) async throws {
        let transportConfig: TransportConfig = .init(tls_cert_filename: nil,
                                                     tls_key_filename: nil,
                                                     time_queue_init_queue_size: 1000,
                                                     time_queue_max_duration: 1000,
                                                     time_queue_bucket_interval: 1,
                                                     time_queue_size_rx: 1000,
                                                     debug: false,
                                                     quic_cwin_minimum: self.config.quicCwinMinimumKiB * 1024)
        let error = super.connect(config.address,
                                  port: config.port,
                                  protocol: config.connectionProtocol.rawValue,
                                  config: transportConfig)
        guard error == .zero else {
            throw CallError.failedToConnect(error)
        }

        let manifest = try await ManifestController.shared.getManifest(confId: config.conferenceID, email: config.email)

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted

        let manifestJSON = try jsonEncoder.encode(manifest)
        super.updateManifest(String(data: manifestJSON, encoding: .utf8)!)

        assert(!engine.isRunning)
        try engine.start()
    }

    func disconnect() throws {
        engine.stop()
        super.close()
    }
}
