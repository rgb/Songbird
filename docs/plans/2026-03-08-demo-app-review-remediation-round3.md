# Demo App Review Remediation (Round 3) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix process manager idempotency bug, proxy lifecycle issues, P2P service patterns, and minor code quality issues identified in the round 3 demo app review.

**Architecture:** The core fix (C1) is a framework-level change to `ProcessManager.State` requiring `Equatable`, enabling the `AnyReaction` handle closure to skip output when state is unchanged on event re-delivery. All other changes are demo-level fixes: proxy lifecycle management, P2P service shutdown patterns, logging consistency, and HTTP status codes.

**Tech Stack:** Swift 6.2, Hummingbird 2, AsyncHTTPClient, swift-log, Swift Testing

---

## Issue Cross-Reference

| ID | Sev | Task | Description |
|----|-----|------|-------------|
| C1 | Critical | 1 | Process manager re-delivery produces duplicate output events |
| C3 | Critical | 2 | HTTPClient shutdown unreachable in proxy on throw path |
| I1 | Important | 3 | SQLite P2P services use `waitForAll()` instead of `next()+cancelAll()` |
| I3 | Important | 4 | Gateway `fatalError()` stubs lack descriptive message |
| I6 | Important | 1 | No idempotency tests for process manager re-delivery |
| I7 | Important | 3 | P2P services use `print()` instead of Logger |
| I8 | Important | 2 | Proxy health check probes `/` (always 404 on backends) |
| I9 | Important | 2 | Proxy `BIND_HOST`/`PORT` hardcoded |
| I11 | Important | 4 | Optional `CountRow` encoding as JSON `null` |
| S3 | Suggestion | 4 | HTTP DELETE/PATCH returning `.ok` instead of `.noContent` |

### Investigated and Downgraded (not actionable)

| ID | Sev | Reason |
|----|-----|--------|
| C2 | Critical→N/A | P2P PG services already use the reference nested task group pattern from `warbler-pg`. Distributed PG workers use flat structure but only have one long-running task (`services.run()`), so nested group is unnecessary. `next()+cancelAll()` correctly handles both directions. |
| C4 | Critical→N/A | `withExtendedLifetime` does NOT support async closures in Swift 6.2 (confirmed via stdlib source and SE-0465). The current `_ = handler` pattern is the correct approach — the `let handler` binding extends to end of scope, and `_ = handler` after `services.run()` prevents the optimizer from releasing early. Zero uses of `withExtendedLifetime` exist in the Songbird codebase. |
| I2 | Important→Deferred | Adding `traceId` to distributed actor function signatures requires changing all 8 workers × 2 variants + both gateways. This is a breaking wire-protocol change better suited for a dedicated feature task. |
| I4 | Important→N/A | Manual v1 projector handling already has a "keep in sync" comment. The limitation is in the framework's `RecordedEvent.decode()` which bypasses the upcast chain. Not fixable at the demo level. |
| I5 | Important→Deferred | Removing `subscriptionId` from `SubscriptionEvent` payloads would change the event schema (breaking immutability principle). The redundancy is a design debt, not a bug. |
| I10 | Important→N/A | `VideoEvent.version = 2` on the whole enum is already documented with a comment. Per-case versioning would require separate event types (a larger refactoring). |
| S1 | Suggestion→N/A | `PlaybackInjector.finish()` was added in round 2 for `TestInjectorHarness` tests. Making it `internal` would require `@testable import` in the test. The public API is acceptable for a demo component. |
| S2 | Suggestion→N/A | `JSONEncoder()` per call is thread-safe but sharing a single instance requires concurrency analysis. Not worth the risk for a demo. |

---

## Task 1: Fix process manager idempotency (C1, I6)

**Why:** The `ProcessManager`'s `AnyReaction` handle closure calls `R.react(newState, event)` with the post-apply state. When `apply()` guards against re-delivery (returning state unchanged), `react()` still sees the already-transitioned state and produces duplicate output events. This violates the at-least-once delivery idempotency guarantee stated in CLAUDE.md.

**Root cause:** In `ProcessManager.swift` line 62-66, the `reaction()` helper creates an `AnyReaction` whose `handle` closure unconditionally calls `react()` with the new state, regardless of whether `apply()` actually changed anything.

