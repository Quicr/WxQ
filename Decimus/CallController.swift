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

actor ManifestHolder {
    var currentManifest: Manifest?
    func setManifest(manifest: Manifest) {
        self.currentManifest = manifest
    }
}

class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {
    private let config: SubscriptionConfig
    private static let logger = DecimusLogger(CallController.self)
    let manifest = ManifestHolder()

    init(metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         config: SubscriptionConfig,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         ptt: PushToTalkManager?,
         conferenceId: UInt32) throws {
        self.config = config
        super.init { level, msg, alert in
            CallController.logger.log(level: DecimusLogger.LogLevel(rawValue: level)!, msg!, alert: alert)
        }
        self.subscriberDelegate = SubscriberDelegate(submitter: metricsSubmitter,
                                                     config: config,
                                                     engine: engine,
                                                     granularMetrics: granularMetrics,
                                                     controller: self)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager,
                                                   opusWindowSize: config.opusWindowSize,
                                                   reliability: config.mediaReliability,
                                                   engine: engine,
                                                   granularMetrics: granularMetrics,
                                                   bitrateType: config.bitrateType,
                                                   ptt: ptt,
                                                   conferenceId: conferenceId)
    }

    func connect(config: CallConfig) async throws {
        let url: URL
        #if targetEnvironment(macCatalyst)
        url = .downloadsDirectory
        #else
        url = .documentsDirectory
        #endif
        try url.path.withCString { dir in
            let transportConfig: TransportConfig = .init(tls_cert_filename: nil,
                                                         tls_key_filename: nil,
                                                         time_queue_init_queue_size: 1000,
                                                         time_queue_max_duration: 5000,
                                                         time_queue_bucket_interval: 1,
                                                         time_queue_rx_size: UInt32(self.config.timeQueueTTL),
                                                         debug: true,
                                                         quic_cwin_minimum: self.config.quicCwinMinimumKiB * 1024,
                                                         quic_wifi_shadow_rtt_us: 0,
                                                         pacing_decrease_threshold_Bps: 16000,
                                                         pacing_increase_threshold_Bps: 16000,
                                                         idle_timeout_ms: 15000,
                                                         use_reset_wait_strategy: self.config.useResetWaitCC,
                                                         use_bbr: self.config.useBBR,
                                                         quic_qlog_path: self.config.enableQlog ? dir : nil,
                                                         quic_priority_limit: self.config.quicPriorityLimit)
            let error = super.connect(config.email,
                                      relay: config.address,
                                      port: config.port,
                                      protocol: config.connectionProtocol.rawValue,
                                      chunk_size: self.config.chunkSize,
                                      config: transportConfig,
                                      useParentLogger: self.config.quicrLogs)
            guard error == .zero else {
                throw CallError.failedToConnect(error)
            }
        }

        let manifest = try await ManifestController.shared.getManifest(confId: config.conferenceID, email: config.email)
        await self.manifest.setManifest(manifest: manifest)

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted

        let manifestJSON = try jsonEncoder.encode(manifest)
        self.setSubscriptionSingleOrdered(self.config.isSingleOrderedSub)
        self.setPublicationSingleOrdered(self.config.isSingleOrderedPub)
        super.updateManifest(String(data: manifestJSON, encoding: .utf8)!)
    }

    enum CallControllerError: Error {
        case malformed
    }

    func fetchSwitchingSets() throws -> [String] {
        guard let sets = self.getSwitchingSets() as NSArray as? [String] else {
            throw CallControllerError.malformed
        }
        return sets
    }

    func fetchSubscriptions(sourceId: String) throws -> [String] {
        guard let subs = self.getSubscriptions(sourceId) as NSArray as? [String] else {
            throw CallControllerError.malformed
        }
        return subs
    }

    func fetchPublications() throws -> [PublicationReport] {
        guard let pubs = self.getPublications() as NSArray as? [PublicationReport] else {
            throw CallControllerError.malformed
        }
        return pubs
    }
}
