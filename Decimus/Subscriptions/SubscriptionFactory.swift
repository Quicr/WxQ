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
    var jitterMaxTime: TimeInterval
    var jitterDepthTime: TimeInterval
    var opusWindowSize: OpusWindowSize
    var videoBehaviour: VideoBehaviour
    var mediaReliability: MediaReliability
    var quicCwinMinimumKiB: UInt64
    var videoJitterBuffer: VideoJitterBuffer.Config
    var isSingleOrderedSub: Bool
    var isSingleOrderedPub: Bool
    var simulreceive: SimulreceiveMode
    var qualityMissThreshold: Int
    var pauseMissThreshold: Int
    var timeQueueTTL: Int
    var chunkSize: UInt32
    var bitrateType: BitrateType
    var useResetWaitCC: Bool
    var useBBR: Bool
    var enableQlog: Bool
    var pauseResume: Bool
    var quicrLogs: Bool
    var quicPriorityLimit: UInt8
    var doSFrame: Bool

    init() {
        jitterMaxTime = 0.2
        jitterDepthTime = 0.2
        opusWindowSize = .twentyMs
        videoBehaviour = .freeze
        mediaReliability = .init()
        quicCwinMinimumKiB = 8
        videoJitterBuffer = .init(mode: .interval, minDepth: jitterDepthTime)
        isSingleOrderedSub = false
        isSingleOrderedPub = false
        simulreceive = .enable
        qualityMissThreshold = 3
        pauseMissThreshold = 30
        timeQueueTTL = 500
        chunkSize = 3000
        bitrateType = .average
        useResetWaitCC = false
        useBBR = true
        enableQlog = false
        pauseResume = false
        quicrLogs = false
        quicPriorityLimit = 0
        doSFrame = true
    }
}

class SubscriptionFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             CodecConfig,
                                             MetricsSubmitter?) throws -> QSubscriptionDelegateObjC?

    private let participants: VideoParticipants
    private let engine: DecimusAudioEngine
    private let config: SubscriptionConfig
    private let granularMetrics: Bool
    private weak var controller: CallController?
    init(participants: VideoParticipants,
         engine: DecimusAudioEngine,
         config: SubscriptionConfig,
         granularMetrics: Bool,
         controller: CallController) {
        self.participants = participants
        self.engine = engine
        self.config = config
        self.granularMetrics = granularMetrics
        self.controller = controller
    }

    func create(_ sourceId: SourceIDType,
                profileSet: QClientProfileSet,
                metricsSubmitter: MetricsSubmitter?) throws -> QSubscriptionDelegateObjC? {
        // Supported codec sets.
        let videoCodecs: Set<CodecType> = [.h264, .hevc]
        let opusCodecs: Set<CodecType> = [.opus]

        // Resolve profile sets to config.
        var foundCodecs: [CodecType] = []
        for profileIndex in 0..<profileSet.profilesCount {
            let profile = profileSet.profiles.advanced(by: profileIndex).pointee
            let config = CodecFactory.makeCodecConfig(from: .init(cString: profile.qualityProfile),
                                                      bitrateType: config.bitrateType)
            foundCodecs.append(config.codec)
        }
        let found = Set(foundCodecs)

        if found.isSubset(of: videoCodecs) {
            return try VideoSubscription(sourceId: sourceId,
                                         profileSet: profileSet,
                                         participants: self.participants,
                                         metricsSubmitter: metricsSubmitter,
                                         videoBehaviour: self.config.videoBehaviour,
                                         reliable: self.config.mediaReliability.video.subscription,
                                         granularMetrics: self.granularMetrics,
                                         jitterBufferConfig: self.config.videoJitterBuffer,
                                         simulreceive: self.config.simulreceive,
                                         qualityMissThreshold: self.config.qualityMissThreshold,
                                         pauseMissThreshold: self.config.pauseMissThreshold,
                                         controller: self.controller,
                                         pauseResume: self.config.pauseResume)
        }

        if found.isSubset(of: opusCodecs) {
            return try OpusSubscription(sourceId: sourceId,
                                        profileSet: profileSet,
                                        engine: self.engine,
                                        submitter: metricsSubmitter,
                                        jitterDepth: self.config.jitterDepthTime,
                                        jitterMax: self.config.jitterMaxTime,
                                        opusWindowSize: self.config.opusWindowSize,
                                        reliable: self.config.mediaReliability.audio.subscription,
                                        granularMetrics: self.granularMetrics)
        }

        throw CodecError.unsupportedCodecSet(found)
    }
}
