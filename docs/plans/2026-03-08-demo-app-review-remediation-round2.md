# Demo App Review Remediation (Round 2) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all 5 critical, 14 important, and 10 suggestion issues from the comprehensive demo app review focusing on Swift 6.2 structured concurrency and Songbird framework correctness.

**Architecture:** Changes span three areas: (1) PostgresClient lifecycle restructuring across all PG demos, (2) domain source fixes for concurrency and framework patterns, (3) test quality improvements. Each task is grouped by logical dependency — PG lifecycle first (affects most files), then domain sources, then tests.

**Tech Stack:** Swift 6.2, PostgresNIO, Hummingbird 2, SongbirdDistributed, DuckDB/Smew, Swift Testing

---

## Issue Cross-Reference

| ID | Sev | Task | Description |
|----|-----|------|-------------|
| C1 | Critical | 1 | PostgresClient double-run / post-cancel in warbler-pg |
| C2 | Critical | 2 | Distributed gateway system.shutdown() ordering |
| C3 | Critical | 2 | `try? await system.shutdown()` swallows transport errors |
| C4 | Critical | 6 | `hasRecordedAtTimestamp` test uses scalarInt64() on TIMESTAMP |
| C5 | Critical | 6 | `updateMetadata` test missing status assertion |
| I1 | Important | 3 | PlaybackInjector.inject() unnecessarily actor-isolated |
| I2 | Important | 3 | Event enums lack explicit Equatable conformance |
| I3 | Important | 3 | Process manager reaction enums are internal |
| I4 | Important | 3 | VideoCatalogProjector v1/v2 handling needs comment |
| I5 | Important | 1 | warbler-p2p-pg hangs on shutdown (client.run never exits) |
| I6 | Important | 2 | Distributed gateway missing RequestIdMiddleware |
| I7 | Important | 2 | `_ = handler` fragile distributed actor lifetime |
| I8 | Important | 4 | warbler-p2p-proxy uses HTTPClient.shared |
| I9 | Important | 6 | UnpublishVideo from .transcoding untested |
| I10 | Important | 6 | paymentConfirmed/paymentFailed ignored by SubscriptionProjector untested |
| I11 | Important | 6 | Out-of-order process manager events untested |
| I12 | Important | 6 | Snapshot policy test is a tautology |
| I13 | Important | 6 | TestInjectorHarness not used for PlaybackInjector |
| I14 | Important | 6 | Lifecycle events with no stream ID not tested in SubscriptionProjector |
| S1 | Suggestion | 5 | ViewCountAggregate/ViewCountEvent are dead code |
| S2 | Suggestion | 3 | commandType should be `let` not computed `var` |
| S3 | Suggestion | 3 | SubscriptionProjector cross-category subscription concern |
| S4 | Suggestion | 3 | EmailNotificationGateway.sentNotifications grows without bound |
| S5 | Suggestion | 3 | VideoCatalogProjector hard-codes status strings |
| S6 | Suggestion | 4 | Inconsistent logging (print vs Logger) |
| S7 | Suggestion | 4 | jsonResponse helper duplicated |
| S8 | Suggestion | 4 | P2P SQLite services lack BIND_HOST env var |
| S9 | Suggestion | 6 | Process manager output casts should use #require |
| S10 | Suggestion | 6 | fullLifecycle test only checks final state |

---

## Task 1: Fix PostgresClient lifecycle in all PG demos (C1, I5)

**Why:** The monolith (`warbler-pg`) calls `client.run()` twice — once in a migration task group that cancels it, then again in the service task group. PostgresNIO documents a single `run()` call per client lifetime. The P2P PG services (`warbler-p2p-pg`) have `client.run()` in an outer group that never gets cancelled when inner services stop, causing the process to hang on shutdown.

**Files:**
- Modify: `demo/warbler-pg/Sources/Warbler/main.swift:42-49,345-350`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerIdentityService/main.swift:33-154`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerCatalogService/main.swift:33-185`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerSubscriptionsService/main.swift:33-137`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift:33-139`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerIdentityWorker/main.swift:110-175`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerCatalogWorker/main.swift:127-191`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker/main.swift:91-147`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift:96-152`

