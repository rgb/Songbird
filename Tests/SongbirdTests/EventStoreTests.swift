import Testing

@testable import Songbird
import SongbirdTesting

@Suite("VersionConflictError")
struct VersionConflictErrorTests {
    @Test func containsConflictDetails() {
        let error = VersionConflictError(
            streamName: StreamName(category: "order", id: "123"),
            expectedVersion: 3,
            actualVersion: 5
        )
        #expect(error.streamName == StreamName(category: "order", id: "123"))
        #expect(error.expectedVersion == 3)
        #expect(error.actualVersion == 5)
    }

    @Test func hasReadableDescription() {
        let error = VersionConflictError(
            streamName: StreamName(category: "order", id: "123"),
            expectedVersion: 3,
            actualVersion: 5
        )
        let desc = String(describing: error)
        #expect(desc.contains("order-123"))
        #expect(desc.contains("3"))
        #expect(desc.contains("5"))
    }
}

@Suite("EventStore protocol")
struct EventStoreProtocolTests {
    @Test func protocolIsUsableAsExistential() async throws {
        let store: any EventStore = InMemoryEventStore()
        let version = try await store.streamVersion(StreamName(category: "test"))
        #expect(version == -1)
    }
}
