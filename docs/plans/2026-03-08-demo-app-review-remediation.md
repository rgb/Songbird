# Demo App Review Remediation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all critical, important, and suggestion findings from a 5-agent parallel code review of the 8 Warbler demo apps.

**Architecture:** Tasks are grouped by module/area. The `warbler` demo has the shared domain code (used by all variants), so domain fixes come first. Each variant demo (pg, distributed, p2p, proxy) gets its own task.

**Tech Stack:** Swift 6.2, Hummingbird 2, Songbird framework, DuckDB/Smew, PostgresNIO, SongbirdDistributed

---

## Context

The review covered all 8 demo apps: `warbler` (SQLite monolith), `warbler-pg` (Postgres monolith), `warbler-distributed` (distributed SQLite), `warbler-distributed-pg` (distributed Postgres), `warbler-p2p` (P2P SQLite), `warbler-p2p-pg` (P2P Postgres), `warbler-p2p-proxy` (proxy), and `warbler-p2p-proxy-pg` (Docker/nginx).

Found: 5 critical, 19 important, 12 suggestions.

---

### Task 1: Fix all Package.swift files across all demos

**Why:** Platform version mismatch (.v14 vs .v15), unused/unnecessary dependencies.

**Files:**
- Modify: `demo/warbler/Package.swift`
- Modify: `demo/warbler-pg/Package.swift`
- Modify: `demo/warbler-distributed/Package.swift`
- Modify: `demo/warbler-distributed-pg/Package.swift`
- Modify: `demo/warbler-p2p/Package.swift`
- Modify: `demo/warbler-p2p-pg/Package.swift`

**Changes:**

1. In ALL demo Package.swift files: change `.macOS(.v14)` to `.macOS(.v15)`.

2. In `demo/warbler/Package.swift`: remove the `SongbirdSQLite` dependency from the executable target (line 65) — the app uses `InMemoryEventStore`, not `SQLiteEventStore`.

3. In `demo/warbler-distributed/Package.swift` and `demo/warbler-distributed-pg/Package.swift`: remove the four Warbler domain library dependencies (`WarblerIdentity`, `WarblerCatalog`, `WarblerSubscriptions`, `WarblerAnalytics`) from the `WarblerGateway` executable target — the gateway uses proxy actors, not domain code.

**Verify:** `cd demo/warbler && swift build` (and spot-check one other)

**Commit:** `Fix platform versions and remove unused dependencies across all demo Package.swift files`

---

### Task 2: Fix WarblerCatalog + WarblerIdentity domain source issues

**Why:** Inconsistent event type naming, projector can't handle v1 events, empty placeholder files, VideoEvent.version documentation.

**Files:**
- Modify: `demo/warbler/Sources/WarblerCatalog/VideoEvent.swift`
- Modify: `demo/warbler/Sources/WarblerCatalog/VideoCatalogProjector.swift`
- Modify: `demo/warbler/Sources/WarblerCatalog/WarblerCatalog.swift`
- Modify: `demo/warbler/Sources/WarblerIdentity/UserEvent.swift`
- Modify: `demo/warbler/Sources/WarblerIdentity/UserProjector.swift`
- Modify: `demo/warbler/Sources/WarblerIdentity/WarblerIdentity.swift`

**Changes:**

1. **Rename `TranscodingCompleted` → `VideoTranscodingCompleted`** in `VideoEvent.swift` (line 13). Update all references:
   - `VideoCatalogProjector.swift` (line 48)
   - `demo/warbler/Sources/Warbler/main.swift` (line 24 in the registry)
   - All tests and other demo main.swift files that reference this string

2. **Rename `ProfileUpdated` → `UserProfileUpdated`** in `UserEvent.swift`. Update all references:
   - `UserProjector.swift`
   - `demo/warbler/Sources/Warbler/main.swift` (line 21 in the registry)
   - All tests and other demo main.swift files

3. **Add v1 event handling to VideoCatalogProjector** — add a case for `"VideoPublished_v1"` that decodes as `VideoPublishedV1` and inserts with a default empty description:
   ```swift
   case "VideoPublished_v1":
       let envelope = try event.decode(VideoPublishedV1.self)
       try await readModel.withConnection { conn in
           try conn.execute(
               "INSERT INTO videos (id, title, description, creator_id, status) VALUES (\(param: videoId), \(param: envelope.event.title), \(param: ""), \(param: envelope.event.creatorId), \(param: "transcoding"))"
           )
       }
   ```
   This goes between the `"VideoPublished"` and `"VideoMetadataUpdated"` cases.
   Note: `VideoCatalogProjector` will need to `import WarblerCatalog` (already has it via the module) — check that `VideoPublishedV1` is `public`.

