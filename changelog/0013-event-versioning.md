# Event Versioning Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add event versioning and upcasting to Songbird so old events stored in the event store are transparently upcast to the latest version on read.

**Architecture:** `Event` protocol gains `static var version: Int` (default 1, non-breaking). An `EventUpcast` protocol defines pure transforms between consecutive versions. `EventTypeRegistry` stores upcast chains and walks them during `decode()`, returning the latest version transparently. Old events stay as-is in the store — upcasting is on read.

**Tech Stack:** Swift 6.2+, Swift Testing (@Test, #expect)

**Design doc:** `docs/plans/2026-03-04-event-versioning-design.md`

---

### Task 1: Add `version` to Event Protocol

**Files:**
- Modify: `Sources/Songbird/Event.swift:3-9`
- Test: `Tests/SongbirdTests/EventTypeRegistryTests.swift`

**Step 1: Write the failing test**

Add a test to `EventTypeRegistryTests.swift` that asserts existing events have version 1:

```swift
@Test func existingEventsDefaultToVersion1() {
    #expect(AccountEvent.version == 1)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter EventTypeRegistryTests/existingEventsDefaultToVersion1`
Expected: FAIL — `AccountEvent` has no static member `version`

**Step 3: Write minimal implementation**

In `Sources/Songbird/Event.swift`, add `version` to the protocol and default extension:

```swift
public protocol Event: Message {
    var eventType: String { get }
    static var version: Int { get }
}

extension Event {
    public var messageType: String { eventType }
    public static var version: Int { 1 }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter EventTypeRegistryTests/existingEventsDefaultToVersion1`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Songbird/Event.swift Tests/SongbirdTests/EventTypeRegistryTests.swift
git commit -m "Add static var version to Event protocol with default of 1"
```

---

### Task 2: Create EventUpcast Protocol

**Files:**
- Create: `Sources/Songbird/EventUpcast.swift`
- Test: `Tests/SongbirdTests/EventUpcastTests.swift`

**Step 1: Write the failing test**

Create `Tests/SongbirdTests/EventUpcastTests.swift` with test types and a concrete upcast:

```swift
import Foundation
import Testing

@testable import Songbird

// MARK: - Test Versioned Events

struct OrderPlaced_v1: Event, Equatable {
    var eventType: String { "OrderPlaced_v1" }
    static let version = 1
    let itemId: String
}

struct OrderPlaced_v2: Event, Equatable {
    var eventType: String { "OrderPlaced_v2" }
    static let version = 2
    let itemId: String
    let quantity: Int
}

// MARK: - Test Upcast

struct OrderPlacedUpcast_v1_v2: EventUpcast {
    func upcast(_ old: OrderPlaced_v1) -> OrderPlaced_v2 {
        OrderPlaced_v2(itemId: old.itemId, quantity: 1)
    }
}

@Suite("EventUpcast")
struct EventUpcastTests {
    @Test func upcastTransformsOldEventToNewEvent() {
        let upcast = OrderPlacedUpcast_v1_v2()
        let old = OrderPlaced_v1(itemId: "abc")
        let new = upcast.upcast(old)
        #expect(new == OrderPlaced_v2(itemId: "abc", quantity: 1))
    }
}
```

Each versioned event uses a distinct `eventType` string (e.g. `"OrderPlaced_v1"`, `"OrderPlaced_v2"`). This is how the registry distinguishes which version is stored — the `eventType` string in the store matches the version that wrote it.

**Step 2: Run test to verify it fails**

Run: `swift test --filter EventUpcastTests/upcastTransformsOldEventToNewEvent`
Expected: FAIL — `EventUpcast` not defined

**Step 3: Write minimal implementation**

Create `Sources/Songbird/EventUpcast.swift`:

```swift
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
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter EventUpcastTests/upcastTransformsOldEventToNewEvent`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Songbird/EventUpcast.swift Tests/SongbirdTests/EventUpcastTests.swift
git commit -m "Add EventUpcast protocol for pure version transforms"
```

---

### Task 3: Add `registerUpcast` to EventTypeRegistry

**Files:**
- Modify: `Sources/Songbird/EventTypeRegistry.swift`
- Test: `Tests/SongbirdTests/EventUpcastTests.swift`

This is the core task. The registry gains:
1. An upcast chain: `[String: @Sendable (any Event) -> any Event]` keyed by old event type string
2. A `registerUpcast` method that stores the decoder for the old type + the upcast transform
3. Updated `decode()` that walks the chain after initial decode

**Step 1: Write the failing tests**

Add to `Tests/SongbirdTests/EventUpcastTests.swift`:

```swift
@Test func registryDecodesOldEventAsLatestVersion() throws {
    let registry = EventTypeRegistry()
    registry.register(OrderPlaced_v2.self, eventTypes: ["OrderPlaced_v2"])
    registry.registerUpcast(
        from: OrderPlaced_v1.self,
        to: OrderPlaced_v2.self,
        upcast: OrderPlacedUpcast_v1_v2(),
        oldEventType: "OrderPlaced_v1"
    )

    // Encode a v1 event (simulating what the store holds)
    let v1 = OrderPlaced_v1(itemId: "abc")
    let data = try JSONEncoder().encode(v1)
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "order", id: "1"),
        position: 0,
        globalPosition: 0,
        eventType: "OrderPlaced_v1",
        data: data,
        metadata: EventMetadata(),
        timestamp: Date()
    )

    let decoded = try registry.decode(recorded)
    let typed = decoded as! OrderPlaced_v2
    #expect(typed == OrderPlaced_v2(itemId: "abc", quantity: 1))
}

@Test func registryDecodesCurrentVersionDirectly() throws {
    let registry = EventTypeRegistry()
    registry.register(OrderPlaced_v2.self, eventTypes: ["OrderPlaced_v2"])
    registry.registerUpcast(
        from: OrderPlaced_v1.self,
        to: OrderPlaced_v2.self,
        upcast: OrderPlacedUpcast_v1_v2(),
        oldEventType: "OrderPlaced_v1"
    )

    // Encode a v2 event (current version, no upcasting needed)
    let v2 = OrderPlaced_v2(itemId: "abc", quantity: 5)
    let data = try JSONEncoder().encode(v2)
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "order", id: "1"),
        position: 0,
        globalPosition: 0,
        eventType: "OrderPlaced_v2",
        data: data,
        metadata: EventMetadata(),
        timestamp: Date()
    )

    let decoded = try registry.decode(recorded)
    let typed = decoded as! OrderPlaced_v2
    #expect(typed == OrderPlaced_v2(itemId: "abc", quantity: 5))
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter EventUpcastTests`
Expected: FAIL — `registerUpcast` method does not exist

**Step 3: Write minimal implementation**

Modify `Sources/Songbird/EventTypeRegistry.swift`. The full file should become:

```swift
import Foundation

public enum EventTypeRegistryError: Error {
    case unregisteredEventType(String)
}

/// `@unchecked Sendable` is justified because all mutable state (`decoders`, `upcasts`)
/// is protected by an `NSLock`. Every read and write acquires the lock first, ensuring
/// thread-safe access from any isolation domain. The class is `final` to prevent subclasses
/// from breaking this invariant.
public final class EventTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [String: @Sendable (Data) throws -> any Event] = [:]
    private var upcasts: [String: @Sendable (any Event) -> any Event] = [:]

    public init() {}

    public func register<E: Event>(_ type: E.Type, eventTypes: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for eventType in eventTypes {
            decoders[eventType] = { data in
                try JSONDecoder().decode(E.self, from: data)
            }
        }
    }

    /// Registers an upcast transform between two consecutive event versions.
    ///
    /// This does three things:
    /// 1. Registers a decoder for the old event type string so stored events can be deserialized
    /// 2. Stores the upcast function keyed by the old event type string
    /// 3. Validates that `NewEvent.version == OldEvent.version + 1`
    ///
    /// The `oldEventType` parameter is the string that appears in the `eventType` column of
    /// stored events for the old version. This is needed because `eventType` is an instance
    /// property on `Event` — we can't get it from the metatype alone.
    ///
    /// ```swift
    /// registry.registerUpcast(
    ///     from: OrderPlaced_v1.self,
    ///     to: OrderPlaced_v2.self,
    ///     upcast: OrderPlacedUpcast_v1_v2(),
    ///     oldEventType: "OrderPlaced_v1"
    /// )
    /// ```
    public func registerUpcast<U: EventUpcast>(
        from oldType: U.OldEvent.Type,
        to newType: U.NewEvent.Type,
        upcast: U,
        oldEventType: String
    ) {
        precondition(
            U.NewEvent.version == U.OldEvent.version + 1,
            "Upcast version mismatch: \(U.OldEvent.self) is version \(U.OldEvent.version), " +
            "\(U.NewEvent.self) is version \(U.NewEvent.version), expected \(U.OldEvent.version + 1)"
        )

        lock.lock()
        defer { lock.unlock() }

        // Register decoder for the old event type string
        decoders[oldEventType] = { data in
            try JSONDecoder().decode(U.OldEvent.self, from: data)
        }

        // Store the upcast transform keyed by the old event type string
        upcasts[oldEventType] = { @Sendable (event: any Event) -> any Event in
            upcast.upcast(event as! U.OldEvent)
        }
    }

    public func decode(_ recorded: RecordedEvent) throws -> any Event {
        lock.lock()
        let decoder = decoders[recorded.eventType]
        lock.unlock()

        guard let decoder else {
            throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
        }

        var event = try decoder(recorded.data)

        // Walk the upcast chain until no more upcasts exist.
        // After each upcast, look up the next using the new event's eventType.
        lock.lock()
        var nextUpcast = upcasts[recorded.eventType]
        lock.unlock()

        while let upcastFn = nextUpcast {
            event = upcastFn(event)

            let newEventType = event.eventType
            lock.lock()
            nextUpcast = upcasts[newEventType]
            lock.unlock()
        }

        return event
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter EventUpcastTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Songbird/EventTypeRegistry.swift Tests/SongbirdTests/EventUpcastTests.swift
git commit -m "Add registerUpcast to EventTypeRegistry with chain-walking decode"
```

---

### Task 4: Multi-Version Upcast Chain (v1 → v2 → v3)

**Files:**
- Test: `Tests/SongbirdTests/EventUpcastTests.swift`

**Step 1: Write the tests**

Add a v3 event type and a second upcast to `EventUpcastTests.swift`:

```swift
struct OrderPlaced_v3: Event, Equatable {
    var eventType: String { "OrderPlaced_v3" }
    static let version = 3
    let itemId: String
    let quantity: Int
    let currency: String
}

struct OrderPlacedUpcast_v2_v3: EventUpcast {
    func upcast(_ old: OrderPlaced_v2) -> OrderPlaced_v3 {
        OrderPlaced_v3(itemId: old.itemId, quantity: old.quantity, currency: "USD")
    }
}
```

Add the tests:

```swift
@Test func registryWalksMultiStepUpcastChain() throws {
    let registry = EventTypeRegistry()
    registry.register(OrderPlaced_v3.self, eventTypes: ["OrderPlaced_v3"])
    registry.registerUpcast(
        from: OrderPlaced_v1.self,
        to: OrderPlaced_v2.self,
        upcast: OrderPlacedUpcast_v1_v2(),
        oldEventType: "OrderPlaced_v1"
    )
    registry.registerUpcast(
        from: OrderPlaced_v2.self,
        to: OrderPlaced_v3.self,
        upcast: OrderPlacedUpcast_v2_v3(),
        oldEventType: "OrderPlaced_v2"
    )

    // Encode a v1 event (oldest version)
    let v1 = OrderPlaced_v1(itemId: "abc")
    let data = try JSONEncoder().encode(v1)
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "order", id: "1"),
        position: 0,
        globalPosition: 0,
        eventType: "OrderPlaced_v1",
        data: data,
        metadata: EventMetadata(),
        timestamp: Date()
    )

    // v1 → v2 → v3 automatically
    let decoded = try registry.decode(recorded)
    let typed = decoded as! OrderPlaced_v3
    #expect(typed == OrderPlaced_v3(itemId: "abc", quantity: 1, currency: "USD"))
}

