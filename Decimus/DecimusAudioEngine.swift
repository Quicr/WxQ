import AVFAudio
import os

/// Wrapper for app specific AVAudioEngine functionality.
class DecimusAudioEngine {

    /// The audio format the application should use.
    static let format: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32,
                                             sampleRate: .opus48khz,
                                             channels: 1,
                                             interleaved: false)!

    private static let logger: DecimusLogger = .init(DecimusAudioEngine.self)

    /// The AVAudioEngine instance this AudioEngine wraps.
    private let engine: AVAudioEngine
    private var blocks: MutableWrapper<[AnyHashable: AVAudioSinkNodeReceiverBlock]> = .init(value: [:])
    private var notificationObservers: [NSObjectProtocol] = []
    private let sink: AVAudioSinkNode?
    private var stopped: Bool = false
    private var elements: [SourceIDType: AVAudioSourceNode] = [:]
    private let inputNodePresent: Bool
    private let outputNodePresent: Bool
    private var lock = OSAllocatedUnfairLock()

    private lazy var reconfigure: (Notification) -> Void = { [weak self] _ in
        guard let self = self else { return }
        Self.logger.debug("AVAudioEngineConfigurationChange")
        do {
            try self.reconfigureAndRestart()
        } catch {
            Self.logger.error("Failed to restart audio on config change. If you switched device, try again?")
        }
    }

    private lazy var interupt: (Notification) -> Void = { [weak self] notification in
        guard let self = self,
              let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // We got interupted.
            Self.logger.warning("Audio interuption", alert: true)
        case .ended:
            // Resume.
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try self.reconfigureAndRestart()
                    Self.logger.notice("Audio resumed")
                } catch {
                    Self.logger.error("Failed to resume audio session")
                }
            } else {
                Self.logger.warning("Audio interuption ended, but didn't ask resume", alert: true)
            }
        @unknown default:
            Self.logger.warning("Got unexpected audio interuption value")
        }
    }

    private lazy var reset: (Notification) -> Void = { _ in
        Self.logger.warning("Media services reset. Report this.")
    }

    private lazy var routeChange: (Notification) -> Void = { notification in
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        Self.logger.debug("Route change: \(reason)")
    }

    init() throws {
        // Configure the session.
        let engine = AVAudioEngine()
        let session = AVAudioSession.sharedInstance()
        try session.setSupportsMultichannelContent(false)
        let options: AVAudioSession.CategoryOptions
        #if os(tvOS)
        options = []
        #else
        options = [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        #endif
        try session.setCategory(.playAndRecord,
                                mode: .videoChat,
                                options: options)

        // Check for the presence of an input node without querying it.
        try session.setActive(true)
        if let availableInputs = session.availableInputs,
           availableInputs.count > 0 {
            // Should be safe to query input node now.
            let inputFormat = engine.inputNode.inputFormat(forBus: 0)
            let valid = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
            guard valid else {
                throw "Input exists w/ bad format. Aggregate device broken. Report this."
            }
            self.inputNodePresent = true
        } else {
            self.inputNodePresent = false
        }

        if !self.inputNodePresent {
            Self.logger.warning("Couldn't find a microphone to use", alert: true)
        }
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        self.outputNodePresent = outputFormat.sampleRate > 0 && outputFormat.channelCount > 0
        if !self.outputNodePresent {
            Self.logger.warning("Couldn't find a speaker to use", alert: true)
        }

        // Enable voice processing.
        if self.outputNodePresent && self.inputNodePresent {
            if !engine.outputNode.isVoiceProcessingEnabled {
                do {
                    try SwiftInterop.catchException {
                        do {
                            try engine.outputNode.setVoiceProcessingEnabled(true)
                        } catch {
                            Self.logger.warning("Failed to enable voice processing: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    Self.logger.warning("Failed to enable voice processing: \(error.localizedDescription)")
                }
            }
        }
        self.engine = engine

        // Ducking.
        if self.inputNodePresent {
            #if !os(tvOS)
            if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, visionOS 1.0, *) {
                let ducking: AVAudioVoiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false,
                                                                                          duckingLevel: .min)
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
            }
            #endif

            // Capture microphone audio.
            let sink = AVAudioSinkNode { [weak blocks] timestamp, frames, data in
                guard let blocks = blocks else { return .zero }
                var success = true
                for block in blocks.value.values {
                    success = success && block(timestamp, frames, data) == .zero
                }
                return success ? .zero : 1
            }
            engine.attach(sink)
            self.sink = sink
        } else {
            self.sink = nil
        }

        // Reconfigure first time.
        try localReconfigure()

        // Register interest in reconfigure events.
        let notifications: NotificationCenter = .default
        notificationObservers.append(notifications.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: nil,
                                                               queue: nil,
                                                               using: reconfigure))
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: interupt))
        let resetName = AVAudioSession.mediaServicesWereResetNotification
        notificationObservers.append(notifications.addObserver(forName: resetName,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: reset))
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: AVAudioSession.sharedInstance(),
                                                               queue: nil,
                                                               using: routeChange))
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Register a block that will be called with microphone data.
    /// You must register all blocks before calling start.
    /// - Parameter identifier: The identifier for this block.
    /// - Parameter block: The block to be called.
    func registerSinkBlock(identifier: AnyHashable, block: @escaping AVAudioSinkNodeReceiverBlock) throws {
        guard !engine.isRunning else { throw "Cannot alter blocks while running" }
        self.lock.withLock {
            self.blocks.value[identifier] = block
        }
    }

    /// Unregister a microphone sink block.
    /// - Parameter identifier: The identifier used to register this block.
    func unregisterSinkBlock(identifier: AnyHashable) throws {
        guard !engine.isRunning else { throw "Cannot alter blocks while running" }
        self.lock.withLock {
            _ = self.blocks.value.removeValue(forKey: identifier)
        }
    }

    /// Run the audio engine.
    func start() throws {
        guard !engine.isRunning else { throw "Already running" }
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        stopped = false
    }

    /// Stop the audio engine running.
    func stop() throws {
        guard engine.isRunning else { throw "Not running" }
        engine.stop()
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stopped = true
    }

    /// Add a source node to this engine, to be mixed with any others.
    /// - Parameter identifier: Identifier for this source.
    /// - Parameter node: The source node supplying audio.
    func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        assert(node.numberOfOutputs == 1)
        assert(node.outputFormat(forBus: 0) == Self.format)
        Self.logger.info("(\(identifier)) Attached node")
        try self.lock.withLock {
            guard self.elements[identifier] == nil else { throw "Add called for existing entry" }
            self.elements[identifier] = node
        }
    }

    /// Remove a previously added source node.
    /// - Parameter identifier: Identifier of the source node to remove.
    func removePlayer(identifier: SourceIDType) throws {
        try self.lock.withLock {
            guard let element = elements.removeValue(forKey: identifier) else {
                throw "Remove called for non existent entry"
            }
            engine.detach(element)
        }
        Self.logger.info("(\(identifier)) Removed player node")
    }

    func isInputMuted() -> Bool {
        self.inputNodePresent ? self.engine.inputNode.isVoiceProcessingInputMuted : true
    }

    func toggleMute() {
        guard self.inputNodePresent else { return }
        self.engine.inputNode.isVoiceProcessingInputMuted.toggle()
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, visionOS 1.0, *)
    func setMutedSpeechActivityEventListener(_ block: ((AVAudioVoiceProcessingSpeechActivityEvent) -> Void)?) throws {
        guard self.inputNodePresent else { return }
        guard self.engine.inputNode.setMutedSpeechActivityEventListener(block) else {
            throw "Couldn't set muted speech listener"
        }
    }

    private func localReconfigure() throws {
        // Reconfigure the audio session.
        let session: AVAudioSession = .sharedInstance()
        try session.setPreferredSampleRate(Self.format.sampleRate)

        // Inputs
        if self.inputNodePresent,
           Self.format.channelCount <= session.maximumInputNumberOfChannels {
            let preSetInput = session.inputNumberOfChannels
            try session.setPreferredInputNumberOfChannels(Int(Self.format.channelCount))
            let postSetInput = session.inputNumberOfChannels
            assert(preSetInput == postSetInput)
        }

        // Outputs
        if self.outputNodePresent,
           Self.format.channelCount <= session.maximumOutputNumberOfChannels {
            let preSetOutput = session.outputNumberOfChannels
            try session.setPreferredOutputNumberOfChannels(Int(Self.format.channelCount))
            let postSetOutput = session.outputNumberOfChannels
            assert(preSetOutput == postSetOutput)
        }

        // We shouldn't be running at this point.
        assert(!engine.isRunning)

        // Sink for microphone output.
        if self.inputNodePresent {
            guard let sink = self.sink else {
                throw "Sink should be present when input node present"
            }
            engine.connect(engine.inputNode, to: sink, format: Self.format)
            assert(engine.inputNode.numberOfOutputs == 1)
            let inputOutputFormat = engine.inputNode.outputFormat(forBus: 0)
            Self.logger.info("Connected microphone: \(inputOutputFormat)")
            assert(inputOutputFormat == Self.format)
            assert(sink.numberOfInputs == 1)
            assert(sink.inputFormat(forBus: 0) == Self.format)
        }

        // Mixer for player nodes.
        if self.outputNodePresent {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: Self.format)
            assert(engine.mainMixerNode.numberOfOutputs == 1)
            let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            Self.logger.info("Connected mixer: \(mixerOutputFormat)")
            assert(mixerOutputFormat == Self.format)

            // Sanity check the output format.
            assert(engine.outputNode.numberOfInputs == 1)
            if self.inputNodePresent && self.outputNodePresent {
                assert(engine.outputNode.isVoiceProcessingEnabled)
            }
            assert(engine.outputNode.inputFormat(forBus: 0) == Self.format)
        }

        // We shouldn't need to reconnect source nodes to the mixer,
        // as the format should not have changed.
        self.lock.withLock {
            for element in self.elements {
                assert(element.value.numberOfOutputs == 1)
                let sourceOutputFormat = element.value.outputFormat(forBus: 0)
                assert(sourceOutputFormat == Self.format)
            }
        }
    }

    private func reconfigureAndRestart() throws {
        guard !self.stopped else { return }
        if self.engine.isRunning {
            self.engine.stop()
        }

        // Reconfigure ourselves.
        try self.localReconfigure()

        // Restart.
        try self.start()
    }
}