**Fix:** Add `Equatable` to `ProcessManager.State` (and `EventReaction.PMState`), then skip `react()` when state is unchanged. This is safe because all existing State types already conform to `Equatable`:
- `RunnerFulfillmentPM.State: Sendable, Equatable` (framework tests)
- `HarnessFulfillmentPM.State: Sendable, Equatable` (harness tests)
- `SubscriptionLifecycleProcess.State: Sendable, Equatable` (demo)

**Files:**
- Modify: `Sources/Songbird/ProcessManager.swift:26,53,64-65`
- Modify: `Sources/Songbird/EventReaction.swift:44`
- Test: `demo/warbler/Tests/WarblerSubscriptionsTests/WarblerSubscriptionsTests.swift`

**Changes:**

### Step 1: Add Equatable constraint to protocols

In `Sources/Songbird/EventReaction.swift`, line 44, change:
```swift
    associatedtype PMState: Sendable
```
to:
```swift
    associatedtype PMState: Sendable, Equatable
```

In `Sources/Songbird/ProcessManager.swift`, line 26, change:
```swift
    associatedtype State: Sendable
```
to:
```swift
    associatedtype State: Sendable, Equatable
```

### Step 2: Skip output when state unchanged

In `Sources/Songbird/ProcessManager.swift`, lines 62-66, change:
```swift
            handle: { state, recorded in
                let event = try R.decode(recorded)
                let newState = R.apply(state, event)
                let output = R.react(newState, event)
                return (newState, output)
            }
```
to:
```swift
            handle: { state, recorded in
                let event = try R.decode(recorded)
                let newState = R.apply(state, event)
                // Skip output when state unchanged — the event was already processed
                // or is irrelevant. This ensures idempotency under at-least-once delivery.
                let output = (newState == state) ? [] : R.react(newState, event)
                return (newState, output)
            }
```

### Step 3: Add idempotency tests

In `demo/warbler/Tests/WarblerSubscriptionsTests/WarblerSubscriptionsTests.swift`, add:
```swift
    @Test func duplicatePaymentConfirmedDoesNotProduceDuplicateOutput() throws {
        var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
        try harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        // First delivery — should produce output
        try harness.given(
            SubscriptionEvent.paymentConfirmed(subscriptionId: "sub-1"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        #expect(harness.output.count == 1)

        // Second delivery (re-delivery) — should NOT produce output
        try harness.given(
            SubscriptionEvent.paymentConfirmed(subscriptionId: "sub-1"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        #expect(harness.output.count == 1, "Re-delivered event should not produce duplicate output")
        #expect(harness.state(for: "sub-1").status == .active)
    }

    @Test func duplicatePaymentFailedDoesNotProduceDuplicateOutput() throws {
        var harness = TestProcessManagerHarness<SubscriptionLifecycleProcess>()
        try harness.given(
            SubscriptionEvent.requested(subscriptionId: "sub-1", userId: "user-1", plan: "pro"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        // First delivery
        try harness.given(
            SubscriptionEvent.paymentFailed(subscriptionId: "sub-1", reason: "Declined"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        #expect(harness.output.count == 1)

        // Second delivery (re-delivery)
        try harness.given(
            SubscriptionEvent.paymentFailed(subscriptionId: "sub-1", reason: "Declined"),
            streamName: StreamName(category: "subscription", id: "sub-1")
        )
        #expect(harness.output.count == 1, "Re-delivered event should not produce duplicate output")
        #expect(harness.state(for: "sub-1").status == .cancelled)
    }
```

### Step 4: Build and test

```bash
swift build && swift test
cd demo/warbler && swift build && swift test
```

All existing framework tests (508) and demo tests should pass. The new idempotency tests should also pass.

**Commit:** `Fix process manager idempotency: skip output when state unchanged on re-delivery`

---

## Task 2: Fix proxy lifecycle and configuration (C3, I8, I9)

**Why:** The proxy's `HTTPClient` is not shut down if `app.runService()` throws. The health check probes `/` which doesn't exist on backends. `BIND_HOST` and `PORT` are hardcoded while all 8 backend services read from the environment.

**Files:**
- Modify: `demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift`

**Changes:**

### C3: Fix HTTPClient shutdown

Replace lines 41-42:
```swift
        try await app.runService()
        try await httpClient.shutdown()
```

with:
```swift
        do {
            try await app.runService()
        } catch {
            try? await httpClient.shutdown()
            throw error
        }
        try await httpClient.shutdown()
```

