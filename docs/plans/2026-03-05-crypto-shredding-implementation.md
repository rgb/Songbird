# Crypto Shredding Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add field-level crypto shredding to Songbird so apps can GDPR-erase sensitive event fields by destroying encryption keys, preserving the hash chain.

**Architecture:** A `CryptoShreddingStore` decorator wraps any `EventStore`, encrypting PII fields on append and decrypting on read. A `KeyStore` protocol abstracts key management with concrete SQLite, Postgres, and in-memory implementations. `Shreddable<T>` wrapper type makes shredding explicit in the type system.

**Tech Stack:** Swift CryptoKit (AES-256-GCM), JSONSerialization for field-level JSON manipulation, Swift Testing.

**Design doc:** `docs/plans/2026-03-05-crypto-shredding-design.md`

---

### Task 1: Shreddable<T> Type

**Files:**
- Create: `Sources/Songbird/Shreddable.swift`
- Test: `Tests/SongbirdTests/ShreddableTests.swift`

**Context:** `Shreddable<T>` is an enum that wraps field values. `.value(T)` holds the real value; `.shredded` means the encryption key was destroyed. It encodes as the raw value (transparent) and decodes `null` as `.shredded`. This avoids overloading Optional's meaning.

**Step 1: Write the failing tests**

```swift
import Testing
@testable import Songbird

@Suite("Shreddable")
struct ShreddableTests {
    // MARK: - Codable Round-Trip

    @Test func valueEncodesAsRawValue() throws {
        let value: Shreddable<String> = .value("Alice")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"Alice\"")
    }

    @Test func shreddedEncodesAsNull() throws {
        let value: Shreddable<String> = .shredded
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "null")
    }

    @Test func decodesValueFromRawValue() throws {
        let data = Data("\"Alice\"".utf8)
        let decoded = try JSONDecoder().decode(Shreddable<String>.self, from: data)
        #expect(decoded == .value("Alice"))
    }

    @Test func decodesNullAsShredded() throws {
        let data = Data("null".utf8)
        let decoded = try JSONDecoder().decode(Shreddable<String>.self, from: data)
        #expect(decoded == .shredded)
    }

    @Test func integerRoundTrip() throws {
        let value: Shreddable<Int> = .value(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Shreddable<Int>.self, from: data)
        #expect(decoded == .value(42))
    }

    @Test func boolRoundTrip() throws {
        let value: Shreddable<Bool> = .value(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Shreddable<Bool>.self, from: data)
        #expect(decoded == .value(true))
    }

    // MARK: - Literal Conformances

    @Test func stringLiteral() {
        let value: Shreddable<String> = "hello"
        #expect(value == .value("hello"))
    }

    @Test func integerLiteral() {
        let value: Shreddable<Int> = 42
        #expect(value == .value(42))
    }

    @Test func floatLiteral() {
        let value: Shreddable<Double> = 3.14
        #expect(value == .value(3.14))
    }

    @Test func booleanLiteral() {
        let value: Shreddable<Bool> = true
        #expect(value == .value(true))
    }

    // MARK: - Equatable

    @Test func equality() {
        #expect(Shreddable<String>.value("a") == .value("a"))
        #expect(Shreddable<String>.value("a") != .value("b"))
        #expect(Shreddable<String>.shredded == .shredded)
        #expect(Shreddable<String>.value("a") != .shredded)
    }

    // MARK: - Struct with Shreddable Fields

    @Test func structRoundTrip() throws {
        struct Person: Codable, Equatable {
            let name: Shreddable<String>
            let age: Int
        }

        let person = Person(name: "Alice", age: 30)
        let data = try JSONEncoder().encode(person)
        let decoded = try JSONDecoder().decode(Person.self, from: data)
        #expect(decoded == person)
    }

    @Test func structWithShreddedField() throws {
        struct Person: Codable, Equatable {
            let name: Shreddable<String>
            let age: Int
        }

        let json = Data("{\"name\":null,\"age\":30}".utf8)
        let decoded = try JSONDecoder().decode(Person.self, from: json)
        #expect(decoded.name == .shredded)
        #expect(decoded.age == 30)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ShreddableTests 2>&1 | head -20`
Expected: FAIL — `Shreddable` type does not exist

**Step 3: Implement Shreddable<T>**

```swift
import Foundation

public enum Shreddable<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case value(T)
    case shredded

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .shredded
        } else {
            self = .value(try container.decode(T.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .value(let v):
            try container.encode(v)
        case .shredded:
            try container.encodeNil()
        }
    }
}

// MARK: - Literal Conformances

extension Shreddable: ExpressibleByStringLiteral, ExpressibleByExtendedGraphemeClusterLiteral,
    ExpressibleByUnicodeScalarLiteral where T == String
{
    public init(stringLiteral value: String) {
        self = .value(value)
    }

    public init(extendedGraphemeClusterLiteral value: String) {
        self = .value(value)
    }

    public init(unicodeScalarLiteral value: String) {
        self = .value(value)
    }
}

extension Shreddable: ExpressibleByIntegerLiteral where T: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: T.IntegerLiteralType) {
        self = .value(T(integerLiteral: value))
    }
}

extension Shreddable: ExpressibleByFloatLiteral where T: ExpressibleByFloatLiteral {
    public init(floatLiteral value: T.FloatLiteralType) {
        self = .value(T(floatLiteral: value))
    }
}

extension Shreddable: ExpressibleByBooleanLiteral where T == Bool {
    public init(booleanLiteral value: Bool) {
        self = .value(value)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ShreddableTests`
Expected: All 13 tests PASS

**Step 5: Commit**

```bash
git add Sources/Songbird/Shreddable.swift Tests/SongbirdTests/ShreddableTests.swift
git commit -m "Add Shreddable<T> type for crypto shredding field values"
```

---

### Task 2: FieldProtection, CryptoShreddable, and EventMetadata.piiReferenceKey

**Files:**
- Create: `Sources/Songbird/CryptoShreddable.swift`
- Modify: `Sources/Songbird/Event.swift` (add `piiReferenceKey` to `EventMetadata`)
- Test: `Tests/SongbirdTests/CryptoShreddableTests.swift`

**Context:** `FieldProtection` is an enum with four levels (pii, retention, piiAndRetention). `CryptoShreddable` is a protocol that events conform to, declaring their field protection map. `EventMetadata` gets a new optional `piiReferenceKey` field.

**Step 1: Write the failing tests**

