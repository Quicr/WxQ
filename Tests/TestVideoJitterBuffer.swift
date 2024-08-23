import CoreMedia
import XCTest
@testable import Decimus

extension DecimusVideoFrame: Equatable {
    public static func == (lhs: Decimus.DecimusVideoFrame, rhs: Decimus.DecimusVideoFrame) -> Bool {
        lhs.samples == rhs.samples &&
            lhs.groupId == rhs.groupId &&
            lhs.objectId == rhs.objectId &&
            lhs.sequenceNumber == rhs.sequenceNumber &&
            lhs.fps == rhs.fps &&
            lhs.orientation == rhs.orientation &&
            lhs.verticalMirror == rhs.verticalMirror
    }
}

final class TestVideoJitterBuffer: XCTestCase {

    /// Nothing should be returned until the min depth has been exceeded.
    func doTestPlayout() throws {
        try testPlayout(sort: true)
        try testPlayout(sort: false)
    }

    func exampleSample(groupId: UInt32,
                       objectId: UInt16,
                       sequenceNumber: UInt64,
                       fps: UInt8) throws -> DecimusVideoFrame {
        let sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [.init(duration: .init(value: 1, timescale: CMTimeScale(fps)),
                                                              presentationTimeStamp: .init(seconds: Date.now.timeIntervalSince1970, preferredTimescale: 1),
                                                              decodeTimeStamp: .invalid)],
                                        sampleSizes: [])
        return .init(samples: [sample],
                     groupId: groupId,
                     objectId: objectId,
                     sequenceNumber: sequenceNumber,
                     fps: fps,
                     orientation: nil,
                     verticalMirror: nil,
                     captureDate: .now)
    }

    func testPlayout(sort: Bool) throws {
        let duration: TimeInterval = 1 / 30
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: sort,
                                           minDepth: duration * 2.5,
                                           capacity: duration * 4,
                                           duration: duration)

        // Write 1, no play.
        let frame1 = try exampleSample(groupId: 0,
                                       objectId: 0,
                                       sequenceNumber: 0,
                                       fps: 30)
        try buffer.write(videoFrame: frame1, from: Date.now)
        XCTAssertNil(buffer.read(from: Date.now))

        // Write 2, no play.
        let frame2 = try exampleSample(groupId: 0,
                                       objectId: 1,
                                       sequenceNumber: 1,
                                       fps: 30)
        try buffer.write(videoFrame: frame2, from: Date.now)
        XCTAssertNil(buffer.read(from: Date.now))

        // Write 3, play, get 1.
        let frame3 = try exampleSample(groupId: 0,
                                       objectId: 2,
                                       sequenceNumber: 2,
                                       fps: 30)
        try buffer.write(videoFrame: frame3, from: Date.now)
        XCTAssertEqual(frame1, buffer.read(from: Date.now))

        // Write 4, get 2.
        let frame4 = try exampleSample(groupId: 0,
                                       objectId: 3,
                                       sequenceNumber: 3,
                                       fps: 30)
        try buffer.write(videoFrame: frame4, from: Date.now)
        XCTAssertEqual(frame2, buffer.read(from: Date.now))

        // Get 3, 4 and done.
        XCTAssertEqual(frame3, buffer.read(from: Date.now))
        XCTAssertEqual(frame4, buffer.read(from: Date.now))
        XCTAssertNil(buffer.read(from: Date.now))
    }

    // Out of orders should go in order.
    func testOutOfOrder() throws {
        let duration: TimeInterval = 1 / 30
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: true,
                                           minDepth: 0,
                                           capacity: duration * 2,
                                           duration: duration)

        // Write newer.
        let frame2 = try exampleSample(groupId: 0,
                                       objectId: 1,
                                       sequenceNumber: 1,
                                       fps: 30)
        try buffer.write(videoFrame: frame2, from: Date.now)

        // Write older.
        let frame1 = try exampleSample(groupId: 0,
                                       objectId: 0,
                                       sequenceNumber: 0,
                                       fps: 30)
        try buffer.write(videoFrame: frame1, from: Date.now)

        // Get older first.
        let read1 = buffer.read(from: Date.now)
        XCTAssertEqual(frame1, read1)

        // Then newer.
        let read2 = buffer.read(from: Date.now)
        XCTAssertEqual(frame2, read2)
    }

    // Out of orders should not be allowed past a read.
    func testOlderFrame() throws {
        try testOlderFrame(true)
        try testOlderFrame(false)
    }

    func testOlderFrame(_ sort: Bool) throws {
        let duration: TimeInterval = 1 / 30
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: sort,
                                           minDepth: 0,
                                           capacity: duration * 2,
                                           duration: duration)

        // Write newer.
        let frame2 = try exampleSample(groupId: 0,
                                       objectId: 1,
                                       sequenceNumber: 1,
                                       fps: 30)
        try buffer.write(videoFrame: frame2, from: Date.now)

        // Read newer.
        let read1 = buffer.read(from: Date.now)
        XCTAssertEqual(frame2, read1)

        // Write older should fail.
        let frame1 = try exampleSample(groupId: 0,
                                       objectId: 0,
                                       sequenceNumber: 0,
                                       fps: 30)
        XCTAssertThrowsError(try buffer.write(videoFrame: frame1, from: Date.now)) {
            XCTAssertEqual("Refused enqueue as older than last read", $0 as? String)
        }
    }

    func testWaitTimeNoDate() throws {
        let startTime: Date = .now
        var waitTime: TimeInterval?
        let minDepth: TimeInterval = 0.2
        let duration: TimeInterval = 1 / 30
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: false,
                                           minDepth: minDepth,
                                           capacity: minDepth,
                                           duration: duration)

        // No calculation possible with no frame available.
        waitTime = buffer.calculateWaitTime(from: startTime, offset: 0)
        XCTAssertNil(waitTime)
    }

    func testWaitTimeMinDepth() throws {
        let duration: TimeInterval = 1 / 30
        let startTime: Date = .now
        var waitTime: TimeInterval?
        let minDepth: TimeInterval = 0.2
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: false,
                                           minDepth: minDepth,
                                           capacity: minDepth,
                                           duration: duration)

        // At first write, and otherwise on time, we should wait the min depth.
        let presentation = CMTime(value: CMTimeValue(Date.timeIntervalSinceReferenceDate), timescale: 1)
        let diff = startTime.timeIntervalSinceReferenceDate - presentation.seconds
        let sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [
                                            .init(duration: .init(value: 1,
                                                                  timescale: 30),
                                                  presentationTimeStamp: presentation,
                                                  decodeTimeStamp: .invalid)
                                        ],
                                        sampleSizes: [0])
        let frame = DecimusVideoFrame(samples: [sample],
                                      groupId: 1,
                                      objectId: 1,
                                      sequenceNumber: 1,
                                      fps: 1,
                                      orientation: nil,
                                      verticalMirror: nil,
                                      captureDate: .now)
        try buffer.write(videoFrame: frame, from: Date.now)
        waitTime = buffer.calculateWaitTime(from: startTime, offset: diff)
        XCTAssertNotNil(waitTime)
        XCTAssertEqual(minDepth, waitTime!, accuracy: 1 / 1000)
    }

    func testWaitTimeN() throws {
        let startTime: Date = .now
        let minDepth: TimeInterval = 0.2
        let duration = CMTime(value: 1, timescale: 30)
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: false,
                                           minDepth: minDepth,
                                           capacity: minDepth * 2,
                                           duration: duration.seconds)
        let presentation = CMTime(value: CMTimeValue(startTime.timeIntervalSinceReferenceDate), timescale: 1)
        var diff: TimeInterval?

        for count in 0..<2 {
            if diff == nil {
                diff = startTime.timeIntervalSinceReferenceDate - presentation.seconds
            }
            let adjust = CMTimeMultiply(duration, multiplier: Int32(count))
            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [
                                                .init(duration: duration,
                                                      presentationTimeStamp: CMTimeAdd(presentation, adjust),
                                                      decodeTimeStamp: .invalid)
                                            ],
                                            sampleSizes: [0])
            let frame = DecimusVideoFrame(samples: [sample],
                                          groupId: 1,
                                          objectId: 1,
                                          sequenceNumber: 1,
                                          fps: 1,
                                          orientation: nil,
                                          verticalMirror: nil,
                                          captureDate: .now)
            try buffer.write(videoFrame: frame, from: Date.now)
        }

        // There are 2 frames in the buffer. If we have waited min depth, first should be 0.
        let waitTime = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth), offset: diff!)
        XCTAssertNotNil(waitTime)
        print(waitTime!)
        XCTAssertEqual(0, waitTime!, accuracy: 1 / 1000)

        // If we read this first one, next should be a duration away.
        let read = buffer.read(from: Date.now)
        XCTAssertNotNil(read)
        let firstReadWait = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth), offset: diff!)
        XCTAssertNotNil(firstReadWait)
        XCTAssertEqual(duration.seconds, firstReadWait!, accuracy: 1 / 1000)

        // Any time we take (less than a frame duration here) should proportionally decrease the wait.
        let later = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth).addingTimeInterval(duration.seconds / 2), offset: diff!)
        XCTAssertNotNil(later)
        XCTAssertEqual(duration.seconds / 2, later!, accuracy: 1 / 1000)

        // If we wait too long, say 1.5 durations, we should get negative 1/2 duration.
        let negativeWait = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth).addingTimeInterval(duration.seconds * 1.5), offset: diff!)
        XCTAssertNotNil(negativeWait)
        XCTAssertEqual(-duration.seconds / 2, negativeWait!, accuracy: 1 / 1000)
    }

    func testFastArrivalPast() throws {
        try testFastArrival(greaterThanNow: false)
    }

    func testFastArrivalFuture() throws {
        try testFastArrival(greaterThanNow: true)
    }

    // Test that fast arrivals of frames don't effect playout time.
    func testFastArrival(greaterThanNow: Bool) throws {
        // Create jitter buffer.
        let capacity = 1000
        let targetDepth: TimeInterval = 0.2
        let fps = 30
        let duration: TimeInterval = 1 / TimeInterval(fps)
        let buffer = try VideoJitterBuffer(namespace: "1234",
                                           metricsSubmitter: nil,
                                           sort: false,
                                           minDepth: targetDepth,
                                           capacity: TimeInterval(capacity) * duration,
                                           duration: duration)

        // A lot of frames will arrive now().
        let firstArrival = Date.now
        let nowInterval = firstArrival.timeIntervalSinceReferenceDate

        // We will start their presentation at some random value (before or after now).
        let range: Range<TimeInterval>
        if greaterThanNow {
            range = nowInterval..<(nowInterval * 100)
        } else {
            range = 0..<nowInterval
        }
        var presentationTime: TimeInterval = .random(in: range)

        // Record the media start time from the first frame.
        let diff = firstArrival.timeIntervalSinceReferenceDate - presentationTime

        // Burst arrive N frames all of duration and presentationTime += duration.
        for index in 0..<capacity {
            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 0,
                                            sampleTimings: [.init(duration: .init(value: 1, timescale: .init(fps)),
                                                                  presentationTimeStamp: .init(seconds: presentationTime,
                                                                                               preferredTimescale: 30000),
                                                                  decodeTimeStamp: .invalid)],
                                            sampleSizes: [])
            presentationTime += duration
            let frame = DecimusVideoFrame(samples: [sample],
                                          groupId: UInt32(index),
                                          objectId: 0,
                                          sequenceNumber: UInt64(index),
                                          fps: UInt8(fps),
                                          orientation: .portrait,
                                          verticalMirror: false,
                                          captureDate: nil)
            try buffer.write(videoFrame: frame, from: Date.now)
        }

        // Start reading frames and moving through media timeline,
        // starting from the same instant as arrival.
        var from = firstArrival
        for index in 0..<capacity {
            guard let waitTime = buffer.calculateWaitTime(from: from, offset: diff) else {
                XCTFail()
                return
            }
            if index == 0 {
                // First frame would play out now() but held for minDepth.
                XCTAssertEqual(waitTime, targetDepth, accuracy: 1 / 1000)
            } else {
                // All other frames should request to be played out a duration away from each other.
                XCTAssertEqual(waitTime, duration, accuracy: 1 / 1000)
            }
            // This is our mock sleep, moving our timeline forward.
            from.addTimeInterval(waitTime)

            // Dequeue this frame.
            guard let frame = buffer.read(from: Date.now) else {
                XCTFail()
                return
            }

            // Sanity.
            XCTAssertEqual(frame.sequenceNumber!, UInt64(index))
        }
    }

    func testDepth() throws {
        let fps: UInt8 = 30
        let duration: TimeInterval = 1 / TimeInterval(fps)
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: true,
                                           minDepth: 0,
                                           capacity: 2,
                                           duration: duration)

        // 0 when empty.
        XCTAssertEqual(buffer.getDepth(), 0)

        // Enqueue one.
        let frame1 = try exampleSample(groupId: 0, objectId: 1, sequenceNumber: 1, fps: fps)
        try buffer.write(videoFrame: frame1, from: Date.now)
        XCTAssertEqual(buffer.getDepth(), 1 / TimeInterval(fps))

        // Enqueue two.
        let frame2 = try exampleSample(groupId: 0, objectId: 2, sequenceNumber: 2, fps: fps)
        try buffer.write(videoFrame: frame2, from: Date.now)
        XCTAssertEqual(buffer.getDepth(), (1 / (TimeInterval(fps)) * 2))
    }
}
