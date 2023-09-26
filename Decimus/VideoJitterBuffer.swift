import Foundation
import OrderedCollections

/// A very simplified jitter buffer designed to contain compressed video frames in order.
class VideoJitterBuffer {
    
    struct Config: Codable {
        var mode: Mode = .none
        var minDepth: TimeInterval = 0.2
    }
    
    enum Mode: CaseIterable, Identifiable, Codable {
        case pid; case interval; case none
        var id: Self { self }
    }

    private actor _Measurement: Measurement {
        var name: String = "VideoJitterBuffer"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var underruns: UInt64 = 0
        private var readAttempts: UInt64 = 0
        private var writes: UInt64 = 0
        private var flushed: UInt64 = 0

        init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
            tags["namespace"] = namespace
            Task(priority: .utility) {
                await submitter.register(measurement: self)
            }
        }

        func currentDepth(depth: TimeInterval, timestamp: Date?) {
            record(field: "currentDepth", value: UInt32(depth * 1000) as AnyObject, timestamp: timestamp)
        }

        func underrun(timestamp: Date?) {
            self.underruns += 1
            record(field: "underruns", value: self.underruns as AnyObject, timestamp: timestamp)
        }

        func write(timestamp: Date?) {
            self.writes += 1
            record(field: "writes", value: self.writes as AnyObject, timestamp: timestamp)
        }

