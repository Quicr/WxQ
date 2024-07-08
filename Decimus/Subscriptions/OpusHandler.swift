import Foundation
import AVFAudio
import CoreAudio
import Atomics

enum OpusSubscriptionError: Error {
    case failedDecoderCreation
}

class OpusHandler {
    private static let logger = DecimusLogger(OpusHandler.self)
    private let sourceId: SourceIDType
    private var decoder: LibOpusDecoder
    private let engine: DecimusAudioEngine
    private let asbd: UnsafeMutablePointer<AudioStreamBasicDescription>
    private var node: AVAudioSourceNode?
    private var jitterBuffer: QJitterBuffer
    private let measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?
    private var underrun = ManagedAtomic<UInt64>(0)
    private var callbacks = ManagedAtomic<UInt64>(0)
    private let granularMetrics: Bool

    init(sourceId: SourceIDType,
         engine: DecimusAudioEngine,
         measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         granularMetrics: Bool) throws {
        self.sourceId = sourceId
        self.engine = engine
        self.measurement = measurement
        self.granularMetrics = granularMetrics
        self.decoder = try .init(format: DecimusAudioEngine.format)

        // Create the jitter buffer.
        self.asbd = .init(mutating: decoder.decodedFormat.streamDescription)
        let opusPacketSize = self.asbd.pointee.mSampleRate * opusWindowSize.rawValue
        self.jitterBuffer = QJitterBuffer(elementSize: Int(asbd.pointee.mBytesPerPacket),
                                          packetElements: Int(opusPacketSize),
                                          clockRate: UInt(asbd.pointee.mSampleRate),
                                          maxLengthMs: UInt(jitterMax * 1000),
                                          minLengthMs: UInt(jitterDepth * 1000)) { level, msg, alert in
            OpusHandler.logger.log(level: DecimusLogger.LogLevel(rawValue: level)!, msg!, alert: alert)
        }

        // Create the player node.
        self.node = .init(format: decoder.decodedFormat, renderBlock: renderBlock)
        try self.engine.addPlayer(identifier: sourceId, node: node!)
    }

    deinit {
        // Remove the audio playout.
        do {
            try engine.removePlayer(identifier: sourceId)
        } catch {
            Self.logger.error("Couldn't remove player: \(error.localizedDescription)")
        }

        // Reset the node.
        node?.reset()
    }