4. **Add a comment to `VideoEvent.version`** explaining the per-enum versioning limitation:
   ```swift
   /// Version applies to the entire enum. Only `.published` changed from v1 → v2
   /// (added `description` field). Other cases have always been at this version.
   public static var version: Int { 2 }
   ```

5. **Replace empty placeholder files** with event type string constants:
   In `WarblerCatalog.swift`:
   ```swift
   import Songbird

   /// Event type string constants for the WarblerCatalog domain.
   public enum CatalogEventTypes {
       public static let videoPublished = "VideoPublished"
       public static let videoPublishedV1 = "VideoPublished_v1"
       public static let videoMetadataUpdated = "VideoMetadataUpdated"
       public static let videoTranscodingCompleted = "VideoTranscodingCompleted"
       public static let videoUnpublished = "VideoUnpublished"
   }
   ```
   In `WarblerIdentity.swift`:
   ```swift
   import Songbird

   /// Event type string constants for the WarblerIdentity domain.
   public enum IdentityEventTypes {
       public static let userRegistered = "UserRegistered"
       public static let userProfileUpdated = "UserProfileUpdated"
       public static let userDeactivated = "UserDeactivated"
   }
   ```

6. **Use the constants** — update `VideoEvent.eventType`, `UserEvent.eventType`, both projectors' switch statements, and the registry `register()` calls in `main.swift` to reference these constants instead of string literals. Also update tests.

**Verify:** `cd demo/warbler && swift build && swift test`

**Commit:** `Fix event naming, add v1 projector handling, extract event type constants in Catalog and Identity`

---

### Task 3: Fix WarblerAnalytics + WarblerSubscriptions domain source issues

**Why:** Gateway userId bug, non-Sendable tuple, missing registerTable, process manager state guards, unnecessary nonisolated(unsafe).

**Files:**
- Modify: `demo/warbler/Sources/WarblerSubscriptions/EmailNotificationGateway.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionProjector.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleProcess.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/SubscriptionLifecycleEvent.swift`
- Modify: `demo/warbler/Sources/WarblerSubscriptions/WarblerSubscriptions.swift`
- Modify: `demo/warbler/Sources/WarblerAnalytics/PlaybackInjector.swift`
- Modify: `demo/warbler/Sources/WarblerAnalytics/WarblerAnalytics.swift`

**Changes:**

1. **Fix EmailNotificationGateway userId bug**: The `SubscriptionCancelled` handler uses `event.streamName.id` (the subscription ID) as the userId. Fix by adding `userId` to the `subscriptionCancelled` event case:
   - In `SubscriptionLifecycleEvent.swift`: change `case subscriptionCancelled(reason: String)` to `case subscriptionCancelled(userId: String, reason: String)`
   - In `SubscriptionLifecycleProcess.swift` (`OnPaymentFailed.react`): pass `userId` from state: `guard case .paymentFailed(_, let reason) = event, let userId = state.userId else { return [] }` then `return [SubscriptionLifecycleEvent.subscriptionCancelled(userId: userId, reason: reason)]`
   - In `EmailNotificationGateway.swift`: `guard case .subscriptionCancelled(let userId, _) = envelope.event else { return }` then use `userId`
   - Update the registry `register()` call and any tests

2. **Replace non-Sendable tuple** in `EmailNotificationGateway.swift`:
   ```swift
   public struct Notification: Sendable, Equatable {
       public let type: String
       public let userId: String
   }
   public private(set) var sentNotifications: [Notification] = []
   ```
   Update all append calls from tuple to `Notification(type:userId:)`. Update tests.

3. **Add registerTable to SubscriptionProjector**:
   ```swift
   public static let tableName = "subscriptions"

   public func registerMigration() async {
       await readModel.registerTable(Self.tableName)
       await readModel.registerMigration { conn in
           // ... existing migration
       }
   }
   ```

