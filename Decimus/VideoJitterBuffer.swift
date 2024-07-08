import Foundation
import OrderedCollections
import AVFoundation
import Atomics

// swiftlint:disable force_cast

/// A very simplified jitter buffer designed to contain compressed video frames in order.
class VideoJitterBuffer {

    struct Config: Codable {
        var mode: Mode = .none
        var minDepth: TimeInterval = 0.2
        var capacity: TimeInterval = 2
    }

    enum Mode: CaseIterable, Identifiable, Codable {
        case pid
        case interval
        case layer
        case none
        var id: Self { self }
    }

    private static let logger = DecimusLogger(VideoJitterBuffer.self)
    private let minDepth: TimeInterval
    private var buffer: CMBufferQueue
    private let measurement: MeasurementRegistration<VideoJitterBufferMeasurement>?
    private var play: Bool = false
    private var playToken: CMBufferQueueTriggerToken?
    private var lastSequenceRead = ManagedAtomic<UInt64>(0)
    private var lastSequenceSet = ManagedAtomic<Bool>(false)

    /// Create a new video jitter buffer.
    /// - Parameter namespace The namespace of the video this buffer is used for, for identification purposes.
    /// - Parameter metricsSubmitter Optionally, an object to submit metrics through.
    /// - Parameter sort True to actually sort on sequence number, false if they're already in order.
    /// - Parameter minDepth Fixed initial delay in seconds.
    /// - Parameter capacity Capacity in buffers / elements.
    init(namespace: QuicrNamespace,
         metricsSubmitter: MetricsSubmitter?,
         sort: Bool,
         minDepth: TimeInterval,
         capacity: Int) throws {
        let handlers = CMBufferQueue.Handlers { builder in
            builder.compare {
                if !sort {
                    return .compareLessThan
                }
                let first = $0 as! DecimusVideoFrame
                let second = $1 as! DecimusVideoFrame
                guard let seq1 = first.sequenceNumber,
                      let seq2 = second.sequenceNumber else {
                    Self.logger.error("Samples were missing sequence number")
                    return .compareLessThan
                }
                if seq1 < seq2 {
                    return .compareLessThan
                } else if seq1 > seq2 {
                    return .compareGreaterThan
                } else if seq1 == seq2 {
                    return .compareEqualTo
                }
                assert(false)
                return .compareLessThan
            }
            builder.getDecodeTimeStamp {
                ($0 as! DecimusVideoFrame).samples.first?.decodeTimeStamp ?? .invalid
            }
            builder.getDuration {
                ($0 as! DecimusVideoFrame).samples.first?.duration ?? .invalid
            }
            builder.getPresentationTimeStamp {
                ($0 as! DecimusVideoFrame).samples.first?.presentationTimeStamp ?? .invalid
            }
            builder.getSize {
                ($0 as! DecimusVideoFrame).samples.reduce(0) { $0 + $1.totalSampleSize }
            }
            builder.isDataReady {
                ($0 as! DecimusVideoFrame).samples.reduce(true) { $0 && $1.dataReadiness == .ready }
            }
        }
        self.buffer = try .init(capacity: capacity, handlers: handlers)
        if let metricsSubmitter = metricsSubmitter {
            let measurement = VideoJitterBufferMeasurement(namespace: namespace)
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }

        self.minDepth = minDepth
        let minDepthCM = CMTime(value: CMTimeValue(minDepth), timescale: 1)
        self.playToken = try self.buffer.installTrigger(condition: .whenDurationBecomesGreaterThanOrEqualTo(minDepthCM), { _ in
            self.play = true
        })
    }

    /// Write a video frame into the jitter buffer.
    /// Write should not be called concurrently with another write.
    /// - Parameter videoFrame The sample to attempt to sort into the buffer.
    func write(videoFrame: DecimusVideoFrame) throws {
        // Check expiry.
        if let thisSeq = videoFrame.sequenceNumber,
           self.lastSequenceSet.load(ordering: .acquiring) {
            guard thisSeq > self.lastSequenceRead.load(ordering: .acquiring) else {
                throw "Refused enqueue as older than last read"
            }
        }

        try self.buffer.enqueue(videoFrame)

        // Metrics.
        if let measurement = self.measurement {
            let now: Date = .now
            Task(priority: .utility) {
                await measurement.measurement.write(timestamp: now)
            }
        }
    }

    /// Attempt to read a frame from the front of the buffer.
    /// - Returns Either the oldest available frame, or nil.
    func read() -> DecimusVideoFrame? {
        let now: Date = .now
        let depth: TimeInterval = self.buffer.duration.seconds

        // Are we playing out?
        guard self.play else {
            return nil
        }

        // We won't stop.
        if let playToken = self.playToken {
            do {
                try self.buffer.removeTrigger(playToken)
            } catch {
                Self.logger.error("Failed to remove playout trigger: \(error.localizedDescription)")
            }
            self.playToken = nil
        }

        // Ensure there's something to get.
        guard let oldest = self.buffer.dequeue() else {
            if let measurement = self.measurement {
                Task(priority: .utility) {
                    await measurement.measurement.currentDepth(depth: depth, timestamp: now)
                    await measurement.measurement.underrun(timestamp: now)
                }
            }
            return nil
        }
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.currentDepth(depth: depth, timestamp: now)
                await measurement.measurement.read(timestamp: now)
            }
        }
        let sample = oldest as! DecimusVideoFrame
        if let sequenceNumber = sample.sequenceNumber {
            self.lastSequenceRead.store(sequenceNumber, ordering: .releasing)
            self.lastSequenceSet.store(true, ordering: .releasing)
        }
        return sample
    }

    /// Get the CMBuffer at the front of the buffer without removing it.
    /// - Returns The head of the buffer, if any.
    func peek() -> CMBuffer? {
        self.buffer.head
    }

    /// Get the current depth of the queue (sum of all contained durations).
    /// - Returns Duration in seconds.
    func getDepth() -> TimeInterval {
        self.buffer.duration.seconds
    }

    /// Calculate the estimated time interval until the next frame should be rendered.
    /// - Parameter from The time to calculate the time interval from.
    /// - Parameter offset Offset from the start point at which media starts.
    /// - Parameter since The start point of the media timeline.
    /// - Returns The time to wait, or nil if no estimation can be made. (There is no next frame).
    func calculateWaitTime(from: Date = .now, offset: TimeInterval, since: Date = .init(timeIntervalSinceReferenceDate: 0)) -> TimeInterval? {
        guard let peek = self.buffer.head else { return nil }
        let frame = peek as! DecimusVideoFrame
        guard let timestamp = frame.samples.first?.presentationTimeStamp else { return nil }
        let targetDate = Date(timeInterval: timestamp.seconds.advanced(by: offset), since: since)
        let waitTime = targetDate.timeIntervalSince(from) + self.minDepth
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.waitTime(value: waitTime, timestamp: from)
            }
        }
        return waitTime
    }
}