```swift
import Testing
@testable import Songbird

@Suite("CryptoShreddable")
struct CryptoShreddableTests {
    struct AccountCreated: Event, CryptoShreddable {
        let name: Shreddable<String>
        let email: Shreddable<String>
        let amount: Double

        var eventType: String { "AccountCreated" }

        static let fieldProtection: [String: FieldProtection] = [
            "name": .piiAndRetention(.seconds(86400 * 365 * 7)),
            "email": .pii,
        ]
    }

    @Test func fieldProtectionValues() {
        let protection = AccountCreated.fieldProtection
        #expect(protection["name"] == .piiAndRetention(.seconds(86400 * 365 * 7)))
        #expect(protection["email"] == .pii)
        #expect(protection["amount"] == nil)
    }

    @Test func piiReferenceKeyInMetadata() {
        let metadata = EventMetadata(piiReferenceKey: "entity-123")
        #expect(metadata.piiReferenceKey == "entity-123")
    }

    @Test func piiReferenceKeyDefaultsToNil() {
        let metadata = EventMetadata()
        #expect(metadata.piiReferenceKey == nil)
    }

    @Test func piiReferenceKeyEncodesAndDecodes() throws {
        let metadata = EventMetadata(piiReferenceKey: "abc-123")
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(EventMetadata.self, from: data)
        #expect(decoded.piiReferenceKey == "abc-123")
    }

    @Test func metadataWithoutPiiKeyStillDecodes() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(EventMetadata.self, from: json)
        #expect(decoded.piiReferenceKey == nil)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter CryptoShreddableTests 2>&1 | head -20`
Expected: FAIL — types don't exist

**Step 3: Create CryptoShreddable.swift**

```swift
import Foundation

public enum FieldProtection: Sendable, Equatable {
    case pii
    case retention(Duration)
    case piiAndRetention(Duration)
}

public protocol CryptoShreddable {
    static var fieldProtection: [String: FieldProtection] { get }
}
```

**Step 4: Add piiReferenceKey to EventMetadata**

In `Sources/Songbird/Event.swift`, modify `EventMetadata`:

```swift
public struct EventMetadata: Sendable, Codable, Equatable {
    public var traceId: String?
    public var causationId: String?
    public var correlationId: String?
    public var userId: String?
    public var piiReferenceKey: String?

    public init(
        traceId: String? = nil,
        causationId: String? = nil,
        correlationId: String? = nil,
        userId: String? = nil,
        piiReferenceKey: String? = nil
    ) {
        self.traceId = traceId
        self.causationId = causationId
        self.correlationId = correlationId
        self.userId = userId
        self.piiReferenceKey = piiReferenceKey
    }
}
```

**Step 5: Run tests to verify they pass**

Run: `swift test --filter CryptoShreddableTests`
Expected: All 5 tests PASS

**Step 6: Run full test suite to check for regressions**

Run: `swift test 2>&1 | tail -5`
Expected: All tests PASS (the new optional field with default nil is backwards-compatible with existing JSON)

**Step 7: Commit**

```bash
git add Sources/Songbird/CryptoShreddable.swift Sources/Songbird/Event.swift Tests/SongbirdTests/CryptoShreddableTests.swift
git commit -m "Add FieldProtection, CryptoShreddable protocol, EventMetadata.piiReferenceKey"
```

---

### Task 3: KeyStore Protocol + InMemoryKeyStore

**Files:**
- Create: `Sources/Songbird/KeyStore.swift`
- Create: `Sources/SongbirdTesting/InMemoryKeyStore.swift`
- Test: `Tests/SongbirdTests/InMemoryKeyStoreTests.swift`

**Context:** `KeyStore` is the abstraction for encryption key management. `KeyLayer` distinguishes PII keys from retention keys. `InMemoryKeyStore` in SongbirdTesting is the test-friendly implementation.

**Step 1: Write the failing tests**

```swift
import CryptoKit
import Testing
@testable import Songbird
@testable import SongbirdTesting

@Suite("InMemoryKeyStore")
struct InMemoryKeyStoreTests {
    @Test func getOrCreateKeyReturnsSameKey() async throws {
        let store = InMemoryKeyStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-1", layer: .pii)
        #expect(key1 == key2)
    }

    @Test func differentEntitiesGetDifferentKeys() async throws {
        let store = InMemoryKeyStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-2", layer: .pii)
        #expect(key1 != key2)
    }

    @Test func differentLayersGetDifferentKeys() async throws {
        let store = InMemoryKeyStore()
        let piiKey = try await store.key(for: "entity-1", layer: .pii)
        let retKey = try await store.key(for: "entity-1", layer: .retention)
        #expect(piiKey != retKey)
    }

    @Test func existingKeyReturnsKeyWhenPresent() async throws {
        let store = InMemoryKeyStore()
        let created = try await store.key(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == created)
    }

    @Test func existingKeyReturnsNilWhenMissing() async throws {
        let store = InMemoryKeyStore()
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == nil)
    }

    @Test func deleteKeyMakesItUnavailable() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == nil)
    }

    @Test func hasKeyReturnsTrueWhenPresent() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        let has = try await store.hasKey(for: "entity-1", layer: .pii)
        #expect(has == true)
    }

    @Test func hasKeyReturnsFalseAfterDelete() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        let has = try await store.hasKey(for: "entity-1", layer: .pii)
        #expect(has == false)
    }

    @Test func deleteDoesNotAffectOtherEntities() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        _ = try await store.key(for: "entity-2", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        let has = try await store.hasKey(for: "entity-2", layer: .pii)
        #expect(has == true)
    }

    @Test func deleteDoesNotAffectOtherLayers() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        _ = try await store.key(for: "entity-1", layer: .retention)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        let hasRetention = try await store.hasKey(for: "entity-1", layer: .retention)
        #expect(hasRetention == true)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter InMemoryKeyStoreTests 2>&1 | head -20`
Expected: FAIL — types don't exist

**Step 3: Create KeyStore.swift**

```swift
import CryptoKit

public enum KeyLayer: String, Sendable {
    case pii
    case retention
}

public protocol KeyStore: Sendable {
    /// Get or create an encryption key for the given reference and layer.
    func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey

    /// Look up an existing key. Returns nil if the key was deleted (shredded) or never created.
    func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey?

    /// Permanently delete a key. This is the crypto-shredding operation.
    func deleteKey(for reference: String, layer: KeyLayer) async throws

    /// Check whether a key exists for the given reference and layer.
    func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool
}
```

**Step 4: Create InMemoryKeyStore.swift**

