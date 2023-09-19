import AVFoundation
import Foundation
import os

class PublisherDelegate: QPublisherDelegateObjC {
    private static let logger = DecimusLogger(PublisherDelegate.self)

    private unowned let capture: CaptureManager
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter?
    private let factory: PublicationFactory

    init(publishDelegate: QPublishObjectDelegateObjC,
         metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         opusWindowSize: OpusWindowSize,
         reliability: MediaReliability,
         engine: AudioEngine,
         granularMetrics: Bool) {
        self.publishDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        self.capture = captureManager
        self.factory = .init(opusWindowSize: opusWindowSize,
                             reliability: reliability,
                             engine: engine,
                             granularMetrics: granularMetrics)
    }

    func allocatePub(byNamespace quicrNamepace: QuicrNamespace!,
                     sourceID: SourceIDType!,
                     qualityProfile: String!) -> QPublicationDelegateObjC? {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile!)
        do {
            let publication = try factory.create(quicrNamepace,
                                       publishDelegate: publishDelegate,
                                       sourceID: sourceID,
                                       config: config,
                                       metricsSubmitter: metricsSubmitter)

            guard let h264publication = publication as? FrameListener else {
                return publication
            }

            DispatchQueue.main.async { [unowned capture] in
                try! capture.addInput(h264publication) // swiftlint:disable:this force_try
            }
            return publication
        } catch {
            Self.logger.error("Failed to allocate publication: \(error.localizedDescription)", alert: true)
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