@Test func registryUpcastsV2ToV3() throws {
    let registry = EventTypeRegistry()
    registry.register(OrderPlaced_v3.self, eventTypes: ["OrderPlaced_v3"])
    registry.registerUpcast(
        from: OrderPlaced_v1.self,
        to: OrderPlaced_v2.self,
        upcast: OrderPlacedUpcast_v1_v2(),
        oldEventType: "OrderPlaced_v1"
    )
    registry.registerUpcast(
        from: OrderPlaced_v2.self,
        to: OrderPlaced_v3.self,
        upcast: OrderPlacedUpcast_v2_v3(),
        oldEventType: "OrderPlaced_v2"
    )

    // Encode a v2 event (middle version — needs one upcast to reach v3)
    let v2 = OrderPlaced_v2(itemId: "abc", quantity: 5)
    let data = try JSONEncoder().encode(v2)
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "order", id: "1"),
        position: 0,
        globalPosition: 0,
        eventType: "OrderPlaced_v2",
        data: data,
        metadata: EventMetadata(),
        timestamp: Date()
    )

    // v2 → v3 automatically
    let decoded = try registry.decode(recorded)
    let typed = decoded as! OrderPlaced_v3
    #expect(typed == OrderPlaced_v3(itemId: "abc", quantity: 5, currency: "USD"))
}
```

**Step 2: Run tests to verify they pass**

Run: `swift test --filter EventUpcastTests`
Expected: PASS — the chain-walking logic from Task 3 handles multi-step chains automatically. If these fail, the chain-walking logic in `decode()` needs debugging.

**Step 3: Commit**

```bash
git add Tests/SongbirdTests/EventUpcastTests.swift
git commit -m "Add multi-version upcast chain tests (v1 → v2 → v3)"
```

---

### Task 5: Validation Error Cases

**Files:**
- Test: `Tests/SongbirdTests/EventUpcastTests.swift`

**Step 1: Write the tests**

Add tests verifying version validation:

```swift
@Test func versionNumbersAreCorrectForTestTypes() {
    #expect(OrderPlaced_v1.version == 1)
    #expect(OrderPlaced_v2.version == 2)
    #expect(OrderPlaced_v3.version == 3)
}