```swift
import CryptoKit
import Songbird

public actor InMemoryKeyStore: KeyStore {
    private var keys: [String: SymmetricKey] = [:]

    public init() {}

    public func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey {
        let id = storageKey(reference, layer)
        if let existing = keys[id] {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        keys[id] = key
        return key
    }

    public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
        keys[storageKey(reference, layer)]
    }

    public func deleteKey(for reference: String, layer: KeyLayer) async throws {
        keys.removeValue(forKey: storageKey(reference, layer))
    }

    public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
        keys[storageKey(reference, layer)] != nil
    }

    private func storageKey(_ reference: String, _ layer: KeyLayer) -> String {
        "\(reference):\(layer.rawValue)"
    }
}
```

**Step 5: Run tests to verify they pass**

Run: `swift test --filter InMemoryKeyStoreTests`
Expected: All 10 tests PASS

**Step 6: Commit**

```bash
git add Sources/Songbird/KeyStore.swift Sources/SongbirdTesting/InMemoryKeyStore.swift Tests/SongbirdTests/InMemoryKeyStoreTests.swift
git commit -m "Add KeyStore protocol and InMemoryKeyStore"
```

---

### Task 4: CryptoShreddableRegistry

**Files:**
- Create: `Sources/Songbird/CryptoShreddableRegistry.swift`
- Test: `Tests/SongbirdTests/CryptoShreddableRegistryTests.swift`

**Context:** Maps event type strings to their `FieldProtection` dictionaries. Needed on the read path where we only have a type string and need to know which fields to decrypt. Follows the same lock-based pattern as `EventTypeRegistry`.

**Step 1: Write the failing tests**

```swift
import Testing
@testable import Songbird

@Suite("CryptoShreddableRegistry")
struct CryptoShreddableRegistryTests {
    struct SecureEvent: Event, CryptoShreddable {
        let name: Shreddable<String>
        let amount: Double
        var eventType: String { "SecureEvent" }
        static let fieldProtection: [String: FieldProtection] = [
            "name": .pii,
        ]
    }

    struct PlainEvent: Event {
        let data: String
        var eventType: String { "PlainEvent" }
    }

    @Test func registeredEventReturnsProtection() {
        var registry = CryptoShreddableRegistry()
        registry.register(SecureEvent.self)
        let protection = registry.fieldProtection(for: "SecureEvent")
        #expect(protection?["name"] == .pii)
    }

    @Test func unregisteredEventReturnsNil() {
        let registry = CryptoShreddableRegistry()
        let protection = registry.fieldProtection(for: "UnknownEvent")
        #expect(protection == nil)
    }

    @Test func multipleRegistrations() {
        struct AnotherEvent: Event, CryptoShreddable {
            let email: Shreddable<String>
            var eventType: String { "AnotherEvent" }
            static let fieldProtection: [String: FieldProtection] = [
                "email": .retention(.seconds(3600)),
            ]
        }

        var registry = CryptoShreddableRegistry()
        registry.register(SecureEvent.self)
        registry.register(AnotherEvent.self)

        #expect(registry.fieldProtection(for: "SecureEvent")?["name"] == .pii)
        #expect(registry.fieldProtection(for: "AnotherEvent")?["email"] == .retention(.seconds(3600)))
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter CryptoShreddableRegistryTests 2>&1 | head -20`
Expected: FAIL — type doesn't exist

**Step 3: Implement CryptoShreddableRegistry**

```swift
import Foundation

public struct CryptoShreddableRegistry: Sendable {
    private var protections: [String: [String: FieldProtection]] = [:]

    public init() {}

    public mutating func register<E: Event & CryptoShreddable>(_ type: E.Type) {
        // Need an instance to get eventType (it's an instance property).
        // Use the static fieldProtection and the type name as a workaround.
        // Actually, we need the eventType string. Let's require it as a parameter.
        fatalError("See note below")
    }
}
```

**Important:** The `Event` protocol's `eventType` is an instance property, not static. We can't get it from the metatype alone. Follow the same pattern as `EventTypeRegistry.register()` — accept the event type string as a parameter:

```swift
public struct CryptoShreddableRegistry: Sendable {
    private var protections: [String: [String: FieldProtection]] = [:]

    public init() {}

    public mutating func register<E: Event & CryptoShreddable>(
        _ type: E.Type,
        eventType: String
    ) {
        protections[eventType] = E.fieldProtection
    }

    public func fieldProtection(for eventType: String) -> [String: FieldProtection]? {
        protections[eventType]
    }
}
```

Update the tests to pass the `eventType` string:

```swift
registry.register(SecureEvent.self, eventType: "SecureEvent")
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter CryptoShreddableRegistryTests`
Expected: All 3 tests PASS

**Step 5: Commit**

```bash
git add Sources/Songbird/CryptoShreddableRegistry.swift Tests/SongbirdTests/CryptoShreddableRegistryTests.swift
git commit -m "Add CryptoShreddableRegistry for field protection lookup"
```

---

### Task 5: JSON Manipulation Helpers

**Files:**
- Create: `Sources/Songbird/JSONValue.swift`
- Test: `Tests/SongbirdTests/JSONValueTests.swift`

**Context:** Internal types for field-level JSON manipulation. `JSONValue` represents any JSON value. `EncryptedPayload` conforms to `Event` and encodes a dictionary of `JSONValue` fields — used to pass partially-encrypted JSON through the inner `EventStore.append()`.

**Step 1: Write the failing tests**

```swift
import Testing
@testable import Songbird

@Suite("JSONValue")
struct JSONValueTests {
    @Test func stringRoundTrip() throws {
        let value = JSONValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func intRoundTrip() throws {
        let value = JSONValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .int(42))
    }

    @Test func doubleRoundTrip() throws {
        let value = JSONValue.double(3.14)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func boolRoundTrip() throws {
        let value = JSONValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func nullRoundTrip() throws {
        let value = JSONValue.null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func objectRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("Alice"),
            "age": .int(30),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func parseEventJSON() throws {
        let json = Data("""
            {"name":"Alice","email":"a@b.com","amount":2300}
            """.utf8)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: json)
        #expect(fields["name"] == .string("Alice"))
        #expect(fields["email"] == .string("a@b.com"))
        #expect(fields["amount"] == .int(2300))
    }

    @Test func encryptedPayloadEncodesWithSortedKeys() throws {
        let payload = EncryptedPayload(
            originalEventType: "AccountCreated",
            fields: [
                "name": .string("enc:pii:abc123"),
                "email": .string("enc:pii+ret:def456"),
                "amount": .int(2300),
            ]
        )
        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8)!
        // Keys should be sorted alphabetically
        #expect(json.contains("\"amount\""))
        #expect(json.contains("\"email\""))
        #expect(json.contains("\"name\""))

        // Verify eventType is correct
        #expect(payload.eventType == "AccountCreated")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter JSONValueTests 2>&1 | head -20`