**The correct pattern:** A single task group with `client.run()` as a peer alongside all services. Migrations run sequentially at the start of the service task (before starting the HTTP server). When any service task exits, the task group cancels all peers — including `client.run()`, which exits cleanly on cancellation.

**Changes for `warbler-pg/Sources/Warbler/main.swift`:**

Replace the two-task-group pattern (lines 42-49 migration group + lines 345-350 service group) with a single flat group:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }
    group.addTask {
        // Run migrations first (client is already running in the peer task)
        try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

        // ... all existing setup code (registry, stores, projectors, routes, etc.) stays here ...

        // Run services
        try await withThrowingTaskGroup(of: Void.self) { serviceGroup in
            serviceGroup.addTask { try await services.run() }
            serviceGroup.addTask { try await app.runService() }
            try await serviceGroup.waitForAll()
        }
    }
    try await group.waitForAll()
}
```

The key change: remove the separate migration task group (lines 42-49) entirely. Move all the setup code that was between the two groups into the second task of the single group. The migration call goes at the very top of that task. The final service group becomes an inner group.

**Changes for `warbler-p2p-pg` (all 4 services):**

These already have the correct structure! `client.run()` is in the outer group task 1, and all setup + inner service group is in task 2. When the inner service group exits, task 2 returns, `waitForAll()` waits for task 1 (`client.run()`). The problem is that `client.run()` blocks forever — it doesn't exit when there's no more work.

The fix: cancel the outer group when services finish. After the inner service group completes, the outer group's `waitForAll()` will wait forever. Use `group.cancelAll()` or restructure:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }
    group.addTask {
        try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
        // ... setup ...
        try await withThrowingTaskGroup(of: Void.self) { serviceGroup in
            serviceGroup.addTask { try await services.run() }
            serviceGroup.addTask { try await app.runService() }
            try await serviceGroup.waitForAll()
        }
    }
    // When task 2 finishes (services stopped), cancel task 1 (client.run)
    try await group.next()
    group.cancelAll()
}
```

Apply this `next() + cancelAll()` pattern to all 4 p2p-pg services.

**Changes for `warbler-distributed-pg` (all 4 workers):**

These already have the correct outer structure with `client.run()` in task 1. But the inner code runs `services.run()` directly (not in a separate group) and handles `system.shutdown()` via try/catch. The shutdown fix is Task 2, but the client lifecycle needs the same `next() + cancelAll()` fix:

After the `system.shutdown()` calls (which remain), the task 2 function returns. Then the outer group needs to cancel `client.run()`:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }
    group.addTask {
        try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
        // ... setup ...
        do {
            try await services.run()
        } catch {
            try await system.shutdown()  // changed from try? — see Task 2
            throw error
        }
        try await system.shutdown()
    }
    try await group.next()
    group.cancelAll()
}
```

**Verify:** `cd demo/warbler-pg && swift build` and `cd demo/warbler-p2p-pg && swift build` and `cd demo/warbler-distributed-pg && swift build`

**Commit:** `Fix PostgresClient lifecycle: single run(), proper shutdown cancellation`

---

## Task 2: Fix distributed system shutdown and gateway patterns (C2, C3, I6, I7)

**Why:** (C2/C3) All distributed workers and gateways use `try? await system.shutdown()`, silently swallowing transport errors — stale socket files will block restarts. (I6) The distributed gateways don't propagate trace IDs through distributed calls. (I7) The `_ = handler` pattern for keeping distributed actors alive is fragile.

**Files:**
- Modify: `demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerCatalogWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerSubscriptionsWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerAnalyticsWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerIdentityWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerCatalogWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerGateway/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerGateway/main.swift`

**Changes:**

### C3: Replace `try?` with `try` for system.shutdown()

In all 8 worker files and both gateways, change:
```swift
try? await system.shutdown()
```
to:
```swift
try await system.shutdown()
```

In the error catch path, keep the error wrapping so both errors are visible:
```swift
do {
    try await services.run()
} catch {
    do {
        try await system.shutdown()
    } catch {
        print("Warning: system shutdown failed: \(error)")
    }
    throw error
}
try await system.shutdown()
```

Wait — this won't compile cleanly because the outer function already throws. A simpler approach: in the error path, we still want to attempt shutdown but prioritize the original error. Use a helper pattern:

```swift
do {
    try await services.run()
} catch let serviceError {
    try? await system.shutdown()  // OK here: we're about to throw the real error
    throw serviceError
}
try await system.shutdown()  // This one MUST propagate errors
```

Actually, the issue is specifically that the **normal exit path** (`try await system.shutdown()` after `services.run()` returns normally) silently swallows errors. The error path swallowing is acceptable because we want to throw the service error. So the fix is only the final line:

In all 10 files, change the final `try? await system.shutdown()` to `try await system.shutdown()`. Leave the catch-path `try?` as-is.

### C2: Gateway shutdown ordering

The gateways run `app.runService()` then call `system.shutdown()` sequentially. This is actually fine — the app stops first, then the system shuts down. The real issue (C2) is that `try?` swallows the error. With the C3 fix above, this is resolved.

### I7: Replace `_ = handler` with `withExtendedLifetime`

In all 8 worker files, change:
```swift
let handler = IdentityCommandHandler(actorSystem: system, ...)
_ = handler  // Keep alive
```
to:
```swift
let handler = IdentityCommandHandler(actorSystem: system, ...)
// handler must stay alive for the duration of services.run() — it's registered in system.localActors

