import DequeModule

class SlidingWindow<T: Numeric> {
    private var values: Deque<(timestamp: Date, value: T)> = []
    private let length: TimeInterval

    init(length: TimeInterval) {
        self.length = length
    }

    func add(timestamp: Date, value: T) {
        // Remove values that are too old.
        while let first = self.values.first,
              timestamp.timeIntervalSince(first.timestamp) > self.length {
            _ = self.values.popFirst()
        }

        self.values.append((timestamp, value))
    }

    func get(from: Date) -> [T] {
        self.values.compactMap {
            from.timeIntervalSince($0.timestamp) <= self.length ? $0.value : nil
        }
    }
}

class SlidingTimeWindow {
    private let window: SlidingWindow<TimeInterval>
    private var lastSubmit: Date?

    init(length: TimeInterval) {
        self.window = .init(length: length)
    }

    func add(timestamp: Date) {
        if let lastSubmit = self.lastSubmit {
            let elapsed = timestamp.timeIntervalSince(lastSubmit)
            self.window.add(timestamp: timestamp, value: elapsed)
        }
        self.lastSubmit = timestamp
    }

    func max(from: Date) -> TimeInterval? {
        self.window.get(from: from).max()
    }
}
