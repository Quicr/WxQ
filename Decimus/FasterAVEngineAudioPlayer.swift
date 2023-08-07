import AVFoundation
import CoreAudio
import CTPCircularBuffer

/// Plays audio samples out.
class FasterAVEngineAudioPlayer {
    let inputFormat: AVAudioFormat
    private var engine: AVAudioEngine = .init()
    private var mixer: AVAudioMixerNode = .init()
    private let errorWriter: ErrorWriter
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]

    /// Create a new `AudioPlayer`
    init(errorWriter: ErrorWriter) {
        self.errorWriter = errorWriter
        engine.attach(mixer)
        inputFormat = mixer.inputFormat(forBus: 0)
        print("[FasterAVEngineAudioPlayer] Creating. Mixer input format is: \(inputFormat)")
        engine.connect(mixer, to: engine.outputNode, format: nil)
#if os(iOS) && targetEnvironment(macCatalyst)
        if !engine.outputNode.isVoiceProcessingEnabled {
            do {
                try engine.outputNode.setVoiceProcessingEnabled(true)
            } catch {
                errorWriter.writeError("Failed to set output voice processing: \(error.localizedDescription)")
            }
        }
#endif
        engine.prepare()
    }

    deinit {
        engine.stop()

        for identifier in elements.keys {
            removePlayer(identifier: identifier)
        }
        elements.removeAll()

        engine.disconnectNodeInput(mixer)
        engine.detach(mixer)
    }

    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        print("[FasterAVAudioEngine] (\(identifier)) Attaching node: \(node.outputFormat(forBus: 0))")
        engine.attach(node)
        engine.connect(node, to: mixer, format: nil)
        if !engine.isRunning {
            try engine.start()
        }
    }

    func removePlayer(identifier: SourceIDType) {

        guard let element = elements.removeValue(forKey: identifier) else { return }
        print("[FasterAVAudioEngine] (\(identifier)) Removing")

        // Dispose of the element's resources.
        engine.disconnectNodeInput(element)
        engine.detach(element)
    }
}
