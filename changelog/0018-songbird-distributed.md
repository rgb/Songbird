# SongbirdDistributed Module

Adds a new `SongbirdDistributed` module providing cross-process communication for Songbird applications via Swift Distributed Actors over Unix domain sockets.

**Design doc:** `docs/plans/2026-03-05-warbler-distributed-design.md`

## What Changed

### New Module: SongbirdDistributed

Dependencies: `Songbird` + `swift-nio` (NIOCore, NIOPosix)

### New Types

- **`SongbirdActorSystem`** — Custom `DistributedActorSystem` implementation. Workers bind a Unix domain socket and register local distributed actors. Clients connect to worker sockets and call distributed functions transparently.
- **`SongbirdActorID`** — Process-aware actor identity (`processName` + `actorName`). Determines which socket to route calls to.
- **`TransportServer`** — NIO-based Unix domain socket server. Accepts connections and dispatches incoming calls to the actor system.
- **`TransportClient`** — NIO-based Unix domain socket client. Sends calls with continuation-based request/response matching.
- **`SongbirdInvocationEncoder`** — Serializes distributed function arguments as base64-encoded JSON.
- **`SongbirdInvocationDecoder`** — Deserializes arguments in order for `executeDistributedTarget`.
- **`SongbirdResultHandler`** — Captures return values and errors from distributed function invocations.
- **`WireMessage`** — Length-prefixed JSON protocol (Call, Result, Error) for socket communication.

### Prerequisite Fix

- **`SQLiteEventStore.append()`** now uses `BEGIN IMMEDIATE` transaction to prevent TOCTOU race when multiple processes write to the same SQLite file.

## Testing

Unit tests for actor ID, wire protocol, invocation codec. Integration tests for transport layer and full distributed actor calls over real Unix domain sockets.

## Known Limitations

- Unix domain sockets are local-only (no network distribution)
- No service discovery — socket paths configured at startup
- No retry/reconnection logic (MVP)
- No generic distributed function support (concrete Codable types only)

## Files

- `Sources/SongbirdDistributed/SongbirdActorSystem.swift` (new)
- `Sources/SongbirdDistributed/SongbirdActorID.swift` (new)
- `Sources/SongbirdDistributed/Transport.swift` (new)
- `Sources/SongbirdDistributed/WireProtocol.swift` (new)
- `Sources/SongbirdDistributed/InvocationEncoder.swift` (new)
- `Sources/SongbirdDistributed/InvocationDecoder.swift` (new)
- `Sources/SongbirdDistributed/ResultHandler.swift` (new)
- `Sources/SongbirdSQLite/SQLiteEventStore.swift` (modified — BEGIN IMMEDIATE)
- `Tests/SongbirdDistributedTests/*.swift` (new)