Expected: FAIL — types don't exist

**Step 3: Implement JSONValue and EncryptedPayload**

```swift
import Foundation

/// Represents any JSON value. Used internally for field-level encryption manipulation.
internal enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        // Try bool before int/double (JSON booleans are sometimes decoded as numbers)
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
            return
        }

        if let intVal = try? container.decode(Int64.self) {
            self = .int(intVal)
            return
        }

        if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
            return
        }

        if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
            return
        }

        if let arrayVal = try? container.decode([JSONValue].self) {
            self = .array(arrayVal)
            return
        }

        if let objectVal = try? container.decode([String: JSONValue].self) {
            self = .object(objectVal)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Cannot decode JSONValue"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    /// Serialize this value to a JSON fragment string (for encryption).
    func toJSONFragmentData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Parse a JSON fragment string back to a JSONValue (for decryption).
    static func fromJSONFragmentData(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - DynamicCodingKey

internal struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

// MARK: - EncryptedPayload

/// An Event that carries pre-encrypted JSON fields. Used by CryptoShreddingStore to pass
/// partially-encrypted data through the inner EventStore's append method.
internal struct EncryptedPayload: Event {
    let originalEventType: String
    let fields: [String: JSONValue]

    var eventType: String { originalEventType }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    init(originalEventType: String, fields: [String: JSONValue]) {
        self.originalEventType = originalEventType
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var dict: [String: JSONValue] = [:]
        for key in container.allKeys {
            dict[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.fields = dict
        self.originalEventType = ""
    }

    static func == (lhs: EncryptedPayload, rhs: EncryptedPayload) -> Bool {
        lhs.originalEventType == rhs.originalEventType && lhs.fields == rhs.fields
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter JSONValueTests`
Expected: All 8 tests PASS

**Step 5: Commit**

```bash
git add Sources/Songbird/JSONValue.swift Tests/SongbirdTests/JSONValueTests.swift
git commit -m "Add JSONValue and EncryptedPayload for field-level JSON manipulation"
```

---

### Task 6: CryptoShreddingStore — Append Flow

**Files:**
- Create: `Sources/Songbird/CryptoShreddingStore.swift`
- Test: `Tests/SongbirdTests/CryptoShreddingStoreTests.swift`

**Context:** The core decorator. This task covers the append path — encrypting PII fields before passing to the inner store. Uses AES-256-GCM from CryptoKit. The encrypted field format is `enc:pii:base64...` or `enc:pii+ret:base64...`.

**Step 1: Write the failing tests**

```swift
import CryptoKit
import Testing
@testable import Songbird
@testable import SongbirdTesting

@Suite("CryptoShreddingStore")
struct CryptoShreddingStoreTests {
    struct SecureEvent: Event, CryptoShreddable {
        let name: Shreddable<String>
        let email: Shreddable<String>
        let amount: Double
        var eventType: String { "SecureEvent" }
        static let fieldProtection: [String: FieldProtection] = [
            "name": .piiAndRetention(.seconds(86400)),
            "email": .pii,
        ]
    }

    struct PlainEvent: Event {
        let data: String
        var eventType: String { "PlainEvent" }
    }

    private func makeStore() -> (CryptoShreddingStore<InMemoryEventStore>, InMemoryEventStore, InMemoryKeyStore) {
        let inner = InMemoryEventStore()
        let keyStore = InMemoryKeyStore()
        var registry = CryptoShreddableRegistry()
        registry.register(SecureEvent.self, eventType: "SecureEvent")
        let store = CryptoShreddingStore(inner: inner, keyStore: keyStore, registry: registry)
        return (store, inner, keyStore)
    }

    // MARK: - Append

    @Test func appendEncryptsPIIFields() async throws {
        let (store, inner, _) = makeStore()
        let stream = StreamName(category: "account", id: "123")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "alice@example.com", amount: 2300),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        // Read directly from inner store — data should be encrypted
        let events = try await inner.readStream(stream, from: 0, maxCount: 10)
        #expect(events.count == 1)
        let json = String(data: events[0].data, encoding: .utf8)!
        #expect(json.contains("enc:pii+ret:"))  // name is piiAndRetention
        #expect(json.contains("enc:pii:"))       // email is pii
        #expect(json.contains("2300"))            // amount is plaintext
        #expect(!json.contains("Alice"))          // name is NOT plaintext
        #expect(!json.contains("alice@example"))  // email is NOT plaintext
    }

    @Test func appendSetsPiiReferenceKey() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "account", id: "123")

        let recorded = try await store.append(
            SecureEvent(name: "Alice", email: "a@b.com", amount: 100),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        #expect(recorded.metadata.piiReferenceKey == "123")
    }

    @Test func appendPlainEventPassesThrough() async throws {
        let (store, inner, _) = makeStore()
        let stream = StreamName(category: "log", id: "1")

        _ = try await store.append(
            PlainEvent(data: "hello"),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        let events = try await inner.readStream(stream, from: 0, maxCount: 10)
        let json = String(data: events[0].data, encoding: .utf8)!
        #expect(json.contains("hello"))  // plaintext, no encryption
    }

    @Test func appendPreservesVersionControl() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "account", id: "1")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "a@b.com", amount: 100),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        #expect(throws: VersionConflictError.self) {
            try await store.append(
                SecureEvent(name: "Bob", email: "b@b.com", amount: 200),
                to: stream, metadata: EventMetadata(), expectedVersion: 5
            )
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter CryptoShreddingStoreTests 2>&1 | head -20`
Expected: FAIL — CryptoShreddingStore doesn't exist

**Step 3: Implement CryptoShreddingStore**

