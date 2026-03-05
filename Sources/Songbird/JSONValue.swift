import Foundation

/// Represents any JSON value. Used internally for field-level encryption manipulation.
internal enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        // Try bool before int/double (JSON booleans are sometimes decoded as numbers)
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
            return
        }

        if let intVal = try? container.decode(Int64.self) {
            self = .int(intVal)
            return
        }

        if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
            return
        }

        if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
            return
        }

        if let arrayVal = try? container.decode([JSONValue].self) {
            self = .array(arrayVal)
            return
        }

        if let objectVal = try? container.decode([String: JSONValue].self) {
            self = .object(objectVal)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Cannot decode JSONValue"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    /// Serialize this value to a JSON fragment (for encryption).
    func toJSONFragmentData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Parse a JSON fragment back to a JSONValue (for decryption).
    static func fromJSONFragmentData(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - DynamicCodingKey

internal struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

// MARK: - EncryptedPayload

/// An Event that carries pre-encrypted JSON fields. Used by CryptoShreddingStore to pass
/// partially-encrypted data through the inner EventStore's append method.
internal struct EncryptedPayload: Event {
    let originalEventType: String
    let fields: [String: JSONValue]

    var eventType: String { originalEventType }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    init(originalEventType: String, fields: [String: JSONValue]) {
        self.originalEventType = originalEventType
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var dict: [String: JSONValue] = [:]
        for key in container.allKeys {
            dict[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.fields = dict
        self.originalEventType = ""
    }

    static func == (lhs: EncryptedPayload, rhs: EncryptedPayload) -> Bool {
        lhs.originalEventType == rhs.originalEventType && lhs.fields == rhs.fields
    }
}
