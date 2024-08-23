extension VideoJitterBuffer {
    actor VideoJitterBufferMeasurement: Measurement {
        let id = UUID()
        var name: String = "VideoJitterBuffer"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var underruns: UInt64 = 0
        private var reads: UInt64 = 0
        private var writes: UInt64 = 0
        private var flushed: UInt64 = 0
        private var pausedWaitTime = false

        init(namespace: QuicrNamespace) {
            tags["namespace"] = namespace
        }

        func currentDepth(depth: TimeInterval, timestamp: Date?) {
            guard depth.isFinite,
                  depth.truncatingRemainder(dividingBy: 1) != 0 else {
                return
            }
            record(field: "currentDepth", value: UInt32(depth * 1000) as AnyObject, timestamp: timestamp)
        }

        func targetDepth(depth: TimeInterval, timestamp: Date) {
            record(field: "targetDepth", value: depth, timestamp: timestamp)
        }

        func idealTargetDepth(depth: TimeInterval, timestamp: Date) {
            record(field: "idealDepth", value: depth, timestamp: timestamp)
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

        func waitTime(value: TimeInterval, timestamp: Date?) {
            if self.pausedWaitTime && value < 0 {
                // Don't spam negative times.
                return
            }
            record(field: "waitTime", value: value as AnyObject, timestamp: timestamp)
            self.pausedWaitTime = value < 0
        }

        func read(timestamp: Date?) {
            self.reads += 1
            record(field: "reads", value: self.reads as AnyObject, timestamp: timestamp)
        }
    }
}