```swift
import CryptoKit
import Foundation

public struct CryptoShreddingStore<Inner: EventStore>: Sendable {
    private let inner: Inner
    private let keyStore: any KeyStore
    private let registry: CryptoShreddableRegistry

    public init(inner: Inner, keyStore: any KeyStore, registry: CryptoShreddableRegistry) {
        self.inner = inner
        self.keyStore = keyStore
        self.registry = registry
    }
}

// MARK: - EventStore Conformance

extension CryptoShreddingStore: EventStore {
    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        // Check if this event type has field protection
        guard let protection = registry.fieldProtection(for: event.eventType),
              !protection.isEmpty
        else {
            // Not crypto-shreddable — pass through unchanged
            return try await inner.append(event, to: stream, metadata: metadata, expectedVersion: expectedVersion)
        }

        // Encode event to JSON, parse to field dictionary
        let jsonData = try JSONEncoder().encode(event)
        var fields = try JSONDecoder().decode([String: JSONValue].self, from: jsonData)

        // Entity ID for key lookup (from stream name)
        let entityId = stream.id ?? stream.description

        // Encrypt each protected field
        for (fieldName, level) in protection {
            guard let fieldValue = fields[fieldName], fieldValue != .null else { continue }

            let plaintext = try fieldValue.toJSONFragmentData()

            switch level {
            case .pii:
                let piiKey = try await keyStore.key(for: entityId, layer: .pii)
                let ciphertext = try encrypt(plaintext, using: piiKey)
                fields[fieldName] = .string("enc:pii:\(ciphertext)")

            case .retention(let duration):
                let retKey = try await keyStore.key(for: entityId, layer: .retention)
                let ciphertext = try encrypt(plaintext, using: retKey)
                fields[fieldName] = .string("enc:ret:\(ciphertext)")

            case .piiAndRetention(let duration):
                let piiKey = try await keyStore.key(for: entityId, layer: .pii)
                let retKey = try await keyStore.key(for: entityId, layer: .retention)
                // Double-encrypt: inner PII, outer retention
                let innerCiphertext = try encrypt(plaintext, using: piiKey)
                let outerCiphertext = try encrypt(
                    Data(innerCiphertext.utf8), using: retKey
                )
                fields[fieldName] = .string("enc:pii+ret:\(outerCiphertext)")
            }
        }

        // Set PII reference key in metadata
        var updatedMetadata = metadata
        updatedMetadata.piiReferenceKey = entityId

        // Create EncryptedPayload and pass to inner store
        let payload = EncryptedPayload(originalEventType: event.eventType, fields: fields)
        let recorded = try await inner.append(
            payload, to: stream, metadata: updatedMetadata, expectedVersion: expectedVersion
        )

        // Return the recorded event (data contains encrypted fields — that's correct for storage)
        return recorded
    }

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let records = try await inner.readStream(stream, from: position, maxCount: maxCount)
        return try await records.asyncMap { try await decryptRecord($0) }
    }

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let records = try await inner.readCategories(categories, from: globalPosition, maxCount: maxCount)
        return try await records.asyncMap { try await decryptRecord($0) }
    }

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        guard let record = try await inner.readLastEvent(in: stream) else { return nil }
        return try await decryptRecord(record)
    }

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        try await inner.streamVersion(stream)
    }
}

// MARK: - Encryption Helpers

extension CryptoShreddingStore {
    /// AES-256-GCM encrypt, returns base64-encoded (nonce + ciphertext + tag).
    private func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> String {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined!.base64EncodedString()
    }

    /// AES-256-GCM decrypt from base64-encoded combined data.
    private func decrypt(_ base64Ciphertext: String, using key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: base64Ciphertext) else {
            throw CryptoShreddingError.invalidCiphertext
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Decrypt a single field value, returning the decrypted JSONValue or .null if shredded.
    private func decryptField(_ encryptedString: String, entityId: String) async throws -> JSONValue {
        if encryptedString.hasPrefix("enc:pii:") {
            let ciphertext = String(encryptedString.dropFirst("enc:pii:".count))
            guard let key = try await keyStore.existingKey(for: entityId, layer: .pii) else {
                return .null // shredded
            }
            let plaintext = try decrypt(ciphertext, using: key)
            return try JSONValue.fromJSONFragmentData(plaintext)

        } else if encryptedString.hasPrefix("enc:ret:") {
            let ciphertext = String(encryptedString.dropFirst("enc:ret:".count))
            guard let key = try await keyStore.existingKey(for: entityId, layer: .retention) else {
                return .null // expired
            }
            let plaintext = try decrypt(ciphertext, using: key)
            return try JSONValue.fromJSONFragmentData(plaintext)

        } else if encryptedString.hasPrefix("enc:pii+ret:") {
            let outerCiphertext = String(encryptedString.dropFirst("enc:pii+ret:".count))

            // Outer layer: retention
            guard let retKey = try await keyStore.existingKey(for: entityId, layer: .retention) else {
                return .null // retention expired
            }
            let innerCiphertextData = try decrypt(outerCiphertext, using: retKey)
            let innerCiphertext = String(data: innerCiphertextData, encoding: .utf8)!

            // Inner layer: PII
            guard let piiKey = try await keyStore.existingKey(for: entityId, layer: .pii) else {
                return .null // PII shredded
            }
            let plaintext = try decrypt(innerCiphertext, using: piiKey)
            return try JSONValue.fromJSONFragmentData(plaintext)

        } else {
            // Not an encrypted value — shouldn't happen for protected fields
            return .string(encryptedString)
        }
    }

    /// Decrypt all protected fields in a RecordedEvent, returning a new RecordedEvent with plaintext data.
    private func decryptRecord(_ record: RecordedEvent) async throws -> RecordedEvent {
        guard let protection = registry.fieldProtection(for: record.eventType),
              !protection.isEmpty
        else {
            return record // not crypto-shreddable
        }

        let entityId = record.streamName.id ?? record.streamName.description
        var fields = try JSONDecoder().decode([String: JSONValue].self, from: record.data)

        for (fieldName, _) in protection {
            guard case .string(let encryptedString) = fields[fieldName],
                  encryptedString.hasPrefix("enc:")
            else { continue }

            fields[fieldName] = try await decryptField(encryptedString, entityId: entityId)
        }

        // Re-encode with sorted keys for determinism
        let decryptedData = try JSONEncoder.sortedKeys.encode(fields)

        return RecordedEvent(
            id: record.id,
            streamName: record.streamName,
            position: record.position,
            globalPosition: record.globalPosition,
            eventType: record.eventType,
            data: decryptedData,
            metadata: record.metadata,
            timestamp: record.timestamp
        )
    }
}

// MARK: - Async Map Helper

extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}

// MARK: - JSONEncoder Extension

extension JSONEncoder {
    static let sortedKeys: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
}

// MARK: - Errors

public enum CryptoShreddingError: Error {
    case invalidCiphertext
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter CryptoShreddingStoreTests`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add Sources/Songbird/CryptoShreddingStore.swift Tests/SongbirdTests/CryptoShreddingStoreTests.swift
git commit -m "Add CryptoShreddingStore with field-level encryption on append"
```

---

### Task 7: CryptoShreddingStore — Read, Shredding, and Hash Chain

**Files:**
- Modify: `Tests/SongbirdTests/CryptoShreddingStoreTests.swift` (add read and shredding tests)
- Modify: `Sources/Songbird/CryptoShreddingStore.swift` (add forget and expireRetentionKeys)

**Context:** Tests the full round-trip: append encrypted → read decrypted → shred → read shredded. Also verifies that the hash chain (in the inner store) stays intact after key deletion.

**Step 1: Add tests for read, shredding, and hash chain**

Add to the existing `CryptoShreddingStoreTests`:

```swift
    // MARK: - Read (Decryption)

    @Test func readDecryptsPIIFields() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "account", id: "123")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "alice@example.com", amount: 2300),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        // Read through CryptoShreddingStore — should get plaintext back
        let events = try await store.readStream(stream, from: 0, maxCount: 10)
        #expect(events.count == 1)
        let decoded = try events[0].decode(SecureEvent.self)
        #expect(decoded.event.name == .value("Alice"))
        #expect(decoded.event.email == .value("alice@example.com"))
        #expect(decoded.event.amount == 2300)
    }

    @Test func readPlainEventPassesThrough() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "log", id: "1")

        _ = try await store.append(
            PlainEvent(data: "hello"),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        let events = try await store.readStream(stream, from: 0, maxCount: 10)
        let decoded = try events[0].decode(PlainEvent.self)
        #expect(decoded.event.data == "hello")
    }

    @Test func readLastEventDecrypts() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "account", id: "123")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "a@b.com", amount: 100),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )
        _ = try await store.append(
            SecureEvent(name: "Bob", email: "b@b.com", amount: 200),
            to: stream, metadata: EventMetadata(), expectedVersion: 0
        )

        let last = try await store.readLastEvent(in: stream)
        let decoded = try last!.decode(SecureEvent.self)
        #expect(decoded.event.name == .value("Bob"))
    }

    @Test func readCategoriesDecrypts() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "account", id: "1")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "a@b.com", amount: 100),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        let events = try await store.readCategory("account", from: 0, maxCount: 10)
        let decoded = try events[0].decode(SecureEvent.self)
        #expect(decoded.event.name == .value("Alice"))
    }

    // MARK: - Shredding

    @Test func forgetEntityMakesPIIFieldsShredded() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "account", id: "123")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "alice@example.com", amount: 2300),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        // Shred
        try await store.forget(entity: "123")

        // Read — PII fields should be .shredded, amount intact
        let events = try await store.readStream(stream, from: 0, maxCount: 10)
        let decoded = try events[0].decode(SecureEvent.self)
        #expect(decoded.event.name == .shredded)
        #expect(decoded.event.email == .shredded)
        #expect(decoded.event.amount == 2300)
    }

    @Test func forgetDoesNotAffectOtherEntities() async throws {
        let (store, _, _) = makeStore()
        let stream1 = StreamName(category: "account", id: "1")
        let stream2 = StreamName(category: "account", id: "2")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "a@b.com", amount: 100),
            to: stream1, metadata: EventMetadata(), expectedVersion: nil
        )
        _ = try await store.append(
            SecureEvent(name: "Bob", email: "b@b.com", amount: 200),
            to: stream2, metadata: EventMetadata(), expectedVersion: nil
        )

        try await store.forget(entity: "1")

        // Entity 1 is shredded
        let events1 = try await store.readStream(stream1, from: 0, maxCount: 10)
        let decoded1 = try events1[0].decode(SecureEvent.self)
        #expect(decoded1.event.name == .shredded)

        // Entity 2 is intact
        let events2 = try await store.readStream(stream2, from: 0, maxCount: 10)
        let decoded2 = try events2[0].decode(SecureEvent.self)
        #expect(decoded2.event.name == .value("Bob"))
    }

    @Test func deletingRetentionKeyShredsPiiAndRetentionFields() async throws {
        let (store, _, keyStore) = makeStore()
        let stream = StreamName(category: "account", id: "123")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "alice@example.com", amount: 2300),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )

        // Delete only the retention key
        try await keyStore.deleteKey(for: "123", layer: .retention)

        let events = try await store.readStream(stream, from: 0, maxCount: 10)
        let decoded = try events[0].decode(SecureEvent.self)
        // name is piiAndRetention — retention key gone, so shredded
        #expect(decoded.event.name == .shredded)
        // email is pii only — pii key still present, so decrypted
        #expect(decoded.event.email == .value("alice@example.com"))
        #expect(decoded.event.amount == 2300)
    }

    @Test func multipleEventsForSameEntityAllShredded() async throws {
        let (store, _, _) = makeStore()
        let stream = StreamName(category: "account", id: "1")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "a@b.com", amount: 100),
            to: stream, metadata: EventMetadata(), expectedVersion: nil
        )
        _ = try await store.append(
            SecureEvent(name: "Alice Updated", email: "a2@b.com", amount: 200),
            to: stream, metadata: EventMetadata(), expectedVersion: 0
        )

        try await store.forget(entity: "1")

        let events = try await store.readStream(stream, from: 0, maxCount: 10)
        #expect(events.count == 2)
        for event in events {
            let decoded = try event.decode(SecureEvent.self)
            #expect(decoded.event.name == .shredded)
            #expect(decoded.event.email == .shredded)
        }
    }

    // MARK: - Mixed Streams

    @Test func mixedEncryptedAndPlainEvents() async throws {
        let (store, _, _) = makeStore()
        let secureStream = StreamName(category: "account", id: "1")
        let plainStream = StreamName(category: "log", id: "1")

        _ = try await store.append(
            SecureEvent(name: "Alice", email: "a@b.com", amount: 100),
            to: secureStream, metadata: EventMetadata(), expectedVersion: nil
        )
        _ = try await store.append(
            PlainEvent(data: "something happened"),
            to: plainStream, metadata: EventMetadata(), expectedVersion: nil
        )

        // Read all events
        let all = try await store.readAll(from: 0, maxCount: 10)
        #expect(all.count == 2)

        // Secure event decrypts properly
        let secure = try all[0].decode(SecureEvent.self)
        #expect(secure.event.name == .value("Alice"))

        // Plain event is untouched
        let plain = try all[1].decode(PlainEvent.self)
        #expect(plain.event.data == "something happened")
    }