// ... keep existing code, but wrap the services.run() + shutdown block:
withExtendedLifetime(handler) {}
```

Wait, `withExtendedLifetime` with an empty closure just extends to that point. We need it to extend through `services.run()`. The correct pattern:

```swift
let handler = IdentityCommandHandler(actorSystem: system, ...)

try await withExtendedLifetime(handler) {
    do {
        try await services.run()
    } catch let serviceError {
        try? await system.shutdown()
        throw serviceError
    }
    try await system.shutdown()
}
```

Hmm, `withExtendedLifetime` doesn't support async closures. The actual safest pattern in Swift is to use `_ = handler` at the end of the scope (after `services.run()` returns), which is what the code already does conceptually. The `let handler` binding already extends to the end of the enclosing scope. The current code is correct; `_ = handler` is just a warning suppressor. Let me reconsider: the real issue the reviewer raised is fragility if someone moves the binding. The simplest robust fix is to add a comment and use `_fixLifetime(handler)` from the standard library (which is specifically designed for this):

Actually, `_fixLifetime` is an internal stdlib function. The simplest robust approach: just reference `handler` after `services.run()`:

```swift
let handler = IdentityCommandHandler(actorSystem: system, ...)

print("Identity worker started on \(socketPath)")

do {
    try await services.run()
} catch let serviceError {
    try? await system.shutdown()
    _ = handler  // ensure handler stays alive through services.run()
    throw serviceError
}
_ = handler  // ensure handler stays alive through services.run()
try await system.shutdown()
```

This is clearer — the `_ = handler` is now explicitly AFTER `services.run()`, making the lifetime intent obvious. Move it from before `services.run()` to after.

### I6: Add RequestIdMiddleware to distributed gateways

In both gateway files (`warbler-distributed/Sources/WarblerGateway/main.swift` and `warbler-distributed-pg/Sources/WarblerGateway/main.swift`), find the router setup (currently `let router = Router()`) and add:

```swift
import SongbirdHummingbird

