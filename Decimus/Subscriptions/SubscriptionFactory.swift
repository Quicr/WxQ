import Foundation

// swiftlint:disable identifier_name
enum SubscriptionFactoryError: Error {
    case NoFactory
    case InvalidCodecConfig(Any)
}
// swiftlint:enable identifier_name

enum VideoBehaviour: CaseIterable, Identifiable, Codable {
    case artifact
    case freeze
    var id: Self { self }
}

struct Reliability: Codable {
    var publication: Bool
    var subscription: Bool

    init(publication: Bool, subscription: Bool) {
        self.publication = publication
        self.subscription = subscription
    }

    init(both: Bool) {
        self.init(publication: both, subscription: both)
    }
}

struct MediaReliability: Codable {
    var audio: Reliability
    var video: Reliability

    init() {
        audio = .init(both: false)
        video = .init(both: true)
    }
}

struct SubscriptionConfig: Codable {
    var jitterMax: UInt
    var jitterDepth: UInt
    var opusWindowSize: TimeInterval
    var videoBehaviour: VideoBehaviour
    var voiceProcessing: Bool
    var mediaReliability: MediaReliability
    init() {
        jitterMax = 500
        jitterDepth = 60
        opusWindowSize = 0.01
        videoBehaviour = .freeze
        voiceProcessing = true
        mediaReliability = .init()
    }
}

class SubscriptionFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             CodecConfig,
                                             MetricsSubmitter?,
                                             ErrorWriter) throws -> Subscription?

    private lazy var factories: [CodecType: FactoryCallbackType] = [
        .h264: { [weak self] in
            guard let self = self else { throw SubscriptionFactoryError.NoFactory }
            guard let config = $1 as? VideoCodecConfig else {
                throw SubscriptionFactoryError.InvalidCodecConfig(type(of: $1))
            }

            let namegate: NameGate
            switch self.config.videoBehaviour {
            case .artifact:
                namegate = AllowAllNameGate()
            case .freeze:
                namegate = SequentialObjectBlockingNameGate()
            }

            return H264Subscription(namespace: $0,
                                    config: config,
                                    participants: self.participants,
                                    metricsSubmitter: $2,
                                    errorWriter: $3,
                                    namegate: namegate,
                                    reliable: self.config.mediaReliability.video.subscription)
        },
        .opus: { [weak self] in
            guard let self = self else { throw SubscriptionFactoryError.NoFactory }
            guard let config = $1 as? AudioCodecConfig else {
                throw SubscriptionFactoryError.InvalidCodecConfig(type(of: $1))
            }
            return try OpusSubscription(namespace: $0,
                                        player: self.player,
                                        config: config,
                                        submitter: $2,
                                        errorWriter: $3,
                                        jitterDepth: self.config.jitterDepth,
                                        jitterMax: self.config.jitterMax,
                                        opusWindowSize: self.config.opusWindowSize,
                                        reliable: self.config.mediaReliability.audio.subscription)
        }
    ]

    private unowned let participants: VideoParticipants
    private unowned let player: FasterAVEngineAudioPlayer
    private let config: SubscriptionConfig
    init(participants: VideoParticipants, player: FasterAVEngineAudioPlayer, config: SubscriptionConfig) {
        self.participants = participants
        self.player = player
        self.config = config
    }

    func create(_ namespace: QuicrNamespace,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter?,
                errorWriter: ErrorWriter) throws -> Subscription? {
        guard let factory = factories[config.codec] else {
            throw CodecError.noCodecFound(config.codec)
        }

        return try factory(namespace, config, metricsSubmitter, errorWriter)
    }
}
