import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Simple test event for subscription tests
enum SubscriptionTestEvent: Event {
    case occurred(value: Int)

    var eventType: String {
        switch self {
        case .occurred: "Occurred"
        }
    }
}

/// Actor to safely collect events across task boundaries in tests.
actor EventCollector {
    private(set) var events: [RecordedEvent] = []

    func append(_ event: RecordedEvent) {
        events.append(event)
    }

    var count: Int { events.count }
}

@Suite("EventSubscription")
struct EventSubscriptionTests {

    let category = "order"

    func makeStores() -> (InMemoryEventStore, InMemoryPositionStore) {
        let registry = EventTypeRegistry()
        registry.register(SubscriptionTestEvent.self, eventTypes: ["Occurred"])
        return (InMemoryEventStore(), InMemoryPositionStore())
    }

    func appendEvents(
        to store: InMemoryEventStore,
        category: String,
        count: Int,
        startId: Int = 1
    ) async throws {
        for i in startId..<(startId + count) {
            let stream = StreamName(category: category, id: "\(i)")
            _ = try await store.append(
                SubscriptionTestEvent.occurred(value: i),
                to: stream,
                metadata: EventMetadata(),
                expectedVersion: nil
            )
        }
    }

    // MARK: - Basic Consumption

    @Test func subscribesToCategoryEvents() async throws {
        let (eventStore, positionStore) = makeStores()
        try await appendEvents(to: eventStore, category: category, count: 3)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 3)
        #expect(received[0].globalPosition == 0)
        #expect(received[1].globalPosition == 1)
        #expect(received[2].globalPosition == 2)
    }

    @Test func skipsOtherCategories() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append to "order" category
        let orderStream = StreamName(category: "order", id: "1")
        _ = try await eventStore.append(
            SubscriptionTestEvent.occurred(value: 1),
            to: orderStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Append to "invoice" category
        let invoiceStream = StreamName(category: "invoice", id: "1")
        _ = try await eventStore.append(
            SubscriptionTestEvent.occurred(value: 2),
            to: invoiceStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Append another to "order" category
        let orderStream2 = StreamName(category: "order", id: "2")
        _ = try await eventStore.append(
            SubscriptionTestEvent.occurred(value: 3),
            to: orderStream2,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: ["order"],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        #expect(received[0].streamName.category == "order")
        #expect(received[1].streamName.category == "order")
    }

    // MARK: - Position Persistence

    @Test func resumesFromPersistedPosition() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append 5 events (global positions 0..4)
        try await appendEvents(to: eventStore, category: category, count: 5)

        // Pre-set position to 2 (already processed through global position 2)
        try await positionStore.save(subscriberId: "test-sub", globalPosition: 2)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        // Should start from position 3 (after persisted position 2)
        #expect(received[0].globalPosition == 3)
        #expect(received[1].globalPosition == 4)
    }

    @Test func savesPositionAfterBatch() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append 5 events with batch size 3
        try await appendEvents(to: eventStore, category: category, count: 5)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 3,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Consume all 5 events (first batch of 3, then batch of 2)
                if await collector.count == 5 { break }
            }
        }

        try await task.value

        // Position should be saved after batches are exhausted.
        // After consuming all events and breaking, the last fully-consumed batch
        // had its position saved. The position saved is the last event of the
        // most recently exhausted batch.
        let savedPosition = try await positionStore.load(subscriberId: "test-sub")
        #expect(savedPosition != nil)
        // After first batch (0,1,2) is exhausted, position 2 is saved.
        // Then second batch (3,4) starts yielding. We break after event 4.
        // The second batch was exhausted at index 2 (batchIndex == currentBatch.count)
        // which triggers position save for the first batch only if we re-enter next().
        // Actually: after yielding all 3 from first batch, next() saves position 2,
        // then fetches second batch (3,4), yields 3, then 4. After 4, we break.
        // Position 2 was saved when first batch was exhausted. Position 4 is NOT saved
        // yet because we broke before exhausting the iterator's internal state.
        // The saved position should be 2 (from the first batch completion).
        #expect(savedPosition == 2)
    }

    // MARK: - Cancellation

    @Test func stopsOnTaskCancellation() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append a few events so the subscription has something to start with
        try await appendEvents(to: eventStore, category: category, count: 2)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Don't break -- let it poll forever
            }
        }

        // Let the subscription process existing events
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task
        task.cancel()

        // The task should finish without hanging.
        // Cancellation may cause CancellationError from Task.sleep, which is expected.
        let result = await task.result
        switch result {
        case .success:
            break  // clean exit via nil return
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count == 2)
    }

    @Test func cancelsCleanlyDuringActivePolling() async throws {
        let (eventStore, positionStore) = makeStores()

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Don't break -- let it poll forever
            }
        }

        // Let the subscription start polling on an empty store
        try await Task.sleep(for: .milliseconds(30))

        // Append an event while the subscription is actively polling
        try await appendEvents(to: eventStore, category: category, count: 1)

        // Wait for the subscription to pick up the new event
        try await Task.sleep(for: .milliseconds(50))
        let count = await collector.count
        #expect(count == 1)

        // Cancel the task while the subscription is polling for more events
        task.cancel()

        // The task should finish promptly. Race against a generous timeout
        // to detect if cancellation hangs.
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await task.result
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        #expect(completed, "EventSubscription did not terminate promptly after cancellation")

        // Verify the task result is either success or CancellationError
        let result = await task.result
        switch result {
        case .success:
            break  // clean exit via nil return
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    // MARK: - Polling

    @Test func pollsForNewEvents() async throws {
        let (eventStore, positionStore) = makeStores()

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        // Give the subscription time to start polling on an empty store
        try await Task.sleep(for: .milliseconds(30))
        let earlyCount = await collector.count
        #expect(earlyCount == 0)

        // Now append events -- the subscription should pick them up
        try await appendEvents(to: eventStore, category: category, count: 3)

        try await task.value
        let finalCount = await collector.count
        #expect(finalCount == 3)
    }

    @Test func handlesEmptyStore() async throws {
        let (eventStore, positionStore) = makeStores()

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let task = Task {
            for try await _ in subscription {
                // Should never get here
            }
        }

        // Let it poll a few times on the empty store
        try await Task.sleep(for: .milliseconds(50))

        // Cancel -- should not crash
        task.cancel()

        // Await completion. Cancellation may cause CancellationError, which is expected.
        let result = await task.result
        switch result {
        case .success:
            break  // clean exit via nil return
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    // MARK: - Multi-Category Subscription

    @Test func subscribesToMultipleCategories() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append events to different categories
        let orderStream = StreamName(category: "order", id: "1")
        let invoiceStream = StreamName(category: "invoice", id: "1")
        let shipmentStream = StreamName(category: "shipment", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 1), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 2), to: invoiceStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 3), to: shipmentStream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: ["order", "invoice"],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        // Should get order and invoice, but not shipment
        let categories = Set(received.map(\.streamName.category))
        #expect(categories == ["order", "invoice"])
    }

    @Test func cancellationFlushesLastDeliveredPosition() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append 5 events (global positions 0..4)
        try await appendEvents(to: eventStore, category: category, count: 5)

        let subscription = EventSubscription(
            subscriberId: "flush-test",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Don't break -- let it poll after consuming all events
            }
        }

        // Wait for all 5 events to be consumed, then the subscription enters the poll loop
        while await collector.count < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Cancel while the subscription is polling for more events.
        // The batch-exhaustion path and/or cancellation flush should persist the position.
        task.cancel()

        // Wait for the task to finish
        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }

        // Verify position was flushed
        let savedPosition = try await positionStore.load(subscriberId: "flush-test")
        #expect(savedPosition != nil, "Position should be saved on cancellation")
        #expect(savedPosition == 4, "Position should reflect the last delivered event")
    }

    // MARK: - All-Events Subscription

    @Test func subscribesToAllEventsWithEmptyCategories() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append events to different categories
        let orderStream = StreamName(category: "order", id: "1")
        let invoiceStream = StreamName(category: "invoice", id: "1")
        let shipmentStream = StreamName(category: "shipment", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 1), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 2), to: invoiceStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 3), to: shipmentStream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 3)
        let categories = Set(received.map(\.streamName.category))
        #expect(categories == ["order", "invoice", "shipment"])
    }
}
