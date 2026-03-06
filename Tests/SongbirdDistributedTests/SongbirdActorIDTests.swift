import Foundation
import Testing
@testable import SongbirdDistributed

@Suite("SongbirdActorID")
struct SongbirdActorIDTests {
    @Test func createsWithProcessAndActorName() {
        let id = SongbirdActorID(processName: "identity-worker", actorName: "command-handler")
        #expect(id.processName == "identity-worker")
        #expect(id.actorName == "command-handler")
    }

    @Test func description() {
        let id = SongbirdActorID(processName: "catalog-worker", actorName: "handler")
        #expect(id.description == "catalog-worker/handler")
    }

    @Test func hashableEquality() {
        let a = SongbirdActorID(processName: "w1", actorName: "h1")
        let b = SongbirdActorID(processName: "w1", actorName: "h1")
        let c = SongbirdActorID(processName: "w1", actorName: "h2")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func codableRoundTrip() throws {
        let id = SongbirdActorID(processName: "worker", actorName: "handler")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(SongbirdActorID.self, from: data)
        #expect(decoded == id)
    }
}
