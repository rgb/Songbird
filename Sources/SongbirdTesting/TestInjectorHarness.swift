import Foundation
import Songbird

/// A harness for testing injectors in isolation, without `SongbirdServices` or external infrastructure.
///
/// Runs the injector's event sequence against an `InMemoryEventStore` via `InjectorRunner`
/// and returns all successfully appended events.
///
/// ```swift
/// let injector = MyPollingInjector(testData: items)
/// let harness = TestInjectorHarness(injector: injector)
/// let events = try await harness.run()
/// #expect(events.count == 3)
/// ```
public struct TestInjectorHarness<I: Injector> {
    /// The wrapped injector instance.
    public let injector: I

    /// The in-memory event store used for appending.
    public let store: InMemoryEventStore

    public init(injector: I, store: InMemoryEventStore = InMemoryEventStore()) {
        self.injector = injector
        self.store = store
    }

    /// Runs the injector until its event sequence finishes, then returns all appended events.
    ///
    /// The injector's sequence must be finite (complete) for this method to return.
    public func run() async throws -> [RecordedEvent] {
        let runner = InjectorRunner(injector: injector, store: store)
        try await runner.run()
        return try await store.readAll(from: 0, maxCount: Int.max)
    }
}
