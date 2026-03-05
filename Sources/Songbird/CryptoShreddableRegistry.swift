import Foundation

/// Maps event type strings to their ``FieldProtection`` dictionaries.
///
/// Needed on the read path where only the event type string is available
/// and the system needs to know which fields require decryption.
///
/// This is a simple value type intended to be initialized once at startup
/// and then only read. For concurrent access, wrap it in an appropriate
/// synchronization primitive or pass it as a `let` binding.
///
/// ```swift
/// var registry = CryptoShreddableRegistry()
/// registry.register(UserCreated.self, eventType: "UserCreated")
///
/// // Later, on the read path:
/// if let protection = registry.fieldProtection(for: "UserCreated") {
///     // protection["email"] == .pii
/// }
/// ```
public struct CryptoShreddableRegistry: Sendable {
    private var protections: [String: [String: FieldProtection]] = [:]

    public init() {}

    /// Registers field protection metadata for a ``CryptoShreddable`` event type.
    ///
    /// The `eventType` parameter is the string that appears in the `eventType` column
    /// of stored events. This is needed because `eventType` is an instance property
    /// on ``Event`` -- it cannot be obtained from the metatype alone.
    ///
    /// - Parameters:
    ///   - type: The event type conforming to both ``Event`` and ``CryptoShreddable``.
    ///   - eventType: The event type string used in the event store.
    public mutating func register<E: Event & CryptoShreddable>(
        _ type: E.Type,
        eventType: String
    ) {
        protections[eventType] = E.fieldProtection
    }

    /// Returns the field protection dictionary for the given event type string,
    /// or `nil` if the event type was not registered.
    public func fieldProtection(for eventType: String) -> [String: FieldProtection]? {
        protections[eventType]
    }
}
