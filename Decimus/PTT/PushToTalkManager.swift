import UIKit
import PushToTalk
import AVFAudio

enum PushToTalkError: Error {
    case notStarted
    case channelExists
    case channelDoesntExist
    case unjoined
}

struct PTTUser: Decodable {
    let id: UUID
    let name: String
    let token: Data
}

class PushToTalkServer {
    private let url: URL
    private let session = URLSession(configuration: .default)
    private var ourself: PTTUser?
    private let name: String

    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    func join(channel: UUID, token: Data) async throws {
        let url = self.url.appending(path: "/channel/\(channel.uuidString)/\(self.name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let body = ["token": token.base64EncodedString()]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await self.session.data(for: request)
        self.ourself = try JSONDecoder().decode(PTTUser.self, from: data)
    }

    func sentAudio(channel: UUID) async throws {
        guard let ourself = self.ourself else { throw PushToTalkError.unjoined }
        let url = self.url.appending(path: "/channel/\(channel.uuidString)/audio/\(ourself.id)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await self.session.data(for: request)
    }

    func leave(channel: UUID) async throws {
        guard let ourself = self.ourself else { throw PushToTalkError.unjoined }
        let url = self.url.appending(path: "/channel/\(channel.uuidString)/\(ourself.id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await self.session.data(for: request)
    }
}

protocol PushToTalkManager {
    func start() async throws
    func startTransmitting(_ uuid: UUID) throws
    func stopTransmitting(_ uuid: UUID) throws
    func registerChannel(_ channel: PushToTalkChannel) async throws
    func unregisterChannel(_ channel: PushToTalkChannel) throws
    func getChannel(uuid: UUID) -> PushToTalkChannel?
}

class MockPushToTalkManager: PushToTalkManager {
    private let logger = DecimusLogger(PushToTalkManager.self)
    private var channels: [UUID: PushToTalkChannel] = [:]
    private let api: PushToTalkServer

    init(api: PushToTalkServer) {
        self.api = api
    }

    func start() async throws { }

    func startTransmitting(_ uuid: UUID) throws {
        guard let channel = self.channels[uuid] else {
            throw PushToTalkError.channelDoesntExist
        }
        guard let publication = channel.publication else {
            fatalError()
        }
        publication.startProcessing()
    }

    func stopTransmitting(_ uuid: UUID) throws {
        guard let channel = self.channels[uuid] else {
            throw PushToTalkError.channelDoesntExist
        }
        guard let publication = channel.publication else {
            fatalError()
        }
        publication.stopProcessing()
    }

    func registerChannel(_ channel: PushToTalkChannel) async throws {
        guard self.channels[channel.uuid] == nil else {
            throw PushToTalkError.channelExists
        }
        self.channels[channel.uuid] = channel
        try await self.api.join(channel: channel.uuid, token: Data(repeating: 0, count: 4))
        self.logger.info("[PTT] (\(channel.uuid)) Channel Registered")
    }

    func unregisterChannel(_ channel: PushToTalkChannel) throws {
        self.channels.removeValue(forKey: channel.uuid)
    }

    func getChannel(uuid: UUID) -> PushToTalkChannel? {
        self.channels[uuid]
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
class PushToTalkManagerImpl: NSObject, PushToTalkManager {
    private let logger = DecimusLogger(PushToTalkManager.self)
    private var token: Data?
    private var channels: [UUID: PushToTalkChannel] = [:]
    private var manager: PTChannelManager?
    private let mode: PTTransmissionMode = .halfDuplex
    private let api: PushToTalkServer
    private var pendingJoinRequests: [UUID] = []

    init(api: PushToTalkServer) {
        self.api = api
    }

    func start() async throws {
        self.manager = try await .channelManager(delegate: self, restorationDelegate: self)
        self.logger.info("[PTT] Started")
        if let uuid = self.manager?.activeChannelUUID {
            self.logger.info("[PTT] (\(uuid)) Existing channel on startup")
            try self.stopTransmitting(uuid)
        }
    }

    func startTransmitting(_ uuid: UUID) throws {
        guard let manager = self.manager else {
            throw PushToTalkError.notStarted
        }
        manager.requestBeginTransmitting(channelUUID: uuid)
    }

    func stopTransmitting(_ uuid: UUID) throws {
        guard let manager = self.manager else {
            throw PushToTalkError.notStarted
        }
        manager.stopTransmitting(channelUUID: uuid)
    }

    func registerChannel(_ channel: PushToTalkChannel) async throws {
        guard self.channels[channel.uuid] == nil else {
            throw PushToTalkError.channelExists
        }
        guard let manager = self.manager else {
            throw PushToTalkError.notStarted
        }
        self.channels[channel.uuid] = channel
        manager.requestJoinChannel(channelUUID: channel.uuid, descriptor: channel.description)
        try await manager.setTransmissionMode(self.mode, channelUUID: channel.uuid)
        try await manager.setServiceStatus(.connecting, channelUUID: channel.uuid)
        self.logger.info("[PTT] (\(channel.uuid)) Channel Registered")
    }

    func unregisterChannel(_ channel: PushToTalkChannel) throws {
        guard let manager = self.manager else {
            throw PushToTalkError.notStarted
        }
        guard self.channels[channel.uuid] != nil else {
            throw PushToTalkError.channelDoesntExist
        }
        manager.leaveChannel(channelUUID: channel.uuid)
    }

    func getChannel(uuid: UUID) -> PushToTalkChannel? {
        self.channels[uuid]
    }
}

// PTT Delegate Implementations.
extension PushToTalkManagerImpl: PTChannelManagerDelegate, PTChannelRestorationDelegate {
    func channelManager(_ channelManager: PTChannelManager,
                        didJoinChannel channelUUID: UUID,
                        reason: PTChannelJoinReason) {
        self.logger.info("[PTT] (\(channelUUID)) Joined channel: \(reason)")

        // Update our status on the PTT server.
        guard let token = self.token else {
            self.logger.error("Missing token")
            self.pendingJoinRequests.append(channelUUID)
            return
        }
        Task(priority: .medium) {
            guard let manager = self.manager else { fatalError() }
            do {
                try await self.api.join(channel: channelUUID, token: token)
                try await manager.setServiceStatus(.ready, channelUUID: channelUUID)
                self.logger.info("[PTT] (\(channelUUID)) Notified server of join")
            } catch {
                self.logger.error("Failed to join channel on PTT server: \(error.localizedDescription)")
                try await manager.setServiceStatus(.unavailable, channelUUID: channelUUID)
            }
        }
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didLeaveChannel channelUUID: UUID,
                        reason: PTChannelLeaveReason) {
        self.logger.info("[PTT] (\(channelUUID)) Left channel: \(reason)")
        self.channels.removeValue(forKey: channelUUID)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        self.logger.info("[PTT] (\(channelUUID)) Began transmitting")
        guard let channel = self.channels[channelUUID] else {
            self.logger.error("[PTT] (\(channelUUID)) Missing channel for beginTransmitting event")
            return
        }
        guard let publication = channel.publication else {
            self.logger.error("[PTT] (\(channelUUID)) Missing publication for channel on beginTransmitting event")
            return
        }

        // Send notification audio is transmitting.
        Task(priority: .medium) {
            do {
                try await self.api.sentAudio(channel: channelUUID)
            } catch {
                print("Failed to send audio notification for PTT: \(error.localizedDescription)")
            }
        }

        // Mark publication to start capturing audio data.
        publication.startProcessing()
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        self.logger.info("[PTT] (\(channelUUID)) Stopped transmitting")
        guard let channel = self.channels[channelUUID] else {
            self.logger.error("[PTT] (\(channelUUID)) Missing channel for beginTransmitting event")
            return
        }
        guard let publication = channel.publication else {
            self.logger.error("[PTT] (\(channelUUID)) Missing publication for channel on beginTransmitting event")
            return
        }
        // Mark publication to stop capturing audio data.
        publication.stopProcessing()
    }

    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
        self.logger.info("[PTT] Got PTT token")
        self.token = pushToken

        // Flush any pending requests.
        for request in self.pendingJoinRequests {
            Task(priority: .medium) {
                guard let manager = self.manager else { fatalError() }
                do {
                    try await self.api.join(channel: request, token: pushToken)
                    try await manager.setServiceStatus(.ready, channelUUID: request)
                } catch {
                    self.logger.error("Failed to join channel on PTT server: \(error.localizedDescription)")
                    try await manager.setServiceStatus(.unavailable, channelUUID: request)
                }
            }
        }
        self.pendingJoinRequests.removeAll()
    }

    func incomingPushResult(channelManager: PTChannelManager,
                            channelUUID: UUID,
                            pushPayload: [String: Any]) -> PTPushResult {
        if let activeSpeaker = pushPayload["activespeaker"] as? String {
            self.logger.info("[PTT] Active Speaker: \(activeSpeaker)")
            return .activeRemoteParticipant(PTParticipant(name: activeSpeaker, image: nil))
        } else {
            self.logger.error("[PTT] Unknown PTT notification received: \(pushPayload)")
            return .leaveChannel
        }
    }

    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
        self.logger.info("[PTT] Activated audio session")
    }

    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
        self.logger.info("[PTT] Deactivated audio session")
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        self.logger.info("[PTT] (\(channelUUID)) Restoration / cache lookup")
        if let channel = self.channels[channelUUID] {
            return channel.description
        } else {
            let channel = PushToTalkChannel(uuid: channelUUID, createdFrom: .restore)
            self.channels[channelUUID] = channel
            return channel.description
        }
    }

    func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: any Error) {
        self.logger.error("[PTT] (\(channelUUID)) Failed to join channel: \(error.localizedDescription)")
    }
}
#endif
