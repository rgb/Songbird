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

@Suite("WireProtocol")
struct WireProtocolTests {
    @Test func callRoundTrip() throws {
        let msg = WireMessage.call(.init(
            requestId: 42,
            actorName: "handler",
            targetName: "greet(name:)",
            arguments: Data("test".utf8)
        ))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        if case .call(let call) = decoded {
            #expect(call.requestId == 42)
            #expect(call.actorName == "handler")
            #expect(call.targetName == "greet(name:)")
        } else {
            Issue.record("Expected .call")
        }
    }

    @Test func resultRoundTrip() throws {
        let msg = WireMessage.result(.init(requestId: 1, value: Data("ok".utf8)))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        if case .result(let result) = decoded {
            #expect(result.requestId == 1)
        } else {
            Issue.record("Expected .result")
        }
    }

    @Test func errorRoundTrip() throws {
        let msg = WireMessage.error(.init(requestId: 1, message: "not found"))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        if case .error(let err) = decoded {
            #expect(err.message == "not found")
        } else {
            Issue.record("Expected .error")
        }
    }
}