4. **Add state transition guards to process manager reactions**:
   - `OnPaymentConfirmed.apply`: add `guard state.status == .paymentPending else { return state }`
   - `OnPaymentFailed.apply`: add `guard state.status == .paymentPending else { return state }`
   - `OnPaymentConfirmed.react`: add `guard state.status == .active` check (state was just updated by apply)
   - `OnPaymentFailed.react`: add `guard state.status == .cancelled` check

5. **Remove `nonisolated(unsafe)`** from `PlaybackInjector._events` — `AsyncStream<InboundEvent>` is `Sendable`.

6. **Create event type constants** in `WarblerSubscriptions.swift` and `WarblerAnalytics.swift`:
   ```swift
   // WarblerSubscriptions.swift:
   public enum SubscriptionEventTypes {
       public static let subscriptionRequested = "SubscriptionRequested"
       public static let paymentConfirmed = "PaymentConfirmed"
       public static let paymentFailed = "PaymentFailed"
   }
   public enum LifecycleEventTypes {
       public static let accessGranted = "AccessGranted"
       public static let subscriptionCancelled = "SubscriptionCancelled"
   }

   // WarblerAnalytics.swift:
   public enum AnalyticsEventTypes {
       public static let videoViewed = "VideoViewed"
   }
   public enum ViewCountEventTypes {
       public static let viewCounted = "ViewCounted"
   }
   ```
   Use these constants in the event types, projectors, gateway, registry calls, and tests.

**Verify:** `cd demo/warbler && swift build && swift test`

**Commit:** `Fix gateway userId bug, add Sendable notification type, add state guards, extract event type constants`

---

### Task 4: Add missing tests in warbler

**Why:** Missing error path tests, projector edge case tests, injector failure test.

**Files:**
- Modify: `demo/warbler/Tests/WarblerCatalogTests/WarblerCatalogTests.swift`
- Modify: `demo/warbler/Tests/WarblerCatalogTests/VideoCatalogProjectorTests.swift`
- Modify: `demo/warbler/Tests/WarblerIdentityTests/UserProjectorTests.swift`
- Modify: `demo/warbler/Tests/WarblerAnalyticsTests/PlaybackInjectorTests.swift`
- Modify: `demo/warbler/Tests/WarblerAnalyticsTests/WarblerAnalyticsTests.swift`
- Modify: `demo/warbler/Tests/WarblerSubscriptionsTests/SubscriptionProjectorTests.swift`
- Modify: `demo/warbler/Tests/WarblerSubscriptionsTests/EmailNotificationGatewayTests.swift`

**Changes:**

1. **VideoAggregate error path tests** — add to WarblerCatalogTests:
   - `rejectMetadataUpdateWhenInitial` — UpdateVideoMetadata on initial state throws `.notPublished`
   - `rejectMetadataUpdateWhenUnpublished` — UpdateVideoMetadata on unpublished state throws `.videoUnpublished`
   - `rejectDoubleUnpublish` — UnpublishVideo on already unpublished throws `.videoUnpublished`
   - `updateMetadataWhenPublished` — UpdateVideoMetadata after transcoding completes (published state)

2. **VideoCatalogProjector edge cases** — add:
   - `ignoresEventsWithoutStreamId` — feed event with category-only StreamName
   - `ignoresUnknownEventType` — feed event with unrecognized type
   - `handlesV1VideoPublishedEvent` — feed a v1 event and verify it's projected with empty description

3. **UserProjector edge case** — add `ignoresUnknownEventType`

4. **PlaybackInjector failure test** — add:
   - `doesNotCountFailedAppends` — call didAppend with .failure, verify count stays 0

5. **PlaybackAnalyticsProjector edge case** — add `ignoresUnknownEventType`

6. **SubscriptionProjector edge case** — add `ignoresUnknownEventType`

7. **EmailNotificationGateway userId assertion** — update existing cancellation test to verify the userId matches the actual user ID (not the subscription ID).

**Verify:** `cd demo/warbler && swift test`

**Commit:** `Add error path and edge case tests for all demo domain modules`

---

### Task 5: Fix monolith entry points (warbler + warbler-pg)

**Why:** SongbirdTesting in production, dead code, hard-coded port, missing logging, repeated JSONEncoder pattern.

**Files:**
- Modify: `demo/warbler/Sources/Warbler/main.swift`
- Modify: `demo/warbler-pg/Sources/Warbler/main.swift`

**Changes:**

