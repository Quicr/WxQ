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
    private let config: SubscriptionConfig
    private static let logger = DecimusLogger(CallController.self)

    init(metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         config: SubscriptionConfig,
         engine: DecimusAudioEngine,
         granularMetrics: Bool) throws {
        self.config = config
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
                                                   engine: engine,
                                                   granularMetrics: granularMetrics,
                                                   hevcOverride: config.hevcOverride)
    }

    func connect(config: CallConfig) async throws {
        let shadowRtt = UInt32(self.config.quicWifiShadowRttUs * 1_000_000)
        let transportConfig: TransportConfig = .init(tls_cert_filename: nil,
                                                     tls_key_filename: nil,
                                                     time_queue_init_queue_size: 1000,
                                                     time_queue_max_duration: 5000,
                                                     time_queue_bucket_interval: 1,
                                                     time_queue_size_rx: 1000,
                                                     debug: false,
                                                     quic_cwin_minimum: self.config.quicCwinMinimumKiB * 1024,
                                                     quic_wifi_shadow_rtt_us: shadowRtt,
                                                     pacing_decrease_threshold_Bps: 16000,
                                                     pacing_increase_threshold_Bps: 16000)
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
        self.setSubscriptionSingleOrdered(self.config.isSingleOrderedSub)
        self.setPublicationSingleOrdered(self.config.isSingleOrderedPub)
        super.updateManifest(String(data: manifestJSON, encoding: .utf8)!)
    }
}