This ensures `httpClient.shutdown()` is called on both the normal exit path (propagating errors) and the error path (swallowing shutdown errors to prioritize the original error).

### I9: Add BIND_HOST and PORT env vars

Add after `let httpClient = HTTPClient()` (line 20):
```swift
        let bindHost = ProcessInfo.processInfo.environment["BIND_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
```

Update the Application configuration (line 33):
```swift
        configuration: .init(address: .hostname(bindHost, port: port))
```

Update the log messages (lines 36-39):
```swift
        logger.info("WarblerProxy starting on http://\(bindHost):\(port)")
```

Also read backend ports from environment if available, or add a comment explaining the hardcoded defaults:
```swift
    // Backend ports are configured to match the P2P service defaults (8081-8084).
    // Override via individual service PORT env vars if needed.
    static let backends: [(prefix: String, port: Int, name: String)] = [
```

### I8: Document health check semantics

In the `healthCheck` function, update the comment and URL to use `/health` (which is the proxy's own health route, not the backends'). Actually, the proxy health check probes BACKEND services. The backends don't have `/health` routes. Instead of adding routes to all backends (out of scope), add a clear comment:

```swift
    static func healthCheck(httpClient: HTTPClient) async throws -> Response {
        // TCP reachability check — probes each backend to verify the HTTP server is running.
        // This does NOT verify database connectivity or service-level health.
```

And change the probe URL from `/` to a known route for each backend:
```swift
        for backend in backends {
            // Probe a known route for each backend service
            let url = "http://localhost:\(backend.port)\(backend.prefix)"
```

This probes `/users`, `/videos`, `/subscriptions`, `/analytics` — routes that actually exist. A 200 response means the service is functioning (not just TCP-reachable).

### Also: Fix print() in ProxyMiddleware

Replace line 102:
```swift
        print("\(request.method) \(path) → :\(backend.port) (\(backend.name)) → \(response.status.code) [\(elapsed)]")
```

The middleware doesn't have a logger. Add a `logger` property to `ProxyMiddleware`:
```swift
struct ProxyMiddleware: RouterMiddleware {
    let backends: [(prefix: String, port: Int, name: String)]
    let httpClient: HTTPClient
    let logger: Logger
```

Pass `logger` when creating the middleware:
```swift
        router.addMiddleware { ProxyMiddleware(backends: backends, httpClient: httpClient, logger: logger) }
```

Replace the `print()` with:
```swift
        logger.info("\(request.method) \(path) → :\(backend.port) (\(backend.name)) → \(response.status.code) [\(elapsed)]")
```

**Verify:** `cd demo/warbler-p2p-proxy && swift build`

**Commit:** `Fix proxy: HTTPClient shutdown, BIND_HOST/PORT, health check, structured logging`

---

## Task 3: Fix P2P service patterns (I1, I7)

**Why:** SQLite P2P services use `waitForAll()` which doesn't cancel the sibling task when one fails. They also use `print()` instead of Logger, inconsistent with the distributed workers fixed in round 2.

**Files:**
- Modify: `demo/warbler-p2p/Sources/WarblerIdentityService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerCatalogService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerSubscriptionsService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerAnalyticsService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerIdentityService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerCatalogService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerSubscriptionsService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift`

**Changes:**

### I1: Change SQLite P2P task group from waitForAll() to next()+cancelAll()

In each of the 4 SQLite P2P services, change:
```swift
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
```
to:
```swift
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.next()
            group.cancelAll()
        }
```

This ensures that when either task fails or completes, the other is cancelled, preventing a degraded half-running state.

### I7: Replace print() with Logger in all 8 P2P services

**SQLite services (4 files):** Add `import Logging`, create logger, replace `print()`:

```swift
import Logging

// Near the top of main():
let logger = Logger(label: "warbler.<domain>")
```

Replace the startup `print(...)` call with `logger.info(...)`.

Logger labels:
- Identity: `"warbler.identity"`
- Catalog: `"warbler.catalog"`
- Subscriptions: `"warbler.subscriptions"`
- Analytics: `"warbler.analytics"`

**PG services (4 files):** Already have `import Logging` and a `Logger` instance (used for migrations). Replace the startup `print(...)` with `logger.info(...)`.

**Verify:** `cd demo/warbler-p2p && swift build` and `cd demo/warbler-p2p-pg && swift build`

