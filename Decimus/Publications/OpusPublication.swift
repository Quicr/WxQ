// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import AVFoundation
import CoreAudio
import os

class OpusPublication: Publication {
    private static let logger = DecimusLogger(OpusPublication.self)

    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?

    private let encoder: LibOpusEncoder
    private let measurement: MeasurementRegistration<OpusPublicationMeasurement>?
    private let opusWindowSize: OpusWindowSize
    private let reliable: Bool
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine
    private var encodeTask: Task<(), Never>?
    private let pcm: AVAudioPCMBuffer
    private let windowFrames: AVAudioFrameCount

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
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(measurement: OpusPublicationMeasurement(namespace: namespace),
                                     submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics

        // Create a buffer to hold raw data waiting for encode.
        let format = DecimusAudioEngine.format
        self.windowFrames = AVAudioFrameCount(format.sampleRate * self.opusWindowSize.rawValue)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: self.windowFrames) else {
            throw "Failed to allocate PCM buffer"
        }
        self.pcm = pcm

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

        Self.logger.info("Registered OPUS publication for source \(sourceID)")
    }

    deinit {
        self.encodeTask?.cancel()
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
                await measurement.measurement.publishedBytes(sentBytes: data.count, timestamp: now)
            }
        }
        self.publishObjectDelegate?.publishObject(self.namespace, data: data, group: true)
    }

    private func encode() throws -> Data? {
        guard let buffer = self.engine.microphoneBuffer else { throw "No Audio Input" }

        // Are there enough frames available to fill an opus window?
        let available = buffer.peek()
        guard available.frames >= self.windowFrames else { return nil }

        // Dequeue a window size worth of data.
        self.pcm.frameLength = self.windowFrames
        let dequeued = buffer.dequeue(frames: self.windowFrames, buffer: &self.pcm.mutableAudioBufferList.pointee)
        self.pcm.frameLength = dequeued.frames
        guard dequeued.frames == self.windowFrames else {
            Self.logger.warning("Dequeue only got: \(dequeued.frames)/\(self.windowFrames)")
            return nil
        }

        // Encode this data.
        return try self.encoder.write(data: self.pcm)
    }

    func publish(_ flag: Bool) {}
}