        func flushed(count: UInt, timestamp: Date?) {
            self.flushed += UInt64(count)
            record(field: "flushed", value: self.flushed as AnyObject, timestamp: timestamp)
        }
    }

    typealias FrameAvailble = (VideoFrame) -> Void
    private var buffer: OrderedSet<VideoFrame>
    private let frameDuration: TimeInterval
    private let minDepth: TimeInterval
    private let lock: NSLock = .init()
    private let measurement: _Measurement?
    private var play: Bool = false
    private var lastSequenceRead: UInt64?
    private let sort: Bool
    private let frameAvailable: FrameAvailble
    private var dequeueTask: Task<(),Never>?
    private let config: Config

    // PID tuning.
    private var kp: Double = 0.01
    private var ki: Double = 0.001
    private var kd: Double = 0.001
    private var integral: Double = 0
    private var lastError: Double = 0
    
    // Time calculation.
    private var firstSeq: UInt64?
    private var firstDequeueTime: Date?
    private var dequeuedCount: UInt64 = 0

    /// Create a new video jitter buffer.
    /// - Parameter namespace The namespace of the video this buffer is used for, for identification purposes.
    /// - Parameter frameDuration The duration of the video frames contained within the buffer.
    /// - Parameter metricsSubmitter Optionally, an object to submit metrics through.
    /// - Parameter sort True to actually sort on sequence number, false if they're already in order.
    /// - Parameter config Jitter buffer configuration.
    /// - Parameter frameAvailable Callback with a paced frame to render.
    init(namespace: QuicrNamespace,
         frameDuration: TimeInterval,
         metricsSubmitter: MetricsSubmitter?,
         sort: Bool,
         config: Config,
         frameAvailable: @escaping FrameAvailble) throws {
        self.frameDuration = frameDuration
        self.minDepth = ceil(config.minDepth / frameDuration) * frameDuration
        self.buffer = .init(minimumCapacity: Int(ceil(minDepth / frameDuration)))
        if let metricsSubmitter = metricsSubmitter {
            measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            measurement = nil
        }
        self.sort = sort
        guard config.mode != .none else {
            throw "Jitter buffer shouldn't be created when mode none"
        }
        self.config = config
        self.frameAvailable = frameAvailable
    }

    /// Write a video frame into the jitter buffer.
    /// - Parameter videoFrame The video frame structure to attempt to sort into the buffer.
    /// - Returns True if successfully enqueued, false if it was older than the last read and thus dropped.
    func write(videoFrame: VideoFrame) -> Bool {
        let result = lock.withLock {
            let thisSeq = videoFrame.getSeq()
            if let lastSequenceRead = self.lastSequenceRead {
                guard thisSeq > lastSequenceRead else {
                    print("[VideoJitterBuffer] Skipping \(thisSeq), had \(lastSequenceRead)")
                    return false
                }
            }
            self.buffer.append(videoFrame)
            if self.sort {
                self.buffer.sort()
            }
            
            if self.dequeueTask == nil {
                let required: Int = .init(ceil(self.minDepth / self.frameDuration))
                if self.buffer.count >= required {
                    self.dequeueTask = .init(priority: .high) { [weak self] in
                        while !Task.isCancelled {
                            guard let self = self else { return }

                            // Wait until we expect to have a frame available.
                            let waitTime = self.lock.withLock {
                                self.calculateWaitTime()
                            }
                            let ns = waitTime * 1_000_000_000
                            if ns > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(ns))
                            } else {
                                print("Instant catchup")
                            }

                            // Attempt to dequeue a frame.
                            self.lock.withLock {
                                if let frame = self.read() {
                                    self.frameAvailable(frame)
                                }
                            }
                        }
                    }
                }
            }
            return true
        }
        if let measurement = self.measurement {
            let now: Date = .now
            Task(priority: .utility) {
                await measurement.write(timestamp: now)
            }
        }
        return result
    }

    /// Attempt to read a frame from the front of the buffer.
    /// The lock should already be held by the caller.
    /// - Returns Either the oldest available frame, or nil.
    private func read() -> VideoFrame? {
        let now: Date = .now
        let depth: TimeInterval = TimeInterval(self.buffer.count) * self.frameDuration
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.currentDepth(depth: depth, timestamp: now)
            }
        }

        // Ensure there's something to get.
        guard self.buffer.count > 0 else {
            if let measurement = self.measurement {
                Task(priority: .utility) {
                    await measurement.underrun(timestamp: now)
                }
            }
            return nil
        }

        // Get the oldest available frame.
        let oldest = self.buffer.removeFirst()
        self.lastSequenceRead = oldest.getSeq()
        if self.firstSeq == nil {
            self.firstSeq = self.lastSequenceRead
            self.firstDequeueTime = .now
        }
        self.dequeuedCount += 1
        return oldest
    }

    /// Flush the jitter buffer until the target group is at the front, or there are no more frames left.
    /// - Parameter targetGroup The group to flush frames up until.
    func flushTo(targetGroup groupId: UInt32) {
        var flushCount: UInt = 0
        lock.withLock {
            while self.buffer.count > 0 && self.buffer[0].groupId < groupId {
                let flushed = self.buffer.removeFirst()
                self.lastSequenceRead = flushed.getSeq()
                flushCount += 1
            }
        }

        if let measurement = self.measurement {
            let now: Date = .now
            let metric = flushCount
            Task(priority: .utility) {
                await measurement.flushed(count: metric, timestamp: now)
            }
        }
    }
    
    private func calculateWaitTime() -> TimeInterval {
        switch self.config.mode {
        case .interval:
            calculateWaitTimeInterval()
        case .pid:
            calculateWaitTimePid()
        case .none:
            fatalError()
        }
    }
    
    private func calculateWaitTimePid() -> TimeInterval {
        let currentDepth = TimeInterval(self.buffer.count) * self.frameDuration
        let error = self.minDepth - currentDepth
        self.integral += error
        let derivative = error - self.lastError
        self.lastError = error
        return self.frameDuration + (self.kp * error + self.ki * self.integral + self.kd * derivative)
    }
    
    private func calculateWaitTimeInterval() -> TimeInterval {
        guard let firstDequeueTime = self.firstDequeueTime else {
            return self.frameDuration
        }
        let expectedTime: Date = firstDequeueTime + (self.frameDuration * Double(dequeuedCount))
        return expectedTime.timeIntervalSinceNow
    }
}

extension VideoFrame: Hashable, Comparable {
    static func < (lhs: VideoFrame, rhs: VideoFrame) -> Bool {
        lhs.getSeq() < rhs.getSeq()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(getSeq())
    }

    static func == (lhs: VideoFrame, rhs: VideoFrame) -> Bool {
        lhs.getSeq() == rhs.getSeq()
    }

    func getSeq() -> UInt64 {
        (UInt64(self.groupId) << 16) | UInt64(self.objectId)
    }
}
