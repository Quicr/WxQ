import CoreMedia
import AVFoundation

enum CallError: Error {
    case failedToConnect(Int32)
}

class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {
    let notifier: NotificationCenter = .default

    init(errorWriter: ErrorWriter,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager) {
        super.init()
        self.subscriberDelegate = SubscriberDelegate(errorWriter: errorWriter,
                                                     submitter: metricsSubmitter)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager)
    }

    func connect(config: CallConfig) async throws {
        let error = super.connect(config.address, port: config.port, protocol: config.connectionProtocol.rawValue)
        guard error == .zero else {
            throw CallError.failedToConnect(error)
        }

        let manifest = await ManifestController.shared.getManifest(confId: config.conferenceID, email: config.email)
        super.updateManifest(manifest)
        notifier.post(name: .connected, object: self)
    }

    func disconnect() throws {
        super.close()
        notifier.post(name: .disconnected, object: self)
    }
}

extension Notification.Name {
    static let connected = Notification.Name("connected")
    static let disconnected = Notification.Name("disconnected")
}