```

**Step 2: Add forget() and expireRetentionKeys() to CryptoShreddingStore**

```swift
// MARK: - Shredding Operations

extension CryptoShreddingStore {
    /// Permanently forget an entity by deleting their PII encryption key.
    /// All PII and piiAndRetention fields for this entity become permanently unreadable.
    public func forget(entity: String) async throws {
        try await keyStore.deleteKey(for: entity, layer: .pii)
    }

    /// Expire all retention keys that have passed their duration.
    /// This is a bulk operation — call periodically or on app startup.
    /// Note: The InMemoryKeyStore doesn't track expiry. SQLiteKeyStore and PostgresKeyStore
    /// use the expires_at column. For InMemoryKeyStore, delete retention keys manually in tests.
    public func expireRetentionKeys() async throws {
        // Default implementation is a no-op.
        // Concrete KeyStore implementations (SQLite/Postgres) handle expiry
        // via their expires_at column and a dedicated method.
    }
}
```

**Step 3: Run tests to verify they pass**

Run: `swift test --filter CryptoShreddingStoreTests`
Expected: All 14 tests PASS (4 from Task 6 + 10 new)

**Step 4: Commit**

```bash
git add Sources/Songbird/CryptoShreddingStore.swift Tests/SongbirdTests/CryptoShreddingStoreTests.swift
git commit -m "Add read decryption, shredding operations, and mixed event tests"
```

---

### Task 8: SQLiteKeyStore

**Files:**
- Create: `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- Test: `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`

