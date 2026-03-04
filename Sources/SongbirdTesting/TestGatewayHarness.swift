import Foundation
import Songbird

/// A value-type harness for testing gateways in isolation, without a subscription or runner.
///
/// Feeds events to the gateway's `handle` method and records successes and failures.
/// Does not throw from `given()` — errors are captured for later assertion.
///
/// ```swift
/// let gateway = WebhookNotifier()
/// var harness = TestGatewayHarness(gateway: gateway)
/// await harness.given(try RecordedEvent(event: OrderPlaced()))
/// #expect(harness.processedEvents.count == 1)
/// #expect(harness.errors.isEmpty)
/// ```
public struct TestGatewayHarness<G: Gateway> {
    /// The wrapped gateway instance.
    public let gateway: G

    /// Events that were successfully handled.
    public private(set) var processedEvents: [RecordedEvent] = []

    /// Events that caused an error, paired with the error.
    public private(set) var errors: [(RecordedEvent, any Error)] = []

    public init(gateway: G) {
        self.gateway = gateway
    }

    /// Feeds an event to the gateway's `handle` method.
    /// Records success or failure without throwing.
    public mutating func given(_ event: RecordedEvent) async {
        do {
            try await gateway.handle(event)
            processedEvents.append(event)
        } catch {
            errors.append((event, error))
        }
    }
}
