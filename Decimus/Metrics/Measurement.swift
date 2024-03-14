import Foundation

struct Point {
    let fieldName: String
    let value: AnyObject
    let tags: [String: String]?
}

typealias Fields = [Date?: [Point]]

protocol Measurement: Actor {
    var name: String { get }
    var fields: Fields { get set }
    var tags: [String: String] { get }
    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String:String]?)
}

extension Measurement {
    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String:String]? = nil) {
        if fields[timestamp] == nil {
            fields[timestamp] = []
        }
        fields[timestamp]!.append(.init(fieldName: field, value: value, tags: tags))
    }

    func clear() {
        fields.removeAll(keepingCapacity: true)
    }
}
