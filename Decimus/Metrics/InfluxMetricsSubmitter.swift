import InfluxDBSwift
import Foundation
import os

actor InfluxMetricsSubmitter: MetricsSubmitter {
    private static let logger = DecimusLogger(InfluxMetricsSubmitter.self)

    private let client: InfluxDBClient
    private var measurements: [Measurement] = []
    private var tags: [String: String]

    init(config: InfluxConfig, tags: [String: String]) {
        // Create the influx API instance.
        client = .init(url: config.url,
                       token: config.token,
                       options: .init(bucket: config.bucket,
                                      org: config.org))
        self.tags = tags
    }

    func register(measurement: Measurement) {
        measurements.append(measurement)
    }

    func submit() async {
        var points: [InfluxDBClient.Point] = []
        for measurement in measurements {
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
                for fields in timestampedDict.value {
                    point.addField(key: fields.key, value: Self.getFieldValue(value: fields.value))
                    points.append(point)
                }
            }
        }

        guard !points.isEmpty else { return }

        do {
            try await client.makeWriteAPI().write(points: points, responseQueue: .global(qos: .utility))
        } catch {
            Self.logger.error("Failed to write: \(error)")
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
