import AVFoundation
import Foundation
import os

class SubscriberDelegate: QSubscriberDelegateObjC {
    private static let logger = DecimusLogger(SubscriberDelegate.self)

    let participants: VideoParticipants
    private let player: FasterAVEngineAudioPlayer
    private var checkStaleVideoTimer: Timer?
    private let submitter: MetricsSubmitter?
    private let factory: SubscriptionFactory

        init(submitter: MetricsSubmitter?,
             config: SubscriptionConfig,
             engine: AVAudioEngine,
             granularMetrics: Bool) {
        self.participants = .init()
        self.player = .init(engine: engine)
        self.submitter = submitter
        self.factory = .init(participants: self.participants,
                             player: self.player,
                             config: config,
                             granularMetrics: granularMetrics)

        self.checkStaleVideoTimer = .scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let staleVideos = self.participants.participants.filter { _, participant in
                return participant.lastUpdated.advanced(by: DispatchTimeInterval.seconds(2)) < .now()
            }
            for id in staleVideos.keys {
                do {
                    try self.participants.removeParticipant(identifier: id)
                } catch {
                    self.player.removePlayer(identifier: id)
                }
            }
        }
    }

    func allocateSub(byNamespace quicrNamepace: QuicrNamespace!,
                     qualityProfile: String!) -> QSubscriptionDelegateObjC? {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile!)
        do {
            return try factory.create(quicrNamepace!,
                                      config: config,
                                      metricsSubmitter: submitter)
        } catch {
            Self.logger.error("Failed to allocate subscription: \(error)", alert: true)
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: QuicrNamespace!) -> Int32 {
        return 0
    }
}
