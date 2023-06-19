import AVFoundation
import Foundation

class PublisherDelegate: QPublisherDelegateObjC {
    private let codecFactory: EncoderFactory
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter
    private let errorWriter: ErrorWriter

    init(publishDelegate: QPublishObjectDelegateObjC, audioFormat: AVAudioFormat, metricsSubmitter: MetricsSubmitter, errorWriter: ErrorWriter) {
        self.publishDelegate = publishDelegate
        self.codecFactory = .init(audioFormat: audioFormat)
        self.metricsSubmitter = metricsSubmitter
        self.errorWriter = errorWriter
    }

    func allocatePub(byNamespace quicrNamepace: QuicrNamespace!) -> Any! {
        return Publication(namespace: quicrNamepace!,
                           publishDelegate: publishDelegate,
                           codecFactory: codecFactory,
                           metricsSubmitter: metricsSubmitter,
                           errorWriter: errorWriter)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
