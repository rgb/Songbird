import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres
@testable import SongbirdTesting

extension AllPostgresTests { @Suite("PostgresEventSubscription") struct EventSubscriptionTests {

    let stream = StreamName(category: "order", id: "abc")

    func makeRegistry() -> EventTypeRegistry {
        let registry = EventTypeRegistry()
        registry.register(PGSubEvent.self, eventTypes: ["OrderPlaced", "InvoiceSent"])
        return registry
    }

    // MARK: - Catch Up

    @Test func catchesUpOnExistingEvents() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let registry = makeRegistry()
            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)
            let connectionConfig = try await PostgresTestHelper.connectionConfig()

            // Append 3 events before creating the subscription
            _ = try await store.append(PGSubEvent.orderPlaced(item: "A"), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGSubEvent.orderPlaced(item: "B"), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGSubEvent.orderPlaced(item: "C"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let subscription = PostgresEventSubscription(
                store: store,
                connectionConfig: connectionConfig,
                subscriberId: "catchup-test",
                categories: ["order"],
                positionStore: positionStore,
                fallbackPollInterval: .seconds(1)
            )

            let events = try await collectEvents(from: subscription, count: 3, timeout: .seconds(10))
            #expect(events.count == 3)
            #expect(events[0].globalPosition == 0)
            #expect(events[1].globalPosition == 1)
            #expect(events[2].globalPosition == 2)
            #expect(events[0].eventType == "OrderPlaced")
        }
    }

    // MARK: - LISTEN/NOTIFY Wakeup

    @Test func receivesEventsViaListenNotification() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let registry = makeRegistry()
            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)
            let connectionConfig = try await PostgresTestHelper.connectionConfig()

            let subscription = PostgresEventSubscription(
                store: store,
                connectionConfig: connectionConfig,
                subscriberId: "listen-test",
                categories: ["order"],
                positionStore: positionStore,
                fallbackPollInterval: .seconds(30)  // Long fallback so we know LISTEN woke us up
            )

            // Append an event after a brief delay to give the subscription time to start listening
            let appendTask = Task {
                try await Task.sleep(for: .milliseconds(500))
                _ = try await store.append(
                    PGSubEvent.orderPlaced(item: "delayed"),
                    to: stream,
                    metadata: EventMetadata(),
                    expectedVersion: nil
                )
            }

            let events = try await collectEvents(from: subscription, count: 1, timeout: .seconds(10))
            _ = try await appendTask.value
            #expect(events.count == 1)
            #expect(events[0].eventType == "OrderPlaced")
        }
    }

    // MARK: - Position Persistence

    @Test func persistsPositionAcrossRestarts() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let registry = makeRegistry()
            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)
            let connectionConfig = try await PostgresTestHelper.connectionConfig()

            // Append 3 events
            _ = try await store.append(PGSubEvent.orderPlaced(item: "A"), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGSubEvent.orderPlaced(item: "B"), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGSubEvent.orderPlaced(item: "C"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            // Subscription A: consume first 2 events
            let subscriptionA = PostgresEventSubscription(
                store: store,
                connectionConfig: connectionConfig,
                subscriberId: "persist-test",
                categories: ["order"],
                positionStore: positionStore,
                fallbackPollInterval: .seconds(1)
            )

            let firstBatch = try await collectEvents(from: subscriptionA, count: 2, timeout: .seconds(10))
            #expect(firstBatch.count == 2)
            #expect(firstBatch[0].globalPosition == 0)
            #expect(firstBatch[1].globalPosition == 1)

            // Force position save by consuming the second event (batch save happens when
            // the batch is exhausted on the next `next()` call). We need to trigger a
            // third next() to save position after consuming event at index 1.
            // The collectEvents helper breaks after count, so the batch save for events
            // 0 and 1 may not have occurred yet. Save explicitly for deterministic behavior.
            try await positionStore.save(subscriberId: "persist-test", globalPosition: 1)

            // Subscription B: same subscriberId, should start from event 3 (globalPosition 2)
            let subscriptionB = PostgresEventSubscription(
                store: store,
                connectionConfig: connectionConfig,
                subscriberId: "persist-test",
                categories: ["order"],
                positionStore: positionStore,
                fallbackPollInterval: .seconds(1)
            )

            let secondBatch = try await collectEvents(from: subscriptionB, count: 1, timeout: .seconds(10))
            #expect(secondBatch.count == 1)
            #expect(secondBatch[0].globalPosition == 2)
        }
    }

    // MARK: - Category Filtering

    @Test func filtersByCategory() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let registry = makeRegistry()
            let store = PostgresEventStore(client: client, registry: registry)
            let positionStore = PostgresPositionStore(client: client)
            let connectionConfig = try await PostgresTestHelper.connectionConfig()

            let orderStream = StreamName(category: "order", id: "o1")
            let invoiceStream = StreamName(category: "invoice", id: "i1")

            // Append events to different categories
            _ = try await store.append(PGSubEvent.orderPlaced(item: "widget"), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGSubEvent.invoiceSent(total: 100), to: invoiceStream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGSubEvent.orderPlaced(item: "gadget"), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)

            // Subscribe to "order" only
            let subscription = PostgresEventSubscription(
                store: store,
                connectionConfig: connectionConfig,
                subscriberId: "filter-test",
                categories: ["order"],
                positionStore: positionStore,
                fallbackPollInterval: .seconds(1)
            )

            let events = try await collectEvents(from: subscription, count: 2, timeout: .seconds(10))
            #expect(events.count == 2)
            #expect(events.allSatisfy { $0.streamName.category == "order" })
            #expect(events[0].eventType == "OrderPlaced")
            #expect(events[1].eventType == "OrderPlaced")
        }
    }

    // MARK: - Helpers

    /// Collects the first `count` events from a subscription, with a timeout to prevent hangs.
    private func collectEvents(
        from subscription: PostgresEventSubscription,
        count: Int,
        timeout: Duration
    ) async throws -> [RecordedEvent] {
        try await withThrowingTaskGroup(of: [RecordedEvent].self) { group in
            group.addTask {
                var collected: [RecordedEvent] = []
                for try await event in subscription {
                    collected.append(event)
                    if collected.count >= count { break }
                }
                return collected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                return []
            }
            group.cancelAll()
            return result
        }
    }
}}

// MARK: - Test Event Type

enum PGSubEvent: Event, Equatable {
    case orderPlaced(item: String)
    case invoiceSent(total: Int)

    var eventType: String {
        switch self {
        case .orderPlaced: "OrderPlaced"
        case .invoiceSent: "InvoiceSent"
        }
    }
}
