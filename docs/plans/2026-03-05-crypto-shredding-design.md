# Crypto Shredding Design

## Overview

Field-level crypto shredding for Songbird, enabling GDPR-compliant event erasure without breaking the hash chain. Events remain in the append-only log, but sensitive fields become permanently unrecoverable when encryption keys are deleted.

Follows Hoffman's multi-level approach (Chapter 8, Real-World Event Sourcing) with two encryption layers, adapted for Songbird's framework architecture.

**Name:** Crypto Shredding

**Scope:** New types in `Songbird` core, decorator `EventStore` wrapper, `KeyStore` protocol with SQLite and Postgres implementations, `InMemoryKeyStore` in `SongbirdTesting`.

## Encryption Granularity

Field-level encryption — only sensitive fields are encrypted. Non-PII fields remain readable after shredding, preserving analytical value. Events declare which fields are protected via a `CryptoShreddable` protocol.

### Two Layers

**Layer 1 — PII reference encryption:** Per-entity key, deleted on explicit "forget me" request. Handles GDPR Article 17 erasure.

**Layer 2 — Retention period encryption:** Time-limited key, auto-expires after a configurable duration. Handles automatic data retention policies.

Fields can have either layer independently, or both (double-encrypted).

## Core Types

### FieldProtection

```swift
public enum FieldProtection: Sendable {
    case pii                            // Layer 1: per-entity key, manual shred
    case retention(Duration)            // Layer 2: time-limited key, auto-expire
    case piiAndRetention(Duration)      // Both layers (outer retention wraps inner PII)
}
```

### CryptoShreddable Protocol

Events opt in to field-level encryption by conforming:

```swift
public protocol CryptoShreddable {
    static var fieldProtection: [String: FieldProtection] { get }
}
```

Only events conforming to `CryptoShreddable` get encrypted. Non-conforming events pass through untouched.

### Shreddable<T> Wrapper

Represents a field value that may have been crypto-shredded:

```swift
public enum Shreddable<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case value(T)
    case shredded
}
```

PII fields use `Shreddable<T>` instead of bare types. This makes shredding explicit in the type system — no confusion with Optional nil values.

Includes `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`, `ExpressibleByFloatLiteral`, and `ExpressibleByBooleanLiteral` conformances where `T` conforms, so event construction stays clean:

```swift
struct AccountCreated: Event, CryptoShreddable {
    let name: Shreddable<String>        // .value("Alice") or .shredded
    let email: Shreddable<String>
    let amount: Double                  // always present, not PII

    static let fieldProtection: [String: FieldProtection] = [
        "name": .piiAndRetention(.seconds(86400 * 365 * 7)),
        "email": .pii,
    ]
}

// Construction with literals:
let event = AccountCreated(name: "Alice", email: "alice@example.com", amount: 2300)

// After shredding:
event.name   // .shredded
event.email  // .shredded
event.amount // 2300
```

### PII Reference Key

Stored in `EventMetadata` as a new optional field:

```swift
public struct EventMetadata {
    // ... existing fields ...
    public var piiReferenceKey: String?
}
```

The framework auto-populates this during append based on the stream's entity ID.

## KeyStore Protocol

```swift
public protocol KeyStore: Sendable {
    /// Get or create an encryption key for the given reference.
    func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey

    /// Look up an existing key (returns nil if shredded/expired).
    func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey?

    /// Delete a key permanently (crypto-shred).
    func deleteKey(for reference: String, layer: KeyLayer) async throws

    /// Check if a key exists.
    func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool
}

public enum KeyLayer: Sendable {
    case pii
    case retention
}
```

**Key references** are opaque strings. For PII keys, the reference is typically the entity ID from the stream name. For retention keys, it's the entity ID combined with a retention period identifier.

### Key Schema

```sql
CREATE TABLE encryption_keys (
    reference   TEXT NOT NULL,
    layer       TEXT NOT NULL,  -- 'pii' or 'retention'
    key_data    BLOB NOT NULL,  -- 32 bytes, AES-256
    created_at  TEXT NOT NULL,
    expires_at  TEXT,           -- NULL for PII keys, set for retention keys
    PRIMARY KEY (reference, layer)
);
```

Retention keys get an `expires_at` timestamp computed from the `Duration` in `FieldProtection`. The framework checks expiry on read — if expired, treats as shredded and deletes the key lazily. No background service needed.

### Encryption Algorithm

AES-256-GCM via Swift CryptoKit. Authenticated encryption — tampering with ciphertext is detectable. Same algorithm as ether's implementation.

### Concrete Implementations

- `SQLiteKeyStore` — keys in the same SQLite database as events (atomic consistency)
- `PostgresKeyStore` — keys in the same Postgres database as events
- `InMemoryKeyStore` — dictionary-based, for unit tests (in `SongbirdTesting`)

Apps can implement `KeyStore` for external vaults (HashiCorp Vault, AWS KMS, etc.).

## CryptoShreddingStore (Decorator)

Wraps any `EventStore`, handles encryption transparently:

