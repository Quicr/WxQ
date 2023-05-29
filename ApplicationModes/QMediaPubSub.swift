import SwiftUI
import CoreMedia
import AVFoundation

enum ApplicationError: Error {
    case emptyEncoder
    case alreadyConnected
    case notConnected
}

class QMediaPubSub: ApplicationMode {
    private var mediaClient: MediaClient?
    private var publisher: Publisher?
    private var subscriber: Subscriber?

    override func connect(config: CallConfig) async throws {
        guard mediaClient == nil else { throw ApplicationError.alreadyConnected }

        mediaClient = .init(address: .init(string: config.address)!,
                            port: config.port,
                            protocol: config.connectionProtocol,
                            conferenceId: config.conferenceId)

        publisher = .init(client: self.mediaClient!)
        subscriber = .init(client: self.mediaClient!, player: self.player)

        let manifest = await ManifestController.shared.getManifest(confId: config.conferenceId, email: config.email)
        try mediaClient!.getStreamConfigs(manifest,
                                          prepareEncoderCallback: prepareEncoder,
                                          prepareDecoderCallback: prepareDecoder)

        notifier.post(name: .connected, object: self)
    }

    override func disconnect() throws {
        guard mediaClient != nil else { throw ApplicationError.notConnected }

        publisher = nil
        subscriber = nil
        mediaClient = nil
    }

    private func prepareEncoder(sourceId: SourceIDType, mediaType: UInt8, endpoint: UInt16, qualityProfile: String) {
        guard let publisher = publisher else {
            fatalError("[QMediaPubSub] No publisher setup, did you forget to connect?")
        }

        let streamID = mediaClient!.addStreamPublishIntent(mediaType: mediaType, clientId: endpoint)
        let publication = publisher.allocateByStream(streamID: streamID)

        do {
            try publication.prepare(streamID: streamID, sourceID: sourceId, qualityProfile: qualityProfile)
        } catch {
            mediaClient!.removeMediaPublishStream(mediaStreamId: streamID)
        }
    }

    private func prepareDecoder(sourceId: SourceIDType, mediaType: UInt8, endpoint: UInt16, qualityProfile: String) {
        guard let subscriber = subscriber else {
            fatalError("[QMediaPubSub] No subscriber setup, did you forget to connect?")
        }

        let subscription = subscriber.allocateByStream(streamID: 0)
        let streamID = mediaClient!.addStreamSubscribe(mediaType: mediaType,
                                                       clientId: endpoint,
                                                       callback: subscription.subscribedObject)
        subscriber.updateSubscriptionStreamID(streamID: streamID)

        do {
            try subscription.prepare(streamID: streamID, sourceID: sourceId, qualityProfile: qualityProfile)
        } catch {
            mediaClient!.removeMediaSubscribeStream(mediaStreamId: streamID)
        }
    }

    override func encodeCameraFrame(identifier: SourceIDType, frame: CMSampleBuffer) {
        guard let publisher = publisher else {
            fatalError("No publisher delegate. Did you forget to connect?")
        }

        let publications = publisher.publications.filter({ $0.value.device!.uniqueID == identifier })
        guard !publications.isEmpty else {
            fatalError("No publishers matching sourceId: \(identifier)")
        }
        Task { await publications.concurrentForEach { $0.value.write(data: frame.asMediaBuffer()) } }
    }

    override func encodeAudioSample(identifier: SourceIDType, sample: CMSampleBuffer) {
        guard let publisher = publisher else {
            fatalError("No publisher delegate. Did you forget to connect?")
        }

        let publications = publisher.publications.filter({ $0.value.device!.uniqueID == identifier })
        guard !publications.isEmpty else {
            fatalError("No publishers matching sourceId: \(identifier)")
        }

        guard let formatDescription = sample.formatDescription else {
            errorHandler.writeError(message: "Missing format description")
            return
        }
        let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        let data = sample.getMediaBuffer(userData: audioFormat)
        publications.forEach { $0.value.write(data: data) }
    }
}

extension Sequence {
    func concurrentForEach(_ operation: @escaping (Element) async -> Void) async {
        // A task group automatically waits for all of its
        // sub-tasks to complete, while also performing those
        // tasks in parallel:
        await withTaskGroup(of: Void.self) { group in
            for element in self {
                group.addTask {
                    await operation(element)
                }
            }
        }
    }
}
