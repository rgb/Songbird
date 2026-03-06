import Foundation
import Testing
@testable import SongbirdDistributed

@Suite("WireProtocol Serialization")
struct WireProtocolSerializationTests {
    @Test("Call message round-trips through JSON")
    func callRoundTrip() throws {
        let call = WireMessage.call(.init(
            requestId: 42,
            actorName: "handler",
            targetName: "doWork",
            arguments: Data("test".utf8)
        ))
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .call(let decodedCall) = decoded else {
            Issue.record("Expected .call")
            return
        }
        #expect(decodedCall.requestId == 42)
        #expect(decodedCall.actorName == "handler")
        #expect(decodedCall.targetName == "doWork")
        #expect(decodedCall.arguments == Data("test".utf8))
    }

    @Test("Result message round-trips through JSON")
    func resultRoundTrip() throws {
        let result = WireMessage.result(.init(requestId: 1, value: Data("ok".utf8)))
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .result(let decodedResult) = decoded else {
            Issue.record("Expected .result")
            return
        }
        #expect(decodedResult.requestId == 1)
        #expect(decodedResult.value == Data("ok".utf8))
    }

    @Test("Error message round-trips through JSON")
    func errorRoundTrip() throws {
        let err = WireMessage.error(.init(requestId: 99, message: "not found"))
        let data = try JSONEncoder().encode(err)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .error(let decodedErr) = decoded else {
            Issue.record("Expected .error")
            return
        }
        #expect(decodedErr.requestId == 99)
        #expect(decodedErr.message == "not found")
    }

    @Test("Malformed JSON throws DecodingError")
    func malformedJSON() throws {
        let badData = Data("{\"type\":\"unknown\",\"payload\":{}}".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WireMessage.self, from: badData)
        }
    }

    @Test("Empty data throws DecodingError")
    func emptyData() throws {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WireMessage.self, from: Data())
        }
    }

    @Test("Call with empty arguments round-trips")
    func emptyArguments() throws {
        let call = WireMessage.call(.init(
            requestId: 0,
            actorName: "",
            targetName: "",
            arguments: Data()
        ))
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .call(let decodedCall) = decoded else {
            Issue.record("Expected .call")
            return
        }
        #expect(decodedCall.arguments == Data())
    }

    @Test("Large arguments round-trip")
    func largeArguments() throws {
        let largeData = Data(repeating: 0xAB, count: 100_000)
        let call = WireMessage.call(.init(
            requestId: 1,
            actorName: "handler",
            targetName: "bigCall",
            arguments: largeData
        ))
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .call(let decodedCall) = decoded else {
            Issue.record("Expected .call")
            return
        }
        #expect(decodedCall.arguments == largeData)
    }
}
