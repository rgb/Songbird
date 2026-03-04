/// A boundary component for outbound side effects (email, webhooks, API calls).
///
/// Gateways subscribe to event categories via `EventSubscription` and receive events
/// through `handle(_:)`. They must be idempotent — events may be delivered more than once
/// (at-least-once delivery). Core components (aggregates, projectors, process managers)
/// must never perform side effects directly; all external interaction goes through gateways.
///
/// Usage:
/// ```swift
/// actor WebhookNotifier: Gateway {
///     let gatewayId = "webhook-notifier"
///     static let categories = ["order", "payment"]
///
///     func handle(_ event: RecordedEvent) async throws {
///         // Send webhook, call external API, etc.
///     }
/// }
/// ```
public protocol Gateway: Sendable {
    var gatewayId: String { get }
    static var categories: [String] { get }
    func handle(_ event: RecordedEvent) async throws
}