1. **Remove SongbirdTesting dependency from warbler monolith** — replace `InMemoryEventStore()` with `SQLiteEventStore(path: ":memory:")`, `InMemoryPositionStore()` with `SQLitePositionStore(path: ":memory:")`, `InMemorySnapshotStore()` with `SQLiteSnapshotStore(path: ":memory:")`. Update imports: remove `SongbirdTesting`, keep `SongbirdSQLite`. Also update `demo/warbler/Package.swift`: remove `SongbirdTesting` from the executable target deps (it remains in test targets).

2. **Remove dead `_viewCountRepo` code** — delete the 3 lines creating it and the `_ = _viewCountRepo` line. In both main.swift files.

3. **Add configurable port** — in both files:
   ```swift
   let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
   ```
   Update `Application` configuration and print message to use `port`.

4. **Use structured logging** — replace `print("Warbler starting...")` with a Logger in both files:
   ```swift
   import Logging
   let logger = Logger(label: "warbler")
   logger.info("Warbler starting on http://localhost:\(port)")
   ```

5. **Extract a JSON response helper** at the top of each file:
   ```swift
   private func jsonResponse(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
       let data = try JSONEncoder().encode(value)
       return Response(
           status: status,
           headers: [.contentType: "application/json"],
           body: .init(byteBuffer: ByteBuffer(data: data))
       )
   }
   ```
   Replace all the inline JSONEncoder+ByteBuffer patterns with `try jsonResponse(result)`.

6. **Update all event type string references** to use the constants from Task 2/3 (e.g., `CatalogEventTypes.videoPublished`).

**Verify:** `cd demo/warbler && swift build` and `cd demo/warbler-pg && swift build`

**Commit:** `Remove SongbirdTesting from production, add configurable port, extract JSON helper, use structured logging`

---

### Task 6: Fix distributed demo apps

**Why:** PostgresClient.run() double-call, no system.shutdown(), unused imports, exit codes, missing README.

**Files:**
- Modify: `demo/warbler-distributed/Sources/WarblerGateway/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerCatalogWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerAnalyticsWorker/main.swift`
- Modify: `demo/warbler-distributed/Sources/WarblerSubscriptionsWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerGateway/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerCatalogWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerIdentityWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift`
- Modify: `demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker/main.swift`
- Create: `demo/warbler-distributed/README.md`

**Changes:**

1. **Remove unused imports from both gateways**: remove `import Songbird` and `import SongbirdHummingbird`.

2. **Add `system.shutdown()`** to all gateways and workers — use `defer`:
   ```swift
   let system = SongbirdActorSystem(...)
   defer { try? await system.shutdown() }
   ```
   Note: `defer` with `await` requires Swift 6.0+. If not supported, wrap in a do/catch/finally pattern.

3. **Fix PostgresClient.run() double-call in PG workers** — restructure so client.run() is called only once in the outer task group:
   ```swift
   try await withThrowingTaskGroup(of: Void.self) { group in
       group.addTask { await client.run() }
       group.addTask {
           try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
           // ... set up stores, projectors, actor system, services ...
           try await services.run()
       }
       try await group.waitForAll()
   }
   ```

4. **Exit with code 1 on missing arguments** — in all SQLite workers, change `return` to `throw` after the usage message:
   ```swift
   guard CommandLine.arguments.count >= 2 else {
       print("Usage: ...")
       Darwin.exit(1)
   }
   ```
   Same for PG workers.

5. **Update event type string references** to use the constants from Task 2/3 in all registry calls.

6. **Create `demo/warbler-distributed/README.md`** — mirror the structure of `demo/warbler-distributed-pg/README.md`.

**Verify:** `cd demo/warbler-distributed && swift build` and `cd demo/warbler-distributed-pg && swift build`

**Commit:** `Fix distributed demos: shutdown, single client.run, exit codes, remove unused imports, add README`

---

### Task 7: Fix P2P + proxy demo apps

**Why:** Hard-coded paths/ports, SongbirdTesting dependency, nginx trailing slash, manual JSON, localhost binding.

**Files:**
- Modify: `demo/warbler-p2p/Sources/WarblerCatalogService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerIdentityService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerAnalyticsService/main.swift`
- Modify: `demo/warbler-p2p/Sources/WarblerSubscriptionsService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerCatalogService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerIdentityService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift`
- Modify: `demo/warbler-p2p-pg/Sources/WarblerSubscriptionsService/main.swift`
- Modify: `demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift`
- Modify: `demo/warbler-p2p-proxy-pg/nginx.conf`