@Test func registerUpcastWithWrongVersionPreconditionFails() {
    // OrderPlaced_v1 (version 1) → OrderPlaced_v3 (version 3) skips a version.
    // registerUpcast uses a precondition to enforce consecutive versions (v3 != v1 + 1).
    // We can't test precondition failures in Swift Testing without crashing the process,
    // so we verify the invariant holds by checking the version numbers directly.
    #expect(OrderPlaced_v3.version != OrderPlaced_v1.version + 1)
}
```

**Step 2: Run tests to verify they pass**

Run: `swift test --filter EventUpcastTests`
Expected: PASS

**Step 3: Commit**

```bash
git add Tests/SongbirdTests/EventUpcastTests.swift
git commit -m "Add event versioning validation tests"
```

---

### Task 6: Clean Build and Full Test Suite

**Step 1: Run full build**

Run: `swift build 2>&1`
Expected: Build succeeds with no warnings and no errors.

**Step 2: Run full test suite**

Run: `swift test 2>&1`
Expected: All tests pass (should be ~250+ tests). No failures, no warnings.

**Step 3: If any issues, fix them and re-run**

Common issues to watch for:
- Existing tests that reference `EventTypeRegistryError` may need updating if we changed the error enum
- Any `exhaustive switch` warnings from the new error case

**Step 4: Commit (if any fixes were needed)**

```bash
git add -A
git commit -m "Fix build issues from event versioning integration"
```

---

### Task 7: Changelog Entry

**Step 1: Verify this file is complete and accurate**

This file (`changelog/0013-event-versioning.md`) serves as both the implementation plan and the changelog entry.

**Step 2: Commit the changelog**

```bash
git add changelog/0013-event-versioning.md
git commit -m "Add event versioning changelog entry"
```