    func submitEncodedAudio(data: Data, sequence: UInt32, date: Date?) throws {
        // Generate PLC prior to real decode.
        let selfPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        jitterBuffer.prepare(UInt(sequence),
                             concealmentCallback: self.plcCallback,
                             userData: selfPtr)

        // Decode and queue for playout.
        let decoded = try decoder.write(data: data)
        try queueDecodedAudio(buffer: decoded, timestamp: date, sequence: sequence)

        // Metrics.
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.framesUnderrun(underrun: self.underrun.load(ordering: .relaxed),
                                                             timestamp: date)
                await measurement.measurement.callbacks(callbacks: self.callbacks.load(ordering: .relaxed),
                                                        timestamp: date)
                if let date = date {
                    await measurement.measurement.depth(depthMs: self.jitterBuffer.getCurrentDepth(),
                                                        timestamp: date)
                }
            }
        }
    }

    private lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [jitterBuffer, asbd, weak underrun, weak callbacks] silence, _, numFrames, data in
        // Fill the buffers as best we can.
        if let callbacks = callbacks {
            callbacks.wrappingIncrement(by: UInt64(numFrames), ordering: .relaxed)
        }
        guard data.pointee.mNumberBuffers == 1 else {
            // Unexpected.
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            Self.logger.error("Got multiple buffers: \(data.pointee.mNumberBuffers)")
            for (idx, buffer) in buffers.enumerated() {
                Self.logger.error("Buffer \(idx) size: \(buffer.mDataByteSize), channels: \(buffer.mNumberChannels)")
            }
            return 1
        }

        guard data.pointee.mBuffers.mNumberChannels == asbd.pointee.mChannelsPerFrame else {
            Self.logger.error("Unexpected render block channels. Got \(data.pointee.mBuffers.mNumberChannels). Expected \(asbd.pointee.mChannelsPerFrame)")
            return 1
        }

        let buffer: AudioBuffer = data.pointee.mBuffers
        assert(buffer.mDataByteSize == numFrames * asbd.pointee.mBytesPerFrame)
        let copiedFrames = jitterBuffer.dequeue(buffer.mData,
                                                destinationLength: Int(buffer.mDataByteSize),
                                                elements: Int(numFrames))
        guard copiedFrames == numFrames else {
            // Ensure any incomplete data is pure silence.
            let framesUnderan = UInt64(numFrames) - UInt64(copiedFrames)
            silence.pointee = .init(framesUnderan == numFrames)
            if let underrun = underrun {
                underrun.wrappingIncrement(by: framesUnderan, ordering: .relaxed)
            }
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            for buffer in buffers {
                guard let dataPointer = buffer.mData else {
                    break
                }
                let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
                let discontinuityStartOffset = copiedFrames * bytesPerFrame
                let numberOfSilenceBytes = Int(framesUnderan) * bytesPerFrame
                guard discontinuityStartOffset + numberOfSilenceBytes == buffer.mDataByteSize else {
                    Self.logger.error("Invalid buffers when calculating silence")
                    break
                }
                memset(dataPointer + discontinuityStartOffset, 0, Int(numberOfSilenceBytes))
            }
            return .zero
        }
        return .zero
    }

    private let plcCallback: PacketCallback = { packets, count, userData in
        guard let userData = userData else {
            OpusHandler.logger.error("Expected self in userData")
            return
        }
        let handler: OpusHandler = Unmanaged<OpusHandler>.fromOpaque(userData).takeUnretainedValue()
        var concealed: UInt64 = 0
        for index in 0..<count {
            // Make PLC packets.
            var packet = packets!.advanced(by: index)
            do {
                // TODO: This can be optimized with some further work to decode PLC directly into the buffer.
                let plcData = try handler.decoder.plc(frames: AVAudioFrameCount(packet.pointee.elements))
                let list = plcData.audioBufferList
                guard list.pointee.mNumberBuffers == 1 else {
                    throw "Not sure what to do with this"
                }

                // Get audio data as packet list.
                let audioBuffer = list.pointee.mBuffers
                guard let data = audioBuffer.mData else {
                    throw "AudioBuffer data was nil"
                }
                assert(packet.pointee.length == audioBuffer.mDataByteSize)
                memcpy(packet.pointee.data, data, packet.pointee.length)
                concealed += UInt64(packet.pointee.elements)
            } catch {
                OpusHandler.logger.error("\(error.localizedDescription)")
            }
        }
        if let measurement = handler.measurement {
            let constConcealed = concealed
            let timestamp: Date? = handler.granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.measurement.concealmentFrames(concealed: constConcealed,
                                                                timestamp: timestamp)
            }
        }
    }

    private func queueDecodedAudio(buffer: AVAudioPCMBuffer, timestamp: Date?, sequence: UInt32) throws {
        // Ensure this buffer looks valid.
        let list = buffer.audioBufferList
        guard list.pointee.mNumberBuffers == 1 else {
            throw "Unexpected number of buffers"
        }

        // Get audio data as packet list.
        let audioBuffer = list.pointee.mBuffers
        guard let data = audioBuffer.mData else {
            Self.logger.error("AudioBuffer data was nil")
            return
        }

        let packet: Packet = .init(sequence_number: UInt(sequence),
                                   data: data,
                                   length: Int(audioBuffer.mDataByteSize),
                                   elements: Int(buffer.frameLength))

        let selfPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()

        // Copy in.
        let copied = jitterBuffer.enqueue(packet,
                                          concealmentCallback: self.plcCallback,
                                          userData: selfPtr)

        let missing = copied < buffer.frameLength ? Int(buffer.frameLength) - copied : 0
        if let measurement = measurement {
            Task(priority: .utility) {
                await measurement.measurement.receivedFrames(received: buffer.frameLength,
                                                             timestamp: timestamp)
                await measurement.measurement.recordLibJitterMetrics(metrics: jitterBuffer.getMetrics(),
                                                                     timestamp: timestamp)
                await measurement.measurement.droppedFrames(dropped: missing,
                                                            timestamp: timestamp)
            }
        }
    }
}