**Commit:** `Fix P2P services: proper shutdown cancellation, structured logging`

---

## Task 4: Fix minor code quality (I3, I11, S3)

**Why:** Gateway fatalError stubs lack context, analytics routes encode Optional as JSON null, and several routes return `.ok` with empty bodies instead of `.noContent`.

**Files:**
- Modify: `demo/warbler-distributed/Sources/WarblerGateway/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerGateway/main.swift`
- Modify: `demo/warbler/Sources/Warbler/main.swift`
- Modify: `demo/warbler-pg/Sources/Warbler/main.swift`

**Changes:**

### I3: Add descriptive message to gateway fatalError stubs

In both gateway files, the remote actor proxy declarations have:
```swift
distributed func registerUser(id: String, email: String, displayName: String) async throws { fatalError() }
```

Add a descriptive message to each `fatalError()`:
```swift
distributed func registerUser(id: String, email: String, displayName: String) async throws {
    fatalError("Remote-only actor — local invocation is not supported")
}
```

Apply to ALL `fatalError()` stubs in both gateway files (there should be several per remote actor proxy).

### I11: Fix Optional CountRow encoding

In `demo/warbler/Sources/Warbler/main.swift` (the analytics view count route), the query uses `COUNT(*)` which always returns a row. Make the type non-optional:

Find the analytics route that does:
```swift
let result: CountRow? = try await readModel.queryFirst(CountRow.self) {
```

Change to use `query` with a non-optional return, or keep `queryFirst` but unwrap with a default:
```swift
let result: CountRow? = try await readModel.queryFirst(CountRow.self) {
    "SELECT COUNT(*) AS view_count, COALESCE(SUM(watched_seconds), 0) AS total_seconds FROM video_views WHERE video_id = \(param: id)"
}
guard let result else {
    return try jsonResponse(CountRow(viewCount: 0, totalSeconds: 0))
}
return try jsonResponse(result)
```

Apply the same fix in `demo/warbler-pg/Sources/Warbler/main.swift` if the same pattern exists there.

Also check `demo/warbler-p2p/Sources/WarblerAnalyticsService/main.swift` and `demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift` for the same pattern.

### S3: Use .noContent for empty-body responses

In `demo/warbler/Sources/Warbler/main.swift`, change routes that return an empty body with `.ok` to use `.noContent`:

- `PATCH /users/{id}` (updateProfile): `return Response(status: .ok)` → `return Response(status: .noContent)`
- `DELETE /users/{id}` (deactivateUser): `return Response(status: .ok)` → `return Response(status: .noContent)`
- `PATCH /videos/{id}` (updateMetadata): `return Response(status: .ok)` → `return Response(status: .noContent)`
- `POST /videos/{id}/transcode-complete`: `return Response(status: .ok)` → `return Response(status: .noContent)`
- `DELETE /videos/{id}` (unpublishVideo): `return Response(status: .ok)` → `return Response(status: .noContent)`

Apply the same changes in `demo/warbler-pg/Sources/Warbler/main.swift`.

**Verify:** `cd demo/warbler && swift build && swift test` and `cd demo/warbler-pg && swift build` and `cd demo/warbler-distributed && swift build` and `cd demo/warbler-distributed-pg && swift build`

**Commit:** `Fix code quality: descriptive fatalError, non-optional CountRow, HTTP 204 for empty responses`

---

## Task 5: Build verification + changelog

**Files:**
- Create: `changelog/0041-demo-app-review-remediation-round3.md`

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

**Step 3:** Write changelog summarizing all changes from this round, referencing issue IDs.

**Step 4:** Commit: `Add demo app review remediation round 3 changelog`

---

## Summary

| Task | Area | Key Changes | Issues |
|------|------|-------------|--------|
| 1 | Framework + demo | Equatable constraint on ProcessManager.State, skip output on unchanged state, idempotency tests | C1, I6 |
| 2 | Proxy | HTTPClient lifecycle, BIND_HOST/PORT, health check, structured logging | C3, I8, I9 |
| 3 | P2P services | next()+cancelAll() shutdown, Logger replacing print() | I1, I7 |
| 4 | Code quality | Descriptive fatalError, non-optional CountRow, HTTP 204 | I3, I11, S3 |
| 5 | Verification | Build all demos, changelog | — |