```swift
public struct CryptoShreddingStore<Inner: EventStore>: Sendable {
    private let inner: Inner
    private let keyStore: any KeyStore
    private let registry: CryptoShreddableRegistry

    public init(inner: Inner, keyStore: any KeyStore, registry: CryptoShreddableRegistry)
}
```

Conforms to `EventStore` — all reads/writes pass through it. The `EventStore` protocol itself is unchanged.

### CryptoShreddableRegistry

Maps event type strings to their `FieldProtection` dictionaries. Needed because when reading, we have a type string and need to know which fields to decrypt:

```swift
public struct CryptoShreddableRegistry: Sendable {
    public mutating func register<E: Event & CryptoShreddable>(_ type: E.Type)
    func fieldProtection(for eventType: String) -> [String: FieldProtection]?
}
```

### Append Flow

1. Encode event to JSON
2. Look up `fieldProtection` for the event type
3. For each protected field: get-or-create key(s) from KeyStore, encrypt the field value
4. Replace plaintext field values with prefixed ciphertext strings in the JSON
5. Store PII reference key in metadata
6. Pass modified data to `inner.append()` — the inner store hashes the partially-encrypted JSON

### Read Flow

1. Get `RecordedEvent` from inner store
2. Look up `fieldProtection` for the event type
3. For each protected field: look up key(s) from KeyStore
4. Key present → decrypt, replace ciphertext with plaintext value
5. Key missing (shredded/expired) → replace with `null` in JSON (decodes as `.shredded`)
6. If retention key expired, lazily delete it

### Shredding Operations

Additional methods on `CryptoShreddingStore` (not on `EventStore` protocol):

```swift
extension CryptoShreddingStore {
    /// Permanently forget an entity — delete their PII key.
    public func forget(entity: String) async throws

    /// Expire retention keys that have passed their duration.
    public func expireRetentionKeys() async throws
}
```

## Encrypted Field Format

Each encrypted field value is replaced with a prefixed string:

```json
{
  "name": "enc:pii+ret:aGVsbG8gd29ybGQ=...",
  "email": "enc:pii:dGhpcyBpcyBl...",
  "amount": 2300
}
```

The prefix (`enc:pii:` or `enc:pii+ret:`) identifies which layers are applied, followed by base64-encoded AES-256-GCM ciphertext (nonce + ciphertext + tag).

For `piiAndRetention`, the value is double-encrypted: `retention_encrypt(pii_encrypt(plaintext))`.

Any field type (String, Int, nested object) is serialized to its JSON representation first, then encrypted into this string format. On decryption, the framework reverses: strip prefix → base64 decode → AES-GCM open → parse original JSON value → insert back into the JSON.

## Hash Chain Integration

The hash chain operates on whatever is stored. Since `CryptoShreddingStore` encrypts fields *before* passing to the inner store, the inner store computes hashes over the partially-encrypted JSON:

- Hash input: `previousHash + eventType + streamName + partiallyEncryptedJSON + timestamp`
- After shredding (key deleted), the stored ciphertext is unchanged — hash remains valid
- `verifyChain()` always works, regardless of key availability

No changes needed to `SQLiteEventStore` or `PostgresEventStore` hash chain logic. The decorator is invisible to the inner store.

**JSON determinism:** When manipulating JSON (encrypting on write, decrypting on read), the decorator must preserve field ordering and use consistent serialization to avoid hash mismatches.

## Testing

**`InMemoryKeyStore`** in `SongbirdTesting` — dictionary-based implementation for unit tests.

**Test coverage:**
- `Shreddable<T>` encoding/decoding round-trips (value and shredded cases, literal conformances)
- Key lifecycle (create, retrieve, delete, expired)
- Field-level encryption round-trip (append with PII → read back plaintext)
- Shredding semantics (delete key → read returns `.shredded` for PII fields, non-PII intact)
- Retention expiry (key auto-expires after duration, fields become `.shredded`)
- Double-encryption (`piiAndRetention` — both keys needed, either deletion shreds)
- Hash chain intact after shredding
- Non-`CryptoShreddable` events pass through untouched
- Mixed streams (some events shreddable, some not)

## Key Differences from Ether

| Aspect | Ether | Songbird |
|--------|-------|----------|
| Granularity | Whole-event | Field-level |
| Layers | 1 (PII only) | 2 (PII + retention) |
| Key storage | SQLite only | Protocol (SQLite, Postgres, external) |
| Shredded representation | Events return nil (skipped) | `Shreddable<T>.shredded` (non-PII preserved) |
| Architecture | Built into EventStore actor | Decorator wrapping any EventStore |
| Hash chain input | Full ciphertext | Partially-encrypted JSON |

## Key Differences from Hoffman

| Aspect | Hoffman | Songbird |
|--------|---------|----------|
| PII field marking | JSON Schema / protobuf metadata | `CryptoShreddable` protocol with `fieldProtection` map |
| Key reference | CloudEvents extension header | `EventMetadata.piiReferenceKey` |
| Key storage | External vault (HashiCorp Vault) | Protocol with concrete SQLite/Postgres + pluggable external |
| Shredded representation | Not specified | `Shreddable<T>` enum |
| Retention expiry | Not detailed | Lazy expiry on read + explicit `expireRetentionKeys()` |
