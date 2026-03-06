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

        await #expect(throws: VersionConflictError.self) {
            try await store.append(
                SecureEvent(name: "Bob", email: "b@b.com", amount: 200),
                to: stream, metadata: EventMetadata(), expectedVersion: 5
            )
        }
    }

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
}
