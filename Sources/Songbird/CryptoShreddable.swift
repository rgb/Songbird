import Foundation

public enum FieldProtection: Sendable, Equatable {
    case pii
    case retention(Duration)
    case piiAndRetention(Duration)
}

public protocol CryptoShreddable {
    static var fieldProtection: [String: FieldProtection] { get }
}
