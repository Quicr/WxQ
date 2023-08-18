import Foundation

class PublicationFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             QPublishObjectDelegateObjC,
                                             SourceIDType,
                                             CodecConfig,
                                             MetricsSubmitter,
                                             ErrorWriter) throws -> Publication

    private let opusWindowSize: TimeInterval
    private let reliability: MediaReliability

    init(opusWindowSize: TimeInterval, reliability: MediaReliability) {
        self.opusWindowSize = opusWindowSize
        self.reliability = reliability
    }

    private lazy var factories: [CodecType: FactoryCallbackType] = [
        .h264: { [weak self] in
            guard let config = $3 as? VideoCodecConfig else { fatalError() }
            guard let reliable = self?.reliability.video.publication else { fatalError() }
            let publication = try H264Publication(namespace: $0,
                                                  publishDelegate: $1,
                                                  sourceID: $2,
                                                  config: config,
                                                  metricsSubmitter: $4,
                                                  errorWriter: $5,
                                                  reliable: reliable)

            return publication
        },
        .opus: { [opusWindowSize, reliability] in
            guard let config = $3 as? AudioCodecConfig else { fatalError() }
            return try OpusPublication(namespace: $0,
                                       publishDelegate: $1,
                                       sourceID: $2,
                                       metricsSubmitter: $4,
                                       errorWriter: $5,
                                       opusWindowSize: opusWindowSize,
                                       reliable: reliability.audio.publication)
        }
    ]

    // swiftlint:disable function_parameter_count - Dependency injection.
    func create(_ namespace: QuicrNamespace,
                publishDelegate: QPublishObjectDelegateObjC,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter,
                errorWriter: ErrorWriter) throws -> Publication {
        guard let factory = factories[config.codec] else {
            throw CodecError.noCodecFound(config.codec)
        }

        return try factory(namespace, publishDelegate, sourceID, config, metricsSubmitter, errorWriter)
    }
}
