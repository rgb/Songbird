import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres
@testable import SongbirdTesting

extension AllPostgresTests { @Suite("PostgresEventStore Chain Verification") struct ChainVerificationTests {
    let stream = StreamName(category: "account", id: "abc")

    func makeRegistry() -> EventTypeRegistry {
        let registry = EventTypeRegistry()
        registry.register(PGAccountEvent.self, eventTypes: ["Credited", "Debited"])
        return registry
    }

    @Test func hashChainIsIntactAfterAppends() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.debited(amount: 50, note: "fee"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let result = try await store.verifyChain()
            #expect(result.intact == true)
            #expect(result.eventsVerified == 3)
            #expect(result.brokenAtSequence == nil)
        }
    }

    @Test func emptyStoreChainIsIntact() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            let result = try await store.verifyChain()
            #expect(result.intact == true)
            #expect(result.eventsVerified == 0)
        }
    }

    #if DEBUG
    @Test func tamperedEventBreaksChain() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client, registry: makeRegistry())
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            // Tamper with the second event's data
            try await store.rawExecute(
                "UPDATE events SET data = '{\"credited\":{\"amount\":999}}'::jsonb WHERE global_position = 2"
            )

            let result = try await store.verifyChain()
            #expect(result.intact == false)
            #expect(result.eventsVerified == 1)
            #expect(result.brokenAtSequence == 1)
        }
    }
    #endif
}}
