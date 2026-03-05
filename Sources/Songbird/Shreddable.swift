import Foundation

public enum Shreddable<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case value(T)
    case shredded

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .shredded
        } else {
            self = .value(try container.decode(T.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .value(let v):
            try container.encode(v)
        case .shredded:
            try container.encodeNil()
        }
    }
}

// MARK: - Literal Conformances

extension Shreddable: ExpressibleByStringLiteral, ExpressibleByExtendedGraphemeClusterLiteral,
    ExpressibleByUnicodeScalarLiteral where T == String
{
    public init(stringLiteral value: String) {
        self = .value(value)
    }

    public init(extendedGraphemeClusterLiteral value: String) {
        self = .value(value)
    }

    public init(unicodeScalarLiteral value: String) {
        self = .value(value)
    }
}

extension Shreddable: ExpressibleByIntegerLiteral where T: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: T.IntegerLiteralType) {
        self = .value(T(integerLiteral: value))
    }
}

extension Shreddable: ExpressibleByFloatLiteral where T: ExpressibleByFloatLiteral {
    public init(floatLiteral value: T.FloatLiteralType) {
        self = .value(T(floatLiteral: value))
    }
}

extension Shreddable: ExpressibleByBooleanLiteral where T == Bool {
    public init(booleanLiteral value: Bool) {
        self = .value(value)
    }
}
