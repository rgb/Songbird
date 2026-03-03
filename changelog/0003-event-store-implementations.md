# 0003 — EventStore Implementations

Implemented Phase 2 of Songbird:

- **EventTypeRegistry** — Thread-safe registry mapping eventType strings to decoders (core module)
- **InMemoryEventStore** — Actor-based in-memory EventStore for testing (SongbirdTesting module)
- **SQLiteEventStore** — SQLite-backed EventStore with WAL mode, SHA-256 hash chaining, optimistic concurrency, and version-tracked migrations (SongbirdSQLite module)
- **ChainVerificationResult** — Result type for hash chain integrity verification

New modules added: SongbirdTesting, SongbirdSQLite.
New dependency: SQLite.swift 0.15.3.

72 tests across 15 suites, all passing, zero warnings.