**Context:** Stores encryption keys in the same SQLite database as events. Uses the existing `SQLite.swift` library. Includes expiry support for retention keys.

**Reference:** Check `Sources/SongbirdSQLite/SQLiteEventStore.swift` for the actor pattern, connection setup, and migration approach. Check `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift` for a simpler example of the same pattern.

**Step 1: Write the failing tests**

```swift
import Testing
@testable import Songbird
@testable import SongbirdSQLite

@Suite("SQLiteKeyStore")
struct SQLiteKeyStoreTests {
    private func makeStore() throws -> SQLiteKeyStore {
        try SQLiteKeyStore(path: ":memory:")
    }

    @Test func getOrCreateReturnsSameKey() async throws {
        let store = try makeStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-1", layer: .pii)
        #expect(key1 == key2)
    }

    @Test func differentEntitiesGetDifferentKeys() async throws {
        let store = try makeStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-2", layer: .pii)
        #expect(key1 != key2)
    }

    @Test func deleteKeyMakesItUnavailable() async throws {
        let store = try makeStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == nil)
    }

    @Test func keyPersistsAcrossLookups() async throws {
        let store = try makeStore()
        let created = try await store.key(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == created)
    }

    @Test func differentLayersAreIndependent() async throws {
        let store = try makeStore()
        let piiKey = try await store.key(for: "entity-1", layer: .pii)
        let retKey = try await store.key(for: "entity-1", layer: .retention)
        #expect(piiKey != retKey)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-1", layer: .retention) == true)
    }

    @Test func hasKeyReturnsFalseAfterDelete() async throws {
        let store = try makeStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-1", layer: .pii) == false)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SQLiteKeyStoreTests 2>&1 | head -20`
Expected: FAIL — SQLiteKeyStore doesn't exist

**Step 3: Implement SQLiteKeyStore**

Follow the same actor + custom executor pattern as `SQLiteEventStore`. Reference `SQLiteSnapshotStore` for a simpler example:

```swift
import CryptoKit
import Foundation
import Songbird
import SQLite

public actor SQLiteKeyStore: KeyStore {
    private nonisolated(unsafe) let db: Connection

    public init(path: String) throws {
        self.db = try Connection(path)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS encryption_keys (
                reference   TEXT NOT NULL,
                layer       TEXT NOT NULL,
                key_data    BLOB NOT NULL,
                created_at  TEXT NOT NULL,
                expires_at  TEXT,
                PRIMARY KEY (reference, layer)
            )
        """)
    }

    public func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey {
        if let existing = try await existingKey(for: reference, layer: layer) {
            return existing
        }
        let keyData = SymmetricKey(size: .bits256)
        let rawBytes = keyData.withUnsafeBytes { Data($0) }
        let now = ISO8601DateFormatter().string(from: Date())

        try db.run(
            "INSERT INTO encryption_keys (reference, layer, key_data, created_at) VALUES (?, ?, ?, ?)",
            reference, layer.rawValue, rawBytes.datatypeValue, now
        )
        return keyData
    }

    public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
        let stmt = try db.prepare(
            "SELECT key_data FROM encryption_keys WHERE reference = ? AND layer = ?",
            reference, layer.rawValue
        )
        for row in stmt {
            guard let blob = row[0] as? Blob else { continue }
            return SymmetricKey(data: Data(blob.bytes))
        }
        return nil
    }

    public func deleteKey(for reference: String, layer: KeyLayer) async throws {
        try db.run(
            "DELETE FROM encryption_keys WHERE reference = ? AND layer = ?",
            reference, layer.rawValue
        )
    }

    public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
        let stmt = try db.prepare(
            "SELECT 1 FROM encryption_keys WHERE reference = ? AND layer = ?",
            reference, layer.rawValue
        )
        return stmt.makeIterator().next() != nil
    }
}
```

