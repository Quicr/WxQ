import InfluxDBSwift
import Foundation
import os

actor InfluxMetricsSubmitter: MetricsSubmitter {
    private class WeakMeasurement {
        weak var measurement: (any Measurement)?
        let id: UUID
        init (_ measurement: any Measurement) {
            self.measurement = measurement
            self.id = measurement.id
        }
    }

    private static let logger = DecimusLogger(InfluxMetricsSubmitter.self)

    private let client: InfluxDBClient
    private var measurements: [UUID: WeakMeasurement] = [:]
    private var tags: [String: String]

    init(config: InfluxConfig, tags: [String: String]) {
        // Create the influx API instance.
        client = .init(url: config.url,
                       token: config.token,
                       options: .init(bucket: config.bucket,
                                      org: config.org,
                                      enableGzip: true))
        self.tags = tags
    }

    func register(measurement: Measurement) {
        let updated = self.measurements.updateValue(.init(measurement), forKey: measurement.id)
        assert(updated == nil)
        guard updated == nil else {
            Self.logger.error("Shouldn't call register for existing measurement: \(measurement)")
            return
        }
    }

    func unregister(id: UUID) {
        let removed = self.measurements.removeValue(forKey: id)
        assert(removed != nil)
        guard removed != nil else {
            Self.logger.error("Shouldn't call unregister for non-existing ID: \(id)")
            return
        }
    }

    func submit() async {
        var points: [InfluxDBClient.Point] = []
        var toRemove: [UUID] = []
        for pair in self.measurements {
            let weakMeasurement = pair.value
            guard let measurement = weakMeasurement.measurement else {
                assert(false)
                Self.logger.warning("Removing dead measurement")
                toRemove.append(weakMeasurement.id)
                continue
            }
            let fields = await measurement.fields
            await measurement.clear()
            for timestampedDict in fields {
                let point: InfluxDBClient.Point = .init(await measurement.name)
                for tag in await measurement.tags {
                    point.addTag(key: tag.key, value: tag.value)
                }
                for tag in self.tags {
                    point.addTag(key: tag.key, value: tag.value)
                }
                if let realTime = timestampedDict.key {
                    point.time(time: .date(realTime))
                }
                for appPoint in timestampedDict.value {
                    if let tags = appPoint.tags {
                        for tag in tags {
                            point.addTag(key: tag.key, value: tag.value)
                        }
                    }
                    point.addField(key: appPoint.fieldName, value: Self.getFieldValue(value: appPoint.value))
                    points.append(point)
                }
            }
        }

        // Clean up dead weak references.
        for id in toRemove {
            self.measurements.removeValue(forKey: id)
        }

        guard !points.isEmpty else { return }

        do {
            try await client.makeWriteAPI().write(points: points, responseQueue: .global(qos: .utility))
        } catch {
            Self.logger.warning("Failed to write metrics: \(error)")
        }
    }

    private static func getFieldValue(value: AnyObject) -> InfluxDBClient.Point.FieldValue? {
        switch value {
        case is Int16, is Int32, is Int64:
            return .int((value as? Int)!)
        case is UInt8, is UInt16, is UInt32, is UInt64:
            return .uint((value as? UInt)!)
        case is Float:
            return .double(Double((value as? Float)!))
        case is Double:
            return .double((value as? Double)!)
        case is String:
            return .string((value as? String)!)
        case is Bool:
            return .boolean((value as? Bool)!)
        default:
            return nil
        }
    }

    deinit {
        client.close()
    }
}
