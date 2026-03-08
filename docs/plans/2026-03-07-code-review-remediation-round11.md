# Code Review Remediation Round 11 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 4 important issues and highest-value suggestions from the fifth consecutive review — this is the final polish round.

**Architecture:** Each task is self-contained. The final task does clean build, full test suite, and changelog.

**Tech Stack:** Swift 6.2, Swift Testing, NIOCore, PostgresNIO, Smew/DuckDB

---

## Context

Round 11 found 0 critical, 4 important, 16 suggestions, and 10 test gaps. This plan addresses the important items plus the highest-value suggestions and test parity gaps.

**Baseline:** 506 tests passing, clean build.

---

### Task 1: Smew — Remove unnecessary nonisolated(unsafe) on connection

**Why:** `Connection` in Smew is `public final class Connection: Sendable`. The `nonisolated(unsafe)` annotation on a `private let` property of `Sendable` type within an actor is unnecessary and may produce a compiler warning.

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`

**Changes:**
Read the file first. Find the `connection` property declaration. Change from:
```swift
private nonisolated(unsafe) let connection: Connection
```
to:
```swift
private let connection: Connection
```

Remove or update the doc comment above it that justifies `nonisolated(unsafe)`.

**Verify:** `swift build`

**Commit:** `git commit -m "Remove unnecessary nonisolated(unsafe) on ReadModelStore.connection"`

---

### Task 2: Postgres — Add batchSize precondition to PostgresEventSubscription

**Why:** All other subscription types validate `batchSize > 0` in their init (added in Round 10), but `PostgresEventSubscription` omits this check.

**Files:**
- Modify: `Sources/SongbirdPostgres/PostgresEventSubscription.swift`

**Changes:**
Read the file. Find the `init`. Add after the property assignments:
```swift
precondition(batchSize > 0, "batchSize must be positive")
```

**Verify:** `swift build`

**Commit:** `git commit -m "Add batchSize precondition to PostgresEventSubscription"`

---

### Task 3: Distributed — Make shutdown() resilient + guard TransportClient.connect()

**Why:** If `server.stop()` throws during `shutdown()`, no clients are disconnected — leaking NIO threads. Also, `TransportClient.connect()` silently overwrites an existing channel if called twice.

**Files:**
- Modify: `Sources/SongbirdDistributed/SongbirdActorSystem.swift`
- Modify: `Sources/SongbirdDistributed/Transport.swift`

**Changes:**
1. In `SongbirdActorSystem.swift`, read the file. Find `shutdown()`. Rewrite to ensure all resources are cleaned up regardless of individual failures:
   ```swift
   public func shutdown() async throws {
       var firstError: (any Error)?
       if let server = serverBox.withLock({ val -> TransportServer? in
           let s = val; val = nil; return s
       }) {
           do { try await server.stop() }
           catch { firstError = error }
       }
       let allClients = clients.withLock { dict -> [TransportClient] in
           let values = Array(dict.values)
           dict.removeAll()
           return values
       }
       for client in allClients {
           do { try await client.disconnect() }
           catch { if firstError == nil { firstError = error } }
       }
       if let firstError { throw firstError }
   }
   ```

2. In `Transport.swift`, read the file. Find `TransportClient.connect()`. Add a precondition at the top:
   ```swift
   precondition(channel == nil, "TransportClient.connect() called while already connected. Call disconnect() first.")
   ```

**Verify:** `swift build && swift test --filter SongbirdDistributed`

**Commit:** `git commit -m "Make shutdown() resilient to partial failures and guard against double-connect"`

---

### Task 4: Core — VersionConflictError Equatable + AnyReaction @Sendable properties

**Why:** `VersionConflictError` is the only public error type without `Equatable`, making test assertions weaker. `AnyReaction`'s stored closure properties drop `@Sendable` from the init parameters.

**Files:**
- Modify: `Sources/Songbird/EventStore.swift`
- Modify: `Sources/Songbird/EventReaction.swift`

**Changes:**
1. In `EventStore.swift`, add `Equatable` conformance to `VersionConflictError`:
   ```swift
   public struct VersionConflictError: Error, Equatable, CustomStringConvertible {
   ```

2. In `EventReaction.swift`, read the file. Find the stored properties on `AnyReaction`. Add `@Sendable` to the closure types:
   ```swift
   public let tryRoute: @Sendable (RecordedEvent) throws -> String?
   public let handle: @Sendable (State, RecordedEvent) throws -> (state: State, output: [any Event])
   ```

**Verify:** `swift build`

**Commit:** `git commit -m "Add Equatable to VersionConflictError and @Sendable to AnyReaction properties"`

---

### Task 5: SQLite — hasKey use db.scalar + cleanup

**Why:** `SQLiteKeyStore.hasKey` uses `db.prepare` + row iteration for a `SELECT COUNT(*)` query, while every other single-value query uses `db.scalar`. Also, test file has unused `@testable import SongbirdTesting` and legacy `ISO8601DateFormatter` usage.

**Files:**
- Modify: `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`

**Changes:**
1. In `SQLiteKeyStore.swift`, read the file. Find `hasKey`. Replace the `db.prepare` + iteration with `db.scalar`:
   ```swift
   func hasKey(for reference: String, layer: EncryptionLayer) async throws -> Bool {
       let count: Int64 = try db.scalar(
           "SELECT COUNT(*) FROM encryption_keys WHERE reference = ? AND layer = ? AND (expires_at IS NULL OR expires_at > datetime('now'))",
           reference, layer.rawValue
       ) ?? 0
       return count > 0
   }
   ```
   Match the exact SQL from the existing implementation — read it first.

2. In `SQLiteEventStoreTests.swift`, remove the unused `@testable import SongbirdTesting` import.

3. In `SQLiteKeyStoreTests.swift`, replace `ISO8601DateFormatter().string(from:)` with `Date(...).formatted(.iso8601)`.

**Verify:** `swift build && swift test --filter SongbirdSQLiteTests`

**Commit:** `git commit -m "Use db.scalar in hasKey, remove unused import, update to ISO8601FormatStyle in tests"`

---

### Task 6: Postgres test parity — readStream round-trip + deleteKey no-op

**Why:** The SQLite tests have `readStreamDataIsDecodable` and `deleteKeyForNonExistentReferenceSucceeds` that the Postgres tests lack. These verify important behavior through the actual database layer.

**Files:**
- Modify: `Tests/SongbirdPostgresTests/PostgresEventStoreTests.swift`
- Modify: `Tests/SongbirdPostgresTests/PostgresKeyStoreTests.swift`

**Changes:**
Read both test files first to understand the patterns (especially `withTestClient` usage).

1. In `PostgresEventStoreTests.swift`, add `readStreamDataIsDecodable`: append an event with full metadata, read it back via `readStream`, decode it, verify data + metadata match.

2. In `PostgresKeyStoreTests.swift`, add `deleteKeyForNonExistentReferenceSucceeds`: call `deleteKey` for a reference that never existed, verify no error.

**Verify:** `swift test --filter SongbirdPostgresTests`

**Commit:** `git commit -m "Add readStream round-trip and deleteKey no-op tests for Postgres stores"`

---

### Task 7: Clean build + full test suite + changelog

**Files:**
- Create: `changelog/0037-code-review-remediation-round11.md`

**Step 1:** `swift build` — clean build, 0 warnings
**Step 2:** `swift test` — all tests pass
**Step 3:** Write changelog summarizing all changes
**Step 4:** Commit: `git commit -m "Add code review remediation round 11 changelog"`

---

## Summary

| Task | Module | Type | Description |
|------|--------|------|-------------|
| 1 | Smew | Safety | Remove unnecessary nonisolated(unsafe) on connection |
| 2 | Postgres | Safety | Add batchSize precondition to PostgresEventSubscription |
| 3 | Distributed | Safety | Resilient shutdown() + double-connect guard |
| 4 | Core | Quality | VersionConflictError Equatable + AnyReaction @Sendable |
| 5 | SQLite | Quality | hasKey db.scalar + unused import + formatter cleanup |
| 6 | Postgres | Test | readStream round-trip + deleteKey no-op parity tests |
| 7 | All | Final | Clean build + full test suite + changelog |