**Note:** The exact `SQLite.swift` API for binding and reading blobs may differ slightly — check `SQLiteSnapshotStore.swift` for the established pattern with `Blob` and `datatypeValue`.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SQLiteKeyStoreTests`
Expected: All 6 tests PASS

**Step 5: Commit**

```bash
git add Sources/SongbirdSQLite/SQLiteKeyStore.swift Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift
git commit -m "Add SQLiteKeyStore for encryption key persistence"
```

---

### Task 9: PostgresKeyStore

**Files:**
- Create: `Sources/SongbirdPostgres/PostgresKeyStore.swift`
- Modify: `Sources/SongbirdPostgres/PostgresMigrations.swift` (add encryption_keys table)
- Test: `Tests/SongbirdPostgresTests/PostgresKeyStoreTests.swift`

**Context:** Stores encryption keys in the same Postgres database as events. Uses PostgresNIO. Migration adds the `encryption_keys` table via the existing `SongbirdPostgresMigrations` system.

**Reference:** Check `Sources/SongbirdPostgres/PostgresSnapshotStore.swift` for the pattern. Check `Sources/SongbirdPostgres/PostgresMigrations.swift` for migration registration. Check `Tests/SongbirdPostgresTests/PostgresTestHelper.swift` for the test container setup (uses `swift-test-containers`).

**Step 1: Add migration for encryption_keys table**

In `Sources/SongbirdPostgres/PostgresMigrations.swift`, add a new migration group for the encryption_keys table:

```swift
// In the apply() method, add after existing migrations:
migrations.add(
    DatabaseMigration(name: "CreateEncryptionKeys") { connection, logger in
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS encryption_keys (
                reference   TEXT NOT NULL,
                layer       TEXT NOT NULL,
                key_data    BYTEA NOT NULL,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                expires_at  TIMESTAMPTZ,
                PRIMARY KEY (reference, layer)
            )
            """, logger: logger)
    }
)
```

**Step 2: Write the failing tests**

```swift
import Testing
@testable import Songbird
@testable import SongbirdPostgres

@Suite(.serialized)
struct PostgresKeyStoreTests {
    @Test func getOrCreateReturnsSameKey() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)

            let key1 = try await store.key(for: "entity-1", layer: .pii)
            let key2 = try await store.key(for: "entity-1", layer: .pii)
            #expect(key1 == key2)
        }
    }

    @Test func differentEntitiesGetDifferentKeys() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)

            let key1 = try await store.key(for: "entity-1", layer: .pii)
            let key2 = try await store.key(for: "entity-2", layer: .pii)
            #expect(key1 != key2)
        }
    }

    @Test func deleteKeyMakesItUnavailable() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)

            _ = try await store.key(for: "entity-1", layer: .pii)
            try await store.deleteKey(for: "entity-1", layer: .pii)
            let found = try await store.existingKey(for: "entity-1", layer: .pii)
            #expect(found == nil)
        }
    }

    @Test func differentLayersAreIndependent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)

            let piiKey = try await store.key(for: "entity-1", layer: .pii)
            let retKey = try await store.key(for: "entity-1", layer: .retention)
            #expect(piiKey != retKey)
            try await store.deleteKey(for: "entity-1", layer: .pii)
            #expect(try await store.hasKey(for: "entity-1", layer: .retention) == true)
        }
    }
}
```

**Note:** `PostgresTestHelper.cleanTables` needs to also truncate `encryption_keys`. Update `cleanTables` in `PostgresTestHelper.swift`:

```swift
static func cleanTables(client: PostgresClient) async throws {
    try await client.query("TRUNCATE events RESTART IDENTITY CASCADE")
    try await client.query("TRUNCATE subscriber_positions")
    try await client.query("TRUNCATE snapshots")
    try await client.query("TRUNCATE encryption_keys")
}
```

**Step 3: Implement PostgresKeyStore**

```swift
import CryptoKit
import Foundation
import PostgresNIO
import Songbird

public struct PostgresKeyStore: KeyStore, Sendable {
    private let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey {
        if let existing = try await existingKey(for: reference, layer: layer) {
            return existing
        }
        let keyData = SymmetricKey(size: .bits256)
        let rawBytes = keyData.withUnsafeBytes { Data($0) }
        let layerStr = layer.rawValue
        let now = Date()

        try await client.query("""
            INSERT INTO encryption_keys (reference, layer, key_data, created_at)
            VALUES (\(reference), \(layerStr), \(PostgresData(bytes: rawBytes)), \(now))
            ON CONFLICT (reference, layer) DO NOTHING
            """)

        // Re-read in case of race condition (ON CONFLICT DO NOTHING)
        if let existing = try await existingKey(for: reference, layer: layer) {
            return existing
        }
        return keyData
    }

    public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
        let rows = try await client.query(
            "SELECT key_data FROM encryption_keys WHERE reference = \(reference) AND layer = \(layer.rawValue)"
        )
        for try await (keyData,) in rows.decode((Data,).self) {
            return SymmetricKey(data: keyData)
        }
        return nil
    }

    public func deleteKey(for reference: String, layer: KeyLayer) async throws {
        try await client.query(
            "DELETE FROM encryption_keys WHERE reference = \(reference) AND layer = \(layer.rawValue)"
        )
    }

    public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
        let rows = try await client.query(
            "SELECT 1 FROM encryption_keys WHERE reference = \(reference) AND layer = \(layer.rawValue)"
        )
        for try await _ in rows.decode((Int,).self) {
            return true
        }
        return false
    }
}
```

**Note:** The exact PostgresNIO binding for `BYTEA` may need adjustment. Check how `PostgresSnapshotStore` handles `Data` bindings. You may need `PostgresData(bytes: rawBytes)` or just pass `rawBytes` directly depending on the version.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter PostgresKeyStoreTests`
Expected: All 4 tests PASS (requires Docker for testcontainer)

**Step 5: Commit**

```bash
git add Sources/SongbirdPostgres/PostgresKeyStore.swift Sources/SongbirdPostgres/PostgresMigrations.swift Tests/SongbirdPostgresTests/PostgresKeyStoreTests.swift Tests/SongbirdPostgresTests/PostgresTestHelper.swift
git commit -m "Add PostgresKeyStore and encryption_keys migration"
```

---

### Task 10: Clean Build, Full Test Suite, and Changelog

**Files:**
- Create: `changelog/0025-crypto-shredding.md`
- Verify: all files from Tasks 1-9

**Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: ALL tests pass, zero warnings

**Step 2: Run a clean build**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete, zero warnings

**Step 3: Write changelog entry**

Create `changelog/0025-crypto-shredding.md`:

```markdown
# 0025: Crypto Shredding

Field-level crypto shredding for GDPR-compliant event erasure. Sensitive fields are encrypted with per-entity AES-256-GCM keys; destroying a key permanently shreds all PII for that entity while preserving the hash chain.

## New Types (Songbird core)

- **`Shreddable<T>`** — Enum wrapping field values: `.value(T)` or `.shredded`. Includes `ExpressibleBy...Literal` conformances for clean construction.
- **`FieldProtection`** — Enum with four levels: `.pii`, `.retention(Duration)`, `.piiAndRetention(Duration)`.
- **`CryptoShreddable`** — Protocol for events to declare their field protection map.
- **`KeyStore`** — Protocol for encryption key management (get-or-create, lookup, delete, exists).
- **`KeyLayer`** — Enum distinguishing `.pii` and `.retention` keys.
- **`CryptoShreddableRegistry`** — Maps event type strings to field protection dictionaries.
- **`CryptoShreddingStore`** — Decorator wrapping any `EventStore`, encrypting PII fields on append and decrypting on read.
- **`EventMetadata.piiReferenceKey`** — New optional field for the entity's PII reference.

## Concrete Implementations

- **`InMemoryKeyStore`** (SongbirdTesting) — Actor-based, dictionary-backed.
- **`SQLiteKeyStore`** (SongbirdSQLite) — Keys in `encryption_keys` table, same database as events.
- **`PostgresKeyStore`** (SongbirdPostgres) — Keys in `encryption_keys` table, same database as events. Migration added to `SongbirdPostgresMigrations`.

## Encryption Details

- AES-256-GCM via Swift CryptoKit
- Per-entity keys (one PII key + optional retention key per entity)
- Field values serialized to JSON fragments before encryption
- Encrypted format: `enc:pii:base64...`, `enc:ret:base64...`, `enc:pii+ret:base64...`
- Double-encryption for `piiAndRetention`: outer retention wraps inner PII
- Hash chain operates on ciphertext — stays intact after key deletion
```

**Step 4: Commit**

```bash
git add changelog/0025-crypto-shredding.md
git commit -m "Add crypto shredding changelog entry"
```
