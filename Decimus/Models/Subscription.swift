import AVFoundation
import CoreMedia
import SwiftUI

class Subscription: QSubscriptionDelegateObjC {

    private let namespace: String
    private var decoder: Decoder?
    private unowned let participants: VideoParticipants
    private unowned let player: FasterAVEngineAudioPlayer
    private unowned let codecFactory: DecoderFactory

    init(namespace: String,
         codecFactory: DecoderFactory,
         participants: VideoParticipants,
         player: FasterAVEngineAudioPlayer) {
        self.namespace = namespace
        self.codecFactory = codecFactory
        self.participants = participants
        self.player = player
    }

    deinit {
        do {
            try participants.removeParticipant(identifier: namespace)
        } catch {
            player.removePlayer(identifier: namespace)
        }
    }

    func prepare(_ sourceId: SourceIDType!, label: String!, qualityProfile: String!) -> Int32 {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)

        do {
            switch config.codec {
            case .opus:
                let bufferDecoder = try codecFactory.create(config: config) { [weak self] in
                    self?.playAudio(buffer: $0, timestamp: $1)
                }
                self.player.addPlayer(identifier: namespace, format: bufferDecoder.decodedFormat)
                decoder = bufferDecoder
            case .h264:
                let sampleDecoder = try codecFactory.create(config: config) { [weak self] in
                    self?.showDecodedImage(decoded: $0, timestamp: $1, orientation: $2, verticalMirror: $3)
                }
                decoder = sampleDecoder
            default:
                return 1
            }

            log("Subscribed to \(String(describing: config.codec)) stream for source \(sourceId!)")
        } catch {
            log("Failed to create decoder: \(error)")
            return 1
        }

        return 0
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return 1
    }

    func subscribedObject(_ data: Data!) -> Int32 {
        guard let decoder = decoder else {
            log("No decoder for Subscription. Did you forget to prepare?")
            return 1
        }

        data.withUnsafeBytes {
            decoder.write(buffer: .init(buffer: $0, timestampMs: 0))
        }

        return 0
    }

    private func playAudio(buffer: AVAudioPCMBuffer, timestamp: CMTime?) {
        player.write(identifier: namespace, buffer: buffer)
    }

    private func showDecodedImage(decoded: CIImage,
                                  timestamp: CMTimeValue,
                                  orientation: AVCaptureVideoOrientation?,
                                  verticalMirror: Bool) {
        let participant = participants.getOrMake(identifier: namespace)

        // TODO: Why can't we use CIImage directly here?
        let image: CGImage = CIContext().createCGImage(decoded, from: decoded.extent)!
        let imageOrientation = orientation?.toImageOrientation(verticalMirror) ?? .up
        participant.decodedImage = .init(decorative: image, scale: 1.0, orientation: imageOrientation)
        participant.lastUpdated = .now()
    }

    private func log(_ message: String) {
        print("[Subscription] (\(namespace)) \(message)")
    }
}

extension AVCaptureVideoOrientation {
    func toImageOrientation(_ verticalMirror: Bool) -> Image.Orientation {
        let imageOrientation: Image.Orientation
        switch self {
        case .portrait:
            imageOrientation = verticalMirror ? .leftMirrored : .right
        case .landscapeLeft:
            imageOrientation = verticalMirror ? .upMirrored : .down
        case .landscapeRight:
            imageOrientation = verticalMirror ? .downMirrored : .up
        case .portraitUpsideDown:
            imageOrientation = verticalMirror ? .rightMirrored : .left
        default:
            imageOrientation = .up
        }
        return imageOrientation
    }
}
