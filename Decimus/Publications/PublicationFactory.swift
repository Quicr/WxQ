import Foundation
import AVFoundation

class PublicationFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             QPublishObjectDelegateObjC,
                                             SourceIDType,
                                             CodecConfig,
                                             MetricsSubmitter?) throws -> Publication

    private let opusWindowSize: OpusWindowSize
    private let reliability: MediaReliability
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine
    private let ptt: PushToTalkManager?
    private let conferenceId: UInt32
    private let logger = DecimusLogger(PublicationFactory.self)

    init(opusWindowSize: OpusWindowSize,
         reliability: MediaReliability,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         ptt: PushToTalkManager?,
         conferenceId: UInt32) {
        self.opusWindowSize = opusWindowSize
        self.reliability = reliability
        self.engine = engine
        self.granularMetrics = granularMetrics
        self.ptt = ptt
        self.conferenceId = conferenceId
    }

    func create(_ namespace: QuicrNamespace,
                publishDelegate: QPublishObjectDelegateObjC,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter?) throws -> Publication {

        switch config.codec {
        case .h264, .hevc:
            guard let config = config as? VideoCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            // TODO: SourceID from manifest is bogus, do this for now to retrieve valid device
            let device: AVCaptureDevice
            if #available(iOS 17.0, tvOS 17.0, *) {
                guard let preferred = AVCaptureDevice.systemPreferredCamera else {
                    throw H264PublicationError.noCamera(sourceID)
                }
                device = preferred
            } else {
                guard let preferred = AVCaptureDevice.default(for: .video) else {
                    throw H264PublicationError.noCamera(sourceID)
                }
                device = preferred
            }
            let encoder = try VTEncoder(config: config,
                                        verticalMirror: device.position == .front,
                                        emitStartCodes: config.codec == .hevc)
            return try H264Publication(namespace: namespace,
                                       publishDelegate: publishDelegate,
                                       sourceID: sourceID,
                                       config: config,
                                       metricsSubmitter: metricsSubmitter,
                                       reliable: reliability.video.publication,
                                       granularMetrics: self.granularMetrics,
                                       encoder: encoder,
                                       device: device)
        case .opus:
            // TODO: Handle opus audio vs. PTT channel.
            guard let config = config as? AudioCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }

            // Opus.
            let opus = try OpusPublication(namespace: namespace,
                                           publishDelegate: publishDelegate,
                                           sourceID: sourceID,
                                           metricsSubmitter: metricsSubmitter,
                                           opusWindowSize: opusWindowSize,
                                           reliable: reliability.audio.publication,
                                           engine: self.engine,
                                           granularMetrics: self.granularMetrics,
                                           config: config)

            // PTT.
            if let ptt = self.ptt {
                opus.stopProcessing()
                let uuid = self.conferenceId.uuid
                var channel = ptt.getChannel(uuid: uuid)
                if channel == nil {
                    let created = PushToTalkChannel(uuid: uuid, createdFrom: .request)
                    channel = created
                    Task(priority: .medium) {
                        do {
                            try await ptt.registerChannel(created)
                        } catch {
                            self.logger.error("Failed to register channel: \(error.localizedDescription)")
                        }
                    }
                }
                channel!.publication = opus
            }
            return opus
        default:
            throw CodecError.noCodecFound(config.codec)
        }
    }
}
