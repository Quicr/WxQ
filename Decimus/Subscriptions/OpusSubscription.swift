import AVFAudio
import CoreAudio
import os

class OpusSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(OpusSubscription.self)

    let sourceId: SourceIDType
    private let engine: DecimusAudioEngine
    private let measurement: MeasurementRegistration<OpusSubscriptionMeasurement>?
    private let reliable: Bool
    private let granularMetrics: Bool
    private var seq: UInt32 = 0
    private let handlerLock = OSAllocatedUnfairLock()
    private var handler: OpusHandler?
    private var cleanupTask: Task<(), Never>?
    private let cleanupTimer: TimeInterval = 1.5
    private var lastUpdateTime: Date?
    private let jitterDepth: TimeInterval
    private let jitterMax: TimeInterval
    private let opusWindowSize: OpusWindowSize

    init(sourceId: SourceIDType,
         profileSet: QClientProfileSet,
         engine: DecimusAudioEngine,
         submitter: MetricsSubmitter?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         granularMetrics: Bool) throws {
        self.sourceId = sourceId
        self.engine = engine
        if let submitter = submitter {
            let measurement = OpusSubscriptionMeasurement(namespace: sourceId)
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.jitterDepth = jitterDepth
        self.jitterMax = jitterMax
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics

        // Create the actual audio handler upfront.
        self.handler = try .init(sourceId: self.sourceId,
                                 engine: self.engine,
                                 measurement: self.measurement,
                                 jitterDepth: self.jitterDepth,
                                 jitterMax: self.jitterMax,
                                 opusWindowSize: self.opusWindowSize,
                                 granularMetrics: self.granularMetrics)

        // Make task for cleaning up audio handlers.
        self.cleanupTask = .init(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                self.handlerLock.withLock {
                    // Remove the audio handler if expired.
                    guard let lastUpdateTime = self.lastUpdateTime else { return }
                    if Date.now.timeIntervalSince(lastUpdateTime) >= self.cleanupTimer {
                        self.lastUpdateTime = nil
                        self.handler = nil
                    }
                }
                try? await Task.sleep(for: .seconds(self.cleanupTimer), tolerance: .seconds(self.cleanupTimer), clock: .continuous)
            }
        }

        Self.logger.info("Subscribed to OPUS stream")
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 profileSet: QClientProfileSet,
                 transportMode: UnsafeMutablePointer<TransportMode>!) -> Int32 {
        transportMode.pointee = self.reliable ? .reliablePerGroup : .unreliable
        return SubscriptionError.none.rawValue
    }

    func update(_ sourceId: SourceIDType!, label: String!, profileSet: QClientProfileSet) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ name: String!,
                          data: UnsafeRawPointer!,
                          length: Int,
                          groupId: UInt32,
                          objectId: UInt16) -> Int32 {
        let now: Date = .now
        self.lastUpdateTime = now

        // Metrics.
        let date: Date? = self.granularMetrics ? now : nil

        // TODO: Handle sequence rollover.
        if groupId > self.seq {
            let missing = groupId - self.seq - 1
            let currentSeq = self.seq
            if let measurement = measurement {
                Task(priority: .utility) {
                    await measurement.measurement.receivedBytes(received: UInt(length), timestamp: date)
                    if missing > 0 {
                        Self.logger.warning("LOSS! \(missing) packets. Had: \(currentSeq), got: \(groupId)")
                        await measurement.measurement.missingSeq(missingCount: UInt64(missing), timestamp: date)
                    }
                }
            }
            self.seq = groupId
        }

        // Do we need to create the handler?
        let handler: OpusHandler
        do {
            handler = try self.handlerLock.withLock {
                guard let handler = self.handler else {
                    let handler = try OpusHandler(sourceId: self.sourceId,
                                                  engine: self.engine,
                                                  measurement: self.measurement,
                                                  jitterDepth: self.jitterDepth,
                                                  jitterMax: self.jitterMax,
                                                  opusWindowSize: self.opusWindowSize,
                                                  granularMetrics: self.granularMetrics)
                    self.handler = handler
                    return handler
                }
                return handler
            }
        } catch {
            Self.logger.error("Failed to recreate audio handler")
            return SubscriptionError.none.rawValue
        }

        do {
            try handler.submitEncodedAudio(data: .init(bytesNoCopy: .init(mutating: data),
                                                       count: length,
                                                       deallocator: .none),
                                           sequence: groupId,
                                           date: date)
        } catch {
            Self.logger.error("Failed to handle encoded audio: \(error.localizedDescription)")
        }

        return SubscriptionError.none.rawValue
    }
}
