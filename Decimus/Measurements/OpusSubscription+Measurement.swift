import AVFAudio

extension OpusSubscription {
    actor OpusSubscriptionMeasurement: Measurement {
        let id = UUID()
        var name: String = "OpusSubscription"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0
        private var missing: UInt64 = 0
        private var callbacks: UInt64 = 0
        private var dropped: UInt64 = 0

        init(namespace: QuicrNamespace) {
            tags["namespace"] = namespace
        }

        func receivedFrames(received: AVAudioFrameCount, timestamp: Date?) {
            self.frames += UInt64(received)
            record(field: "receivedFrames", value: self.frames as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: UInt, timestamp: Date?) {
            self.bytes += UInt64(received)
            record(field: "receivedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
        }

        func missingSeq(missingCount: UInt64, timestamp: Date?) {
            self.missing += missingCount
            record(field: "missingSeqs", value: self.missing as AnyObject, timestamp: timestamp)
        }

        func framesUnderrun(underrun: UInt64, timestamp: Date?) {
            record(field: "framesUnderrun", value: underrun as AnyObject, timestamp: timestamp)
        }

        func concealmentFrames(concealed: UInt64, timestamp: Date?) {
            record(field: "framesConcealed", value: concealed as AnyObject, timestamp: timestamp)
        }

        func callbacks(callbacks: UInt64, timestamp: Date?) {
            record(field: "callbacks", value: callbacks as AnyObject, timestamp: timestamp)
        }

        func recordLibJitterMetrics(metrics: Metrics, timestamp: Date?) {
            record(field: "concealed", value: metrics.concealed_frames as AnyObject, timestamp: timestamp)
            record(field: "filled", value: metrics.filled_packets as AnyObject, timestamp: timestamp)
            record(field: "skipped", value: metrics.skipped_frames as AnyObject, timestamp: timestamp)
            record(field: "missed", value: metrics.update_missed_frames as AnyObject, timestamp: timestamp)
            record(field: "updated", value: metrics.updated_frames as AnyObject, timestamp: timestamp)
        }

        func droppedFrames(dropped: Int, timestamp: Date?) {
            self.dropped += UInt64(dropped)
            record(field: "dropped", value: self.dropped as AnyObject, timestamp: timestamp)
        }

        func depth(depthMs: Int, timestamp: Date) {
            record(field: "currentDepth", value: TimeInterval(depthMs) / 1000.0, timestamp: timestamp)
        }
    }
}
