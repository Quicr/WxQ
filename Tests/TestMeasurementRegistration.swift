@testable import Decimus
import XCTest

final class TestMeasurementRegistration: XCTestCase {
    actor MockMetricsSubmitter: MetricsSubmitter {
        var measurement: Decimus.Measurement?
        typealias Callback = (UUID) -> Void
        private let registerCallback: Callback?
        private let unregisterCallback: Callback?

        init(registerCallback: Callback? = nil, unregisterCallback: Callback? = nil) {
            self.registerCallback = registerCallback
            self.unregisterCallback = unregisterCallback
        }

        func register(measurement: any Decimus.Measurement) {
            self.registerCallback?(measurement.id)
            self.measurement = measurement
        }

        func unregister(id: UUID) {
            self.unregisterCallback?(id)
            self.measurement = nil
        }

        func submit() async { }
    }

    actor MockMeasurement: Decimus.Measurement {
        let id = UUID()
        var name = "MockMeasurement"
        var fields: Decimus.Fields = [:]
        var tags: [String: String] = [:]
    }

    func testRegistration() async {
        let submitter = MockMetricsSubmitter()
        let measurement = MockMeasurement()

        // Measurement should register on creation.
        let registered = await submitter.measurement
        XCTAssertNil(registered)
        let registration = MeasurementRegistration(measurement: measurement, submitter: submitter)
        await registration.registration.value
        let expectedId = measurement.id
        let registeredId = await submitter.measurement?.id
        XCTAssertEqual(expectedId, registeredId)
    }

    func testImmediateDestruct() async {
        var register: UUID?
        var unregister: UUID?
        let registerCallback: MockMetricsSubmitter.Callback = {
            register = $0
        }
        let unregisterCallback: MockMetricsSubmitter.Callback = {
            unregister = $0
        }

        let submitter = MockMetricsSubmitter(registerCallback: registerCallback, unregisterCallback: unregisterCallback)
        let measurement = MockMeasurement()

        // Measurement should register on creation.
        var registered = await submitter.measurement
        XCTAssertNil(registered)
        var registration: MeasurementRegistration<MockMeasurement>? = .init(measurement: measurement,
                                                                            submitter: submitter)
        registration = nil
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(register, measurement.id)
        XCTAssertEqual(unregister, measurement.id)
        registered = await submitter.measurement
        XCTAssertNil(registered)
    }
}
