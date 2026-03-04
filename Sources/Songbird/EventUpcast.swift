/// A pure transform between two consecutive event versions.
///
/// Each upcast handles exactly one version step (e.g. v1 → v2). Upcasts are
/// registered in the `EventTypeRegistry` and chained automatically so that
/// reading a v1 event from the store returns the latest version transparently.
///
/// ```swift
/// struct OrderPlacedUpcast_v1_v2: EventUpcast {
///     func upcast(_ old: OrderPlaced_v1) -> OrderPlaced_v2 {
///         OrderPlaced_v2(itemId: old.itemId, quantity: 1)
///     }
/// }
/// ```
public protocol EventUpcast<OldEvent, NewEvent>: Sendable {
    associatedtype OldEvent: Event
    associatedtype NewEvent: Event
    func upcast(_ old: OldEvent) -> NewEvent
}
