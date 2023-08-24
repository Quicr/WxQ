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
         opusWindowSize: TimeInterval,
         reliability: MediaReliability) {
        self.publishDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        self.capture = captureManager
        self.factory = .init(opusWindowSize: opusWindowSize, reliability: reliability)
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
            if let h264publication = publication as? FrameListener {
                DispatchQueue.main.async { [unowned capture] in
                    try! capture.addInput(h264publication) // swiftlint:disable:this force_try
                }
            }
            return publication
        } catch {
            Self.logger.error("Failed to allocate publication: \(error.localizedDescription)")
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