**Changes:**

1. **Make file paths configurable** in all P2P SQLite services:
   ```swift
   let sqlitePath = ProcessInfo.processInfo.environment["SQLITE_PATH"] ?? "data/songbird.sqlite"
   let duckdbPath = ProcessInfo.processInfo.environment["DUCKDB_PATH"] ?? "data/catalog.duckdb"
   ```

2. **Make port configurable** in all P2P services (both SQLite and PG):
   ```swift
   let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8082") ?? 8082
   ```

3. **Make bind host configurable** in all P2P PG services:
   ```swift
   let bindHost = ProcessInfo.processInfo.environment["BIND_HOST"] ?? "localhost"
   configuration: .init(address: .hostname(bindHost, port: port))
   ```

4. **Fix nginx trailing slashes** in `warbler-p2p-proxy-pg/nginx.conf`:
   ```nginx
   location /users {
   location /videos {
   location /subscriptions {
   location /analytics {
   ```

5. **Replace manual JSON in proxy** with JSONEncoder:
   ```swift
   struct HealthResponse: Codable, Sendable {
       let status: String
       let services: [String: String]
   }
   let response = HealthResponse(status: allHealthy ? "healthy" : "degraded", services: dict)
   let data = try JSONEncoder().encode(response)
   ```

6. **Remove dead `_viewCountRepo`** code from all analytics services.

7. **Update event type string references** in all registry calls.

**Verify:** `cd demo/warbler-p2p && swift build` and `cd demo/warbler-p2p-pg && swift build`

**Commit:** `Fix P2P demos: configurable paths/ports/host, nginx locations, proxy JSON encoding`

---

### Task 8: Cross-cutting suggestions (launch scripts, README, misc)

**Why:** Remaining suggestions: launch.sh improvements, Postgres config boilerplate, command input validation.

**Files:**
- Modify: `demo/warbler-distributed/launch.sh`
- Modify: `demo/warbler-distributed-pg/launch.sh`
- Modify: `demo/warbler-p2p-proxy-pg/launch.sh`
- Modify: `demo/warbler/Sources/WarblerCatalog/VideoCommands.swift`
- Modify: `demo/warbler/Sources/WarblerIdentity/UserCommands.swift`

**Changes:**

1. **Fix launch.sh scripts** — replace `sleep 1`/`sleep 2` with socket/port polling:
   ```bash
   # For distributed (socket-based):
   for sock in identity.sock catalog.sock subscriptions.sock analytics.sock; do
       while [ ! -S "$SOCKET_DIR/$sock" ]; do sleep 0.1; done
   done

   # For P2P (port-based):
   for p in 8081 8082 8083 8084; do
       until nc -z localhost $p 2>/dev/null; do sleep 0.2; done
   done
   ```

2. **Remove `2>/dev/null || true` from build commands** in launch.sh — let build failures surface:
   ```bash
   swift build || exit 1
   ```

3. **Add input validation examples** to at least one command in each domain:
   - `PublishVideo`: guard title and description are non-empty
   - `RegisterUser`: guard email is non-empty

**Verify:** Check scripts are syntactically correct; `cd demo/warbler && swift build && swift test`

**Commit:** `Improve launch scripts, add command input validation examples`

---

### Task 9: Build verification across all demos + changelog

**Files:**
- Create: `changelog/0039-demo-app-review-remediation.md`

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

**Step 2:** Also build + test the main Songbird framework: `swift build && swift test`

**Step 3:** Write changelog summarizing all changes.

**Step 4:** Commit: `Add demo app review remediation changelog`

---

## Summary

| Task | Area | Key Changes |
|------|------|-------------|
| 1 | Package.swift | Platform .v15, remove unused deps |
| 2 | Catalog + Identity | Event naming, v1 projector handling, event type constants |
| 3 | Analytics + Subscriptions | Gateway userId fix, Sendable type, state guards, registerTable |
| 4 | Tests | Error paths, projector edge cases, injector failure |
| 5 | Monolith entry points | Remove SongbirdTesting, configurable port, JSON helper, logging |
| 6 | Distributed demos | shutdown(), single client.run(), exit codes, unused imports |
| 7 | P2P + proxy | Configurable paths/ports, nginx fix, proxy JSON |
| 8 | Cross-cutting | launch.sh polling, input validation |
| 9 | Verification | Build all demos, changelog |
