import Foundation

/// Lossless generic JSON for round-trip flows: the Live TV timer create
/// flow GETs `/LiveTv/Timers/Defaults?programId=` and POSTs the payload
/// back unchanged. The HTTP client JSON-encodes request bodies via
/// `AnyEncodable`, so raw `Data` would be base64-encoded; this type
/// re-encodes the original structure faithfully instead.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Bridge from a JSONSerialization-style object ([String: Any] /
    /// [Any]). Used by the PlaybackInfo endpoint, whose DeviceProfile
    /// body is built as a plain dictionary by DirectPlayProfile.
    init(jsonObject: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
