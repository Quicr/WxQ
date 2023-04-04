import SwiftUI
import CoreMedia
import AVFoundation

enum ApplicationError: Error {
    case emptyEncoder
    case alreadyConnected
}

class QMediaPubSub: ApplicationModeBase {
    struct WeakQMediaPubSub {
        weak var value: QMediaPubSub?
        init(_ publisher: QMediaPubSub?) {
            self.value = publisher
        }
    }
    private static var streamIdMap: [UInt64: WeakQMediaPubSub] = .init()

    private var qMedia: QMedia?
    private var identifierMapping: [UInt32: UInt64] = .init()

    private var videoSubscription: UInt64 = 0
    private var audioSubscription: UInt64 = 0

    private var sourcesByMediaType: [QMedia.CodecType: UInt8] = [:]

    deinit {
        guard qMedia != nil else { return }
        QMediaPubSub.streamIdMap.forEach { id, _ in
            removeRemoteSource(identifier: UInt32(id))
        }
        identifierMapping.forEach { id, _ in
            qMedia!.removeMediaPublishStream(mediaStreamId: UInt64(id))
        }
    }

    let streamCallback: SubscribeCallback = { streamId, mediaId, clientId, data, length, timestamp in
        guard let publisher = QMediaPubSub.streamIdMap[streamId]?.value else {
            fatalError("Failed to find QMediaPubSub instance for stream: \(streamId))")
        }
        guard data != nil else {
            publisher.errorHandler.writeError(message: "[QMediaPubSub] [Subscription \(streamId)] Data was nil")
            return
        }

        // Get the codec out of the media ID.
        let rawCodec = mediaId & 0b1111_0000
        guard let codec = QMedia.CodecType(rawValue: rawCodec) else {
            publisher.errorHandler.writeError(
                message: "[QMediaPubSub] [Subscription \(streamId)] Unexpected codec type: \(rawCodec)")
            return
        }

        let mediaType: PipelineManager.MediaType
        switch codec {
        case .h264:
            mediaType = .video
        case .opus:
            mediaType = .audio
        }

        let unique: UInt32 = .init(clientId) << 24 | .init(mediaId)
        if publisher.pipeline!.decoders[unique] == nil {
            publisher.pipeline!.registerDecoder(identifier: unique, type: mediaType)
        }

        let buffer: MediaBufferFromSource = .init(source: UInt32(unique),
                                                  media: .init(buffer: .init(start: data, count: Int(length)),
                                                               timestampMs: UInt32(timestamp)))
        publisher.pipeline!.decode(mediaBuffer: buffer)
    }

    func connect(config: CallConfig) throws {
        guard qMedia == nil else { throw ApplicationError.alreadyConnected }
        qMedia = .init(address: .init(string: config.address)!, port: config.port)

        // Video.
        videoSubscription = qMedia!.addVideoStreamSubscribe(codec: .h264, callback: streamCallback)
        Self.streamIdMap[videoSubscription] = .init(self)
        print("[QMediaPubSub] Subscribed for video: \(videoSubscription)")

        // Audio.
        audioSubscription = qMedia!.addAudioStreamSubscribe(codec: .opus, callback: streamCallback)
        Self.streamIdMap[audioSubscription] = .init(self)
        print("[QMediaPubSub] Subscribed for audio: \(audioSubscription)")
    }

    override func createVideoEncoder(identifier: UInt32,
                                     width: Int32,
                                     height: Int32,
                                     orientation: AVCaptureVideoOrientation?,
                                     verticalMirror: Bool) {
        super.createVideoEncoder(identifier: identifier,
                                 width: width,
                                 height: height,
                                 orientation: orientation,
                                 verticalMirror: verticalMirror)

        let subscriptionId = qMedia!.addVideoStreamPublishIntent(codec: getUniqueCodecType(type: .h264),
                                                                 clientIdentifier: clientId)
        print("[QMediaPubSub] (\(identifier)) Video registered to publish stream: \(subscriptionId)")
        identifierMapping[identifier] = subscriptionId
    }

    override func createAudioEncoder(identifier: UInt32) {
        super.createAudioEncoder(identifier: identifier)

        let subscriptionId = qMedia!.addAudioStreamPublishIntent(codec: getUniqueCodecType(type: .opus),
                                                                 clientIdentifier: clientId)
        print("[QMediaPubSub] (\(identifier)) Audio registered to publish stream: \(subscriptionId)")
        identifierMapping[identifier] = subscriptionId
    }

    override func removeRemoteSource(identifier: UInt32) {
        super.removeRemoteSource(identifier: identifier)
        qMedia!.removeMediaSubscribeStream(mediaStreamId: UInt64(identifier))
    }

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        do {
            try data.dataBuffer!.withUnsafeMutableBytes { ptr in
                let unsafe = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let timestampMs: UInt32
                do {
                    timestampMs = UInt32(try data.sampleTimingInfo(at: 0).presentationTimeStamp.seconds * 1000)
                } catch {
                    timestampMs = 0
                }
                guard let streamId = self.identifierMapping[identifier] else {
                    errorHandler.writeError(
                        message: "[QMediaPubSub] Couldn't lookup stream id for media id: \(identifier)"
                    )
                    return
                }
                qMedia!.sendVideoFrame(mediaStreamId: streamId,
                                       buffer: unsafe,
                                       length: UInt32(data.dataBuffer!.dataLength),
                                       timestamp: UInt64(timestampMs),
                                       flag: false)
            }
        } catch {
            errorHandler.writeError(message: "[QMediaPubSub] Failed to get bytes of encoded image")
        }
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        guard let streamId = identifierMapping[data.source] else {
            errorHandler.writeError(message: "[QMediaPubSub] Couldn't lookup stream id for media id: \(data.source)")
            return
        }
        guard data.media.buffer.count > 0 else {
            errorHandler.writeError(message: "[QMediaPubSub] Audio to send had length 0")
            return
        }
        qMedia!.sendAudio(mediaStreamId: streamId,
                          buffer: data.media.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          length: UInt32(data.media.buffer.count),
                          timestamp: UInt64(data.media.timestampMs))
    }

    private func getUniqueCodecType(type: QMedia.CodecType) -> UInt8 {
        if sourcesByMediaType[type] == nil {
            sourcesByMediaType[type] = 0
        } else {
            sourcesByMediaType[type]! += 1
        }
        return type.rawValue | sourcesByMediaType[type]!
    }
}
