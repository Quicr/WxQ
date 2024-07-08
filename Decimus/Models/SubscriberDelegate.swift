import AVFoundation
import Foundation
import os

class SubscriberDelegate: QSubscriberDelegateObjC {
    private static let logger = DecimusLogger(SubscriberDelegate.self)

    let participants: VideoParticipants
    private let submitter: MetricsSubmitter?
    private let factory: SubscriptionFactory

    init(submitter: MetricsSubmitter?,
         config: SubscriptionConfig,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         controller: CallController) {
        self.participants = .init()
        self.submitter = submitter
        self.factory = .init(participants: self.participants,
                             engine: engine,
                             config: config,
                             granularMetrics: granularMetrics,
                             controller: controller)
    }

    func allocateSub(bySourceId sourceId: SourceIDType,
                     profileSet: QClientProfileSet) -> QSubscriptionDelegateObjC? {
        do {
            return try factory.create(sourceId,
                                      profileSet: profileSet,
                                      metricsSubmitter: self.submitter)
        } catch {
            Self.logger.error("Failed to allocate subscription: \(error)")
            return nil
        }
    }

    func remove(bySourceId sourceId: SourceIDType) -> Int32 {
        return 0
    }
}