let router = Router(context: SongbirdRequestContext.self)
router.addMiddleware { RequestIdMiddleware() }
```

Then update all route handler closures to pass the request ID through to EventMetadata. The gateway calls remote distributed actors, so the trace ID needs to be passed as a parameter to the distributed actor methods. Check whether the distributed actor methods already accept a `traceId` parameter — if not, add one.

Actually, looking at the gateway code, it calls distributed actors like `identityHandler.register(email:displayName:)`. These don't currently accept metadata/traceId. Adding it would require changing the distributed actor interfaces across both SQLite and PG variants. This is a significant change.

**Simpler approach**: Add the middleware and SongbirdRequestContext to the gateways for consistency, and log the request ID in the gateway's print statements. Passing traceId through to workers is a larger refactor we should note but not implement here (it would require changing all distributed actor method signatures across 4 workers × 2 variants = 8 files).

In both gateways:
1. Add `import SongbirdHummingbird` (if not already imported)
2. Change `let router = Router()` to `let router = Router(context: SongbirdRequestContext.self)`
3. Add `router.addMiddleware { RequestIdMiddleware() }`
4. Update the route closure signatures from `{ request, context -> Response in` to use `SongbirdRequestContext`

**Verify:** `cd demo/warbler-distributed && swift build` and `cd demo/warbler-distributed-pg && swift build`

**Commit:** `Fix distributed system shutdown, actor lifetime, gateway middleware`

---

## Task 3: Fix domain source issues (I1, I2, I3, I4, S2, S3, S4, S5)

**Why:** Multiple domain source issues: PlaybackInjector over-isolation, missing Equatable, internal reaction enums, hardcoded strings, etc.

**Files:**
- Modify: `demo/warbler/Sources/WarblerAnalytics/PlaybackInjector.swift`
- Modify: `demo/warbler/Sources/WarblerAnalytics/AnalyticsEvent.swift`
- Modify: `demo/warbler/Sources/WarblerAnalytics/ViewCountEvent.swift`
- Modify: `demo/warbler/Sources/WarblerCatalog/VideoEvent.swift`
- Modify: `demo/warbler/Sources/WarblerCatalog/VideoCommands.swift`
- Modify: `demo/warbler/Sources/WarblerIdentity/UserEvent.swift`
- Modify: `demo/warbler/Sources/WarblerIdentity/UserCommands.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionEvent.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleEvent.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleProcess.swift`
- Modify: `demo/warbler/Sources/WarblerCatalog/VideoCatalogProjector.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionProjector.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/EmailNotificationGateway.swift`

**Changes:**

### I1: Make PlaybackInjector.inject() nonisolated

In `PlaybackInjector.swift`, the `continuation` property and `inject()` method can safely be nonisolated because `AsyncStream.Continuation` is `Sendable` and `yield` is thread-safe.

Change line 7:
```swift
private nonisolated let continuation: AsyncStream<InboundEvent>.Continuation
```

Change lines 31-34:
```swift
/// Called by the HTTP route to inject a playback event.
public nonisolated func inject(_ event: InboundEvent) {
    continuation.yield(event)
}
```

### I2: Add explicit Equatable to all event enums

In each of these 6 files, add `, Equatable` to the enum declaration:

- `AnalyticsEvent.swift`: `public enum AnalyticsEvent: Event, Equatable {`
- `ViewCountEvent.swift`: `public enum ViewCountEvent: Event, Equatable {`
- `VideoEvent.swift`: `public enum VideoEvent: Event, Equatable {`
- `UserEvent.swift`: `public enum UserEvent: Event, Equatable {`
- `SubscriptionEvent.swift`: `public enum SubscriptionEvent: Event, Equatable {`
- `SubscriptionLifecycleEvent.swift`: `public enum SubscriptionLifecycleEvent: Event, Equatable {`

### I3: Make process manager reaction enums public

In `SubscriptionLifecycleProcess.swift`, change:
- Line 33: `public enum OnSubscriptionRequested: EventReaction {`
- Line 58: `public enum OnPaymentConfirmed: EventReaction {`
- Line 84: `public enum OnPaymentFailed: EventReaction {`

Also make their typealiases and static properties/methods public:
- All `typealias PMState` → `public typealias PMState`
- All `typealias Input` → `public typealias Input`
- All `static let eventTypes` → `public static let eventTypes`
- All `static func route` → `public static func route`
- All `static func apply` → `public static func apply`
- All `static func react` → `public static func react`

### I4: Add comment to VideoCatalogProjector v1/v2 handling

In `VideoCatalogProjector.swift`, add a comment before the v1 branch (around line 39):
```swift
// NOTE: RecordedEvent.decode() does not go through the EventTypeRegistry upcast chain,
// so this projector must handle v1 events manually. Keep in sync with VideoPublishedUpcast.
case CatalogEventTypes.videoPublishedV1:
```

### S2: Change commandType from computed var to let

In `VideoCommands.swift`:
- Line 4: `public let commandType = "PublishVideo"`
- Line 32: `public let commandType = "UpdateVideoMetadata"`
- Line 59: `public let commandType = "CompleteTranscoding"`
- Line 78: `public let commandType = "UnpublishVideo"`

In `UserCommands.swift`:
- Line 4: `public let commandType = "RegisterUser"`
- Line 29: `public let commandType = "UpdateProfile"`
- Line 52: `public let commandType = "DeactivateUser"`

### S3: Add comment about SubscriptionProjector cross-category concern

In `SubscriptionProjector.swift`, add a comment before the class:
```swift
// This projector handles events from both "subscription" and "subscriptionLifecycle" categories.
// The ProjectionPipeline delivers all events from the event store, so both categories are covered.
```

### S4: Add comment about sentNotifications growth

In `EmailNotificationGateway.swift`, add a comment on line 13:
```swift
/// Tracks sent notifications for testing and observability.
/// In production, replace with metrics emission or a bounded ring buffer.
public private(set) var sentNotifications: [Notification] = []
```

### S5: Use VideoStatus rawValue in VideoCatalogProjector

In `VideoCatalogProjector.swift`, replace hardcoded status strings with enum rawValues:

```swift
// Where currently: "transcoding" → VideoStatus.transcoding.rawValue
// Where currently: "published" → VideoStatus.published.rawValue
// Where currently: "unpublished" → VideoStatus.unpublished.rawValue
```

Find all SQL INSERT/UPDATE statements that use raw status strings and replace them. Check lines 35, 43, etc.

**Verify:** `cd demo/warbler && swift build && swift test`

**Commit:** `Fix domain sources: PlaybackInjector isolation, Equatable, public reactions, status rawValues`

---

## Task 4: Fix entry point consistency issues (S6, S7, S8, I8)

**Why:** Inconsistent logging (print vs Logger), duplicated jsonResponse helper, missing BIND_HOST in P2P SQLite, and HTTPClient.shared lifecycle issue.

**Files:**
- Modify: `demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerCatalogWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerSubscriptionsWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerAnalyticsWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerIdentityWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerCatalogWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerGateway/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerGateway/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerIdentityService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerCatalogService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerSubscriptionsService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerAnalyticsService/main.swift`
- Modify: `demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift`

**Changes:**

### S6: Replace print() with Logger in distributed workers and gateways

All 8 distributed workers already create a `Logger` (it's passed to `SongbirdPostgresMigrations.apply()`). The SQLite workers need to create one. Replace all `print("...")` startup messages with `logger.info("...")`.

For SQLite workers (4 files), add `import Logging` and `let logger = Logger(label: "warbler.identity")` (etc.) near the top, then replace `print(...)` calls.

For PG workers (4 files), the logger already exists. Replace `print(...)` with `logger.info(...)`.

For both gateways, add `import Logging` and `let logger = Logger(label: "warbler.gateway")`, replace `print(...)` with `logger.info(...)`.

### S7: Extract jsonResponse to a shared location

The `jsonResponse` helper is identical in `warbler/Sources/Warbler/main.swift` and `warbler-pg/Sources/Warbler/main.swift`. Since these are separate packages, we can't easily share code between them. Leave the duplication but add a comment:
```swift
// NOTE: This helper is duplicated in warbler-pg. If extracting to a shared module,
// move to a SongbirdHummingbird convenience extension.
```

Actually, this should be a `SongbirdHummingbird` helper. But adding it to the framework is out of scope for a demo remediation. Keep the duplication with the comment.

### S8: Add BIND_HOST to P2P SQLite services

In all 4 `warbler-p2p` service files, add the `BIND_HOST` env var (matching the p2p-pg pattern):

```swift
let bindHost = ProcessInfo.processInfo.environment["BIND_HOST"] ?? "localhost"
```

And change the Application configuration:
```swift
configuration: .init(address: .hostname(bindHost, port: port))
```

### I8: Replace HTTPClient.shared with lifecycle-managed client

In `warbler-p2p-proxy/Sources/WarblerProxy/main.swift`:

1. Create an `HTTPClient` with explicit lifecycle:
```swift
let httpClient = HTTPClient()
```

2. Pass it to `ProxyMiddleware` and `healthCheck`:
```swift
router.get("/health") { _, _ -> Response in
    try await healthCheck(httpClient: httpClient)
}
router.addMiddleware { ProxyMiddleware(backends: backends, httpClient: httpClient) }
```

3. Update `ProxyMiddleware` to accept the client:
```swift
struct ProxyMiddleware: RouterMiddleware {
    let backends: [(prefix: String, port: Int, name: String)]
    let httpClient: HTTPClient
    // ... use httpClient instead of HTTPClient.shared
}
```

4. Shut down the client after the app exits:
```swift
try await app.runService()
try await httpClient.shutdown()
```

Do the same for `warbler-p2p-proxy-pg` if it has a Swift entry point (it uses nginx, so check).

**Verify:** `cd demo/warbler-distributed && swift build` and `cd demo/warbler-distributed-pg && swift build` and `cd demo/warbler-p2p && swift build` and `cd demo/warbler-p2p-proxy && swift build`

**Commit:** `Fix entry point consistency: Logger, BIND_HOST, HTTPClient lifecycle`

---

## Task 5: Remove dead code (S1)

**Why:** `ViewCountAggregate` and `ViewCountEvent` are registered in the event type registry but never wired to routes, command handlers, or projectors. They are dead code that should be removed.

**Files:**
- Delete: `demo/warbler/Sources/WarblerAnalytics/ViewCountAggregate.swift`
- Delete: `demo/warbler/Sources/WarblerAnalytics/ViewCountEvent.swift`
- Delete: `demo/warbler/Tests/WarblerAnalyticsTests/ViewCountAggregateTests.swift`
- Modify: `demo/warbler/Sources/WarblerAnalytics/WarblerAnalytics.swift` — remove `ViewCountEventTypes` enum
- Modify: `demo/warbler/Sources/Warbler/main.swift` — remove ViewCountEvent/ViewCountAggregate registry and repository references
- Modify: `demo/warbler-pg/Sources/Warbler/main.swift` — remove ViewCountEvent registry reference
- Modify: `demo/warbler-p2p/Sources/WarblerAnalyticsService/main.swift` — remove ViewCountEvent registry reference
- Modify: `demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift` — remove ViewCountEvent registry reference
- Modify: `demo/warbler-distributed/Sources/WarblerAnalyticsWorker/main.swift` — remove ViewCountEvent registry reference
- Modify: `demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift` — remove ViewCountEvent registry reference

**Changes:**

1. Delete the three files listed above.

2. In `WarblerAnalytics.swift`, remove the `ViewCountEventTypes` enum entirely. Keep `AnalyticsEventTypes`.

3. In every `main.swift` that registers `ViewCountEvent.self`, remove that line. Search for:
```swift
registry.register(ViewCountEvent.self, eventTypes: [ViewCountEventTypes.viewCounted])
```

4. In `warbler/Sources/Warbler/main.swift`, also remove any `AggregateRepository<ViewCountAggregate>` creation.

**Verify:** `cd demo/warbler && swift build && swift test` — tests should drop from 59 to 54 (5 ViewCountAggregate tests removed). Then: `cd demo/warbler-pg && swift build` and `cd demo/warbler-p2p && swift build` and `cd demo/warbler-p2p-pg && swift build` and `cd demo/warbler-distributed && swift build` and `cd demo/warbler-distributed-pg && swift build`

**Commit:** `Remove dead ViewCountAggregate and ViewCountEvent code`

---

## Task 6: Fix test quality issues (C4, C5, I9-I14, S9, S10)

**Why:** Multiple test quality issues: unreliable assertions, missing coverage for important code paths, tautological tests, unused harnesses.

**Files:**
- Modify: `demo/warbler/Tests/WarblerAnalyticsTests/WarblerAnalyticsTests.swift`
- Modify: `demo/warbler/Tests/WarblerAnalyticsTests/PlaybackInjectorTests.swift`
- Modify: `demo/warbler/Tests/WarblerCatalogTests/WarblerCatalogTests.swift`
- Modify: `demo/warbler/Tests/WarblerSubscriptionsTests/SubscriptionProjectorTests.swift`
- Modify: `demo/warbler/Tests/WarblerSubscriptionsTests/WarblerSubscriptionsTests.swift`

**Changes:**

### C4: Fix hasRecordedAtTimestamp test

In `WarblerAnalyticsTests.swift`, replace lines 74-78:
```swift
// Verify recorded_at column exists and has a non-null value
let count = try await readModel.withConnection { conn in
    try conn.query("SELECT COUNT(*) FROM video_views WHERE recorded_at IS NOT NULL").scalarInt64()
}
#expect(count == 1)
```

### C5: Add status assertion to updateMetadata test

In `WarblerCatalogTests.swift`, in the `updateMetadata` test (around line 55), add after the existing assertions:
```swift
#expect(harness.state.status == .transcoding)
```

### I9: Add test for UnpublishVideo from .transcoding state

In `WarblerCatalogTests.swift`, add:
```swift
@Test func unpublishVideoWhileTranscoding() throws {
    var harness = TestAggregateHarness<VideoAggregate>()
    harness.given(.published(title: "T", description: "D", creatorId: "c"))
    // State is .transcoding (published triggers transcoding state)
    let events = try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
    #expect(events == [.unpublished])
    #expect(harness.state.status == .unpublished)
}
```

### I10: Add tests for ignored events in SubscriptionProjector

In `SubscriptionProjectorTests.swift`, add:
```swift
@Test func ignoresPaymentConfirmed() async throws {
    var (readModel, _, harness) = try await makeProjector()

    try await harness.given(
        SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
        streamName: StreamName(category: "subscription", id: "sub-1")
    )
    try await harness.given(
        SubscriptionEvent.paymentConfirmed(subscriptionId: "sub-1"),
        streamName: StreamName(category: "subscription", id: "sub-1")
    )

    // paymentConfirmed should not change the subscription row
    let sub: SubRow? = try await readModel.queryFirst(SubRow.self) {
        "SELECT id, user_id, plan, status FROM subscriptions WHERE id = \(param: "sub-1")"
    }
    #expect(sub?.status == "pending")
}

@Test func ignoresPaymentFailed() async throws {
    var (readModel, _, harness) = try await makeProjector()

    try await harness.given(
        SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
        streamName: StreamName(category: "subscription", id: "sub-1")
    )
    try await harness.given(
        SubscriptionEvent.paymentFailed(subscriptionId: "sub-1", reason: "Declined"),
        streamName: StreamName(category: "subscription", id: "sub-1")
    )

    let sub: SubRow? = try await readModel.queryFirst(SubRow.self) {
        "SELECT id, user_id, plan, status FROM subscriptions WHERE id = \(param: "sub-1")"
    }
    #expect(sub?.status == "pending")
}
```

### I11: Add out-of-order process manager test

In `WarblerSubscriptionsTests.swift`, add:
```swift
@Test func paymentConfirmedBeforeRequestIsIgnored() throws {
    var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
    try harness.given(
        SubscriptionEvent.paymentConfirmed(subscriptionId: "sub-1"),
        streamName: StreamName(category: "subscription", id: "sub-1")
    )

    let state = harness.state(for: "sub-1")
    #expect(state.status == .initial)
    #expect(harness.output.isEmpty)
}

@Test func paymentFailedBeforeRequestIsIgnored() throws {
    var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
    try harness.given(
        SubscriptionEvent.paymentFailed(subscriptionId: "sub-1", reason: "Declined"),
        streamName: StreamName(category: "subscription", id: "sub-1")
    )

    let state = harness.state(for: "sub-1")
    #expect(state.status == .initial)
    #expect(harness.output.isEmpty)
}
```

### I12: Fix snapshot policy tautology test

This test is in `ViewCountAggregateTests.swift` which will be deleted in Task 5. No action needed — the dead code removal covers this.

### I13: Add TestInjectorHarness test for PlaybackInjector

In `PlaybackInjectorTests.swift`, add:
```swift
@Test func endToEndInjectionViaHarness() async throws {
    let injector = PlaybackInjector()
    let harness = TestInjectorHarness(injector: injector)

    let viewEvent = AnalyticsEvent.videoViewed(videoId: "v-1", userId: "u-1", watchedSeconds: 60)
    let inbound = InboundEvent(
        event: viewEvent,
        stream: StreamName(category: "analytics", id: "v-1"),
        metadata: EventMetadata(traceId: "test")
    )
    await injector.inject(inbound)
    injector.finish()  // Signal end of stream

    let recorded = try await harness.run()
    #expect(recorded.count == 1)
    #expect(recorded[0].streamName == StreamName(category: "analytics", id: "v-1"))
}
```

Note: Check whether `PlaybackInjector` has a `finish()` method to terminate the `AsyncStream`. If not, `TestInjectorHarness.run()` will block forever. The injector's `AsyncStream` needs to be terminated for the harness to return. If there's no `finish()` method, add one:

In `PlaybackInjector.swift`:
```swift
public nonisolated func finish() {
    continuation.finish()
}
```

### I14: Add stream-ID-missing test for SubscriptionProjector

In `SubscriptionProjectorTests.swift`, add:
```swift
@Test func ignoresLifecycleEventsWithoutStreamId() async throws {
    let (readModel, projector, _) = try await makeProjector()

    // First create a subscription so we have data
    let harness = TestProjectorHarness(projector: projector)
    // (we need a mutable copy for given())

    // Create a RecordedEvent with no stream ID (category-only stream)
    let recorded = RecordedEvent(
        id: UUID(),
        streamName: StreamName(category: "subscriptionLifecycle"),
        position: 0,
        globalPosition: 0,
        eventType: LifecycleEventTypes.accessGranted,
        data: try JSONEncoder().encode(SubscriptionLifecycleEvent.accessGranted(userId: "user-1")),
        metadata: EventMetadata(),
        timestamp: Date()
    )
    try await projector.apply(recorded)

    let count = try await readModel.withConnection { conn in
        try conn.query("SELECT COUNT(*) FROM subscriptions").scalarInt64()
    }
    #expect(count == 0)
}
```

### S9: Use #require for process manager output casts

In `WarblerSubscriptionsTests.swift`, replace:
```swift
let output = harness.output[0] as? SubscriptionLifecycleEvent
#expect(output == .accessGranted(userId: "user-1"))
```
with:
```swift
let output = try #require(harness.output[0] as? SubscriptionLifecycleEvent)
#expect(output == .accessGranted(userId: "user-1"))
```

Do this in both `paymentConfirmedGrantsAccess` and `paymentFailedCancelsSubscription`.

### S10: Add intermediate assertions to fullLifecycle test

In `WarblerCatalogTests.swift`, in the `fullLifecycle` test, add status checks between each step:
```swift
@Test func fullLifecycle() throws {
    var harness = TestAggregateHarness<VideoAggregate>()
    try harness.when(
        PublishVideo(title: "T", description: "D", creatorId: "c"),
        using: PublishVideoHandler.self
    )
    #expect(harness.state.status == .transcoding)

    try harness.when(CompleteTranscoding(), using: CompleteTranscodingHandler.self)
    #expect(harness.state.status == .published)

    try harness.when(
        UpdateVideoMetadata(title: "Updated", description: "Better"),
        using: UpdateVideoMetadataHandler.self
    )
    #expect(harness.state.status == .published)
    #expect(harness.state.title == "Updated")

    try harness.when(UnpublishVideo(), using: UnpublishVideoHandler.self)
    #expect(harness.state.status == .unpublished)
    #expect(harness.appliedEvents.count == 4)
}
```

**Verify:** `cd demo/warbler && swift build && swift test` — all tests pass

**Commit:** `Fix test quality: reliable assertions, missing coverage, harness usage`

---

## Task 7: Build verification + changelog

**Files:**
- Create: `changelog/0040-demo-app-review-remediation-round2.md`

**Step 1:** Build all demo apps:
```bash
cd demo/warbler && swift build && swift test
cd demo/warbler-pg && swift build
cd demo/warbler-distributed && swift build
cd demo/warbler-distributed-pg && swift build
cd demo/warbler-p2p && swift build
cd demo/warbler-p2p-pg && swift build
cd demo/warbler-p2p-proxy && swift build
```

**Step 2:** Build + test the main framework: `swift build && swift test`

**Step 3:** Write changelog summarizing all changes.

**Step 4:** Commit: `Add demo app review remediation round 2 changelog`

---

## Summary

| Task | Area | Key Changes | Issues |
|------|------|-------------|--------|
| 1 | PG client lifecycle | Single client.run(), proper shutdown cancellation | C1, I5 |
| 2 | Distributed shutdown | Non-swallowed errors, actor lifetime, gateway middleware | C2, C3, I6, I7 |
| 3 | Domain sources | Injector isolation, Equatable, public reactions, rawValues | I1-I4, S2-S5 |
| 4 | Entry point consistency | Logger, BIND_HOST, HTTPClient lifecycle | S6-S8, I8 |
| 5 | Dead code removal | Remove ViewCountAggregate/Event | S1 |
| 6 | Test quality | Reliable assertions, missing coverage, harness usage | C4, C5, I9-I14, S9, S10 |
| 7 | Verification | Build all demos, changelog | — |
