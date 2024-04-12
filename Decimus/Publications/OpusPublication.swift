import Foundation
import Atomics
import AVFAudio
import AVFoundation
import CTPCircularBuffer
import CoreAudio
import os

class OpusPublication: Publication {
    private static let logger = DecimusLogger(OpusPublication.self)

    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?

    private let encoder: LibOpusEncoder
    private let buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private let measurement: OpusPublicationMeasurement?
    private let metricsSubmitter: MetricsSubmitter?
    private let opusWindowSize: OpusWindowSize
    private let reliable: Bool
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine
    private var encodeTask: Task<(), Never>?
    private var transmit: ManagedAtomic<Bool> = .init(true)

    lazy var block: AVAudioSinkNodeReceiverBlock = { [buffer, weak transmit] timestamp, numFrames, data in
        assert(data.pointee.mNumberBuffers <= 2)
        guard let transmit = transmit,
              transmit.load(ordering: .acquiring) else {
            return .zero
        }
        let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                         data,
                                                         timestamp,
                                                         numFrames,
                                                         DecimusAudioEngine.format.streamDescription)
        return copied ? .zero : 1
    }

    init(namespace: QuicrNamespace,
         publishDelegate: QPublishObjectDelegateObjC,
         sourceID: SourceIDType,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         config: AudioCodecConfig) throws {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.engine = engine
        self.metricsSubmitter = metricsSubmitter
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace)
        } else {
            self.measurement = nil
        }
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics

        // Create a buffer to hold raw data waiting for encode.
        let format = DecimusAudioEngine.format
        let hundredMils = Double(format.streamDescription.pointee.mBytesPerPacket) * format.sampleRate * opusWindowSize.rawValue
        guard _TPCircularBufferInit(buffer, UInt32(hundredMils), MemoryLayout<TPCircularBuffer>.size) else {
            fatalError()
        }

        encoder = try .init(format: format, desiredWindowSize: opusWindowSize, bitrate: Int(config.bitrate))
        Self.logger.info("Created Opus Encoder")

        // Setup encode job.
        self.encodeTask = .init(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                do {
                    while let data = try self.encode() {
                        self.publish(data: data)
                    }
                } catch {
                    Self.logger.error("Failed encode: \(error)")
                }
                try? await Task.sleep(for: .seconds(opusWindowSize.rawValue),
                                      tolerance: .seconds(opusWindowSize.rawValue / 2),
                                      clock: .continuous)
            }
        }

        // Register our block.
        try engine.registerSinkBlock(identifier: namespace, block: block)

        // Metrics registration (after any possible throws)
        if let metricsSubmitter = self.metricsSubmitter,
           let measurement = self.measurement {
            Task(priority: .utility) {
                await metricsSubmitter.register(measurement: measurement)
            }
        }

        Self.logger.info("Registered OPUS publication for source \(sourceID)")
    }

    deinit {
        do {
            try engine.unregisterSinkBlock(identifier: self.namespace)
        } catch {
            Self.logger.critical("Failed to unregister sink block: \(error.localizedDescription)")
        }
        self.encodeTask?.cancel()
        TPCircularBufferCleanup(self.buffer)
        if let measurement = self.measurement,
           let metricsSubmitter = self.metricsSubmitter {
            let id = measurement.id
            Task(priority: .utility) {
                await metricsSubmitter.unregister(id: id)
            }
        }
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!, transportMode: UnsafeMutablePointer<TransportMode>!) -> Int32 {
        transportMode.pointee = self.reliable ? .reliablePerGroup : .unreliable
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    private func publish(data: Data) {
        if let measurement = self.measurement {
            let now: Date? = granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.publishedBytes(sentBytes: data.count, timestamp: now)
            }
        }
        self.publishObjectDelegate?.publishObject(self.namespace, data: data, group: true)
    }

    private func encode() throws -> Data? {
        let format = DecimusAudioEngine.format
        let windowFrames: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate * self.opusWindowSize.rawValue)
        var timestamp: AudioTimeStamp = .init()
        let availableFrames = TPCircularBufferPeek(buffer,
                                                   &timestamp,
                                                   format.streamDescription)
        guard availableFrames >= windowFrames else { return nil }

        let pcm: AVAudioPCMBuffer = .init(pcmFormat: format, frameCapacity: windowFrames)!
        pcm.frameLength = windowFrames
        var inOutFrames: AVAudioFrameCount = windowFrames
        TPCircularBufferDequeueBufferListFrames(buffer,
                                                &inOutFrames,
                                                pcm.audioBufferList,
                                                &timestamp,
                                                format.streamDescription)
        pcm.frameLength = inOutFrames
        guard inOutFrames == windowFrames else {
            Self.logger.info("Dequeue only got: \(inOutFrames)/\(windowFrames)")
            return nil
        }

        return try encoder.write(data: pcm)
    }

    func publish(_ flag: Bool) {}
    
    func startProcessing() {
        self.transmit.store(true, ordering: .releasing)
    }
    
    func stopProcessing() {
        self.transmit.store(false, ordering: .releasing)
    }
}
