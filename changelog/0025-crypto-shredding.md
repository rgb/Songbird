# 0025 — Crypto Shredding

Field-level crypto shredding for GDPR-compliant event erasure. Sensitive fields are encrypted with per-entity keys; destroying a key makes those fields permanently unrecoverable while the hash chain stays intact.

## What Changed

### Core Types (Songbird module)

- **`Shreddable<T>`** — Enum wrapping field values as `.value(T)` or `.shredded`. Encodes as the raw value; `null` decodes as `.shredded`. Includes `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`, `ExpressibleByFloatLiteral`, and `ExpressibleByBooleanLiteral` conformances.

- **`FieldProtection`** — Enum with three cases: `.pii` (per-entity key, manual shred), `.retention(Duration)` (time-limited key), `.piiAndRetention(Duration)` (both layers, double-encrypted).

- **`CryptoShreddable`** — Protocol for events declaring field protection via `static var fieldProtection: [String: FieldProtection]`.

- **`EventMetadata.piiReferenceKey`** — New optional field auto-populated with the entity ID during append.

- **`KeyStore`** protocol — `key(for:layer:)`, `existingKey(for:layer:)`, `deleteKey(for:layer:)`, `hasKey(for:layer:)` using CryptoKit `SymmetricKey`. `KeyLayer` enum: `.pii`, `.retention`.

- **`CryptoShreddableRegistry`** — Maps event type strings to their `FieldProtection` dictionaries for the read path.

- **`CryptoShreddingStore<Inner: EventStore>`** — Decorator wrapping any `EventStore`. Encrypts PII fields on append (AES-256-GCM), decrypts on read. Missing keys produce `.shredded` values. `forget(entity:)` deletes the PII key.

- **`JSONValue`** / **`EncryptedPayload`** — Internal types for field-level JSON manipulation with sorted-key encoding for hash determinism.

### Concrete KeyStore Implementations

- **`InMemoryKeyStore`** (SongbirdTesting) — Actor-based dictionary implementation for unit tests.
- **`SQLiteKeyStore`** (SongbirdSQLite) — Keys in SQLite `encryption_keys` table.
- **`PostgresKeyStore`** (SongbirdPostgres) — Keys in Postgres `encryption_keys` table. New migration added.

## Encrypted Field Format

```json
{
  "name": "enc:pii+ret:base64...",
  "email": "enc:pii:base64...",
  "amount": 2300
}
```

## Hash Chain

The inner EventStore hashes the partially-encrypted JSON. After key deletion, stored ciphertext is unchanged — hash chain verification always works regardless of key availability.

## Files Added

- `Sources/Songbird/Shreddable.swift`
- `Sources/Songbird/CryptoShreddable.swift`
- `Sources/Songbird/KeyStore.swift`
- `Sources/Songbird/CryptoShreddableRegistry.swift`
- `Sources/Songbird/JSONValue.swift`
- `Sources/Songbird/CryptoShreddingStore.swift`
- `Sources/SongbirdTesting/InMemoryKeyStore.swift`
- `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- `Sources/SongbirdPostgres/PostgresKeyStore.swift`
- `Tests/SongbirdTests/ShreddableTests.swift`
- `Tests/SongbirdTests/CryptoShreddableTests.swift`
- `Tests/SongbirdTests/InMemoryKeyStoreTests.swift`
- `Tests/SongbirdTests/CryptoShreddableRegistryTests.swift`
- `Tests/SongbirdTests/JSONValueTests.swift`
- `Tests/SongbirdTests/CryptoShreddingStoreTests.swift`
- `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`
- `Tests/SongbirdPostgresTests/PostgresKeyStoreTests.swift`

## Files Modified

- `Sources/Songbird/Event.swift` — Added `piiReferenceKey` to `EventMetadata`
- `Sources/SongbirdPostgres/PostgresMigrations.swift` — Added `CreateEncryptionKeysTable` migration
- `Tests/SongbirdPostgresTests/PostgresTestHelper.swift` — Added `encryption_keys` to `cleanTables`

## Test Coverage

- 13 tests for `Shreddable<T>` (encoding, decoding, literals, equality, struct integration)
- 5 tests for `CryptoShreddable` and `FieldProtection`
- 10 tests for `InMemoryKeyStore`
- 3 tests for `CryptoShreddableRegistry`
- 8 tests for `JSONValue` and `EncryptedPayload`
- 13 tests for `CryptoShreddingStore` (append, read, shredding, mixed streams)
- 6 tests for `SQLiteKeyStore`
- 6 tests for `PostgresKeyStore`
