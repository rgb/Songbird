import Distributed
import Foundation
import Testing
@testable import SongbirdDistributed

@Suite("InvocationCodec")
struct InvocationCodecTests {
    @Test func encodesAndDecodesStringArgument() throws {
        var encoder = SongbirdInvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "name", name: "name", value: "Alice"))
        try encoder.doneRecording()

        let data = try encoder.encodeArguments()
        let decoder = try SongbirdInvocationDecoder(data: data)
        let decoded: String = try decoder.decodeNextArgument()
        #expect(decoded == "Alice")
    }

    @Test func encodesAndDecodesMultipleArguments() throws {
        var encoder = SongbirdInvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "name", name: "name", value: "Bob"))
        try encoder.recordArgument(RemoteCallArgument(label: "age", name: "age", value: 42))
        try encoder.doneRecording()

        let data = try encoder.encodeArguments()
        let decoder = try SongbirdInvocationDecoder(data: data)
        let name: String = try decoder.decodeNextArgument()
        let age: Int = try decoder.decodeNextArgument()
        #expect(name == "Bob")
        #expect(age == 42)
    }

    @Test func decoderThrowsOnExtraArgument() throws {
        var encoder = SongbirdInvocationEncoder()
        try encoder.recordArgument(RemoteCallArgument(label: "x", name: "x", value: 1))
        try encoder.doneRecording()

        let data = try encoder.encodeArguments()
        let decoder = try SongbirdInvocationDecoder(data: data)
        let _: Int = try decoder.decodeNextArgument()
        #expect(throws: SongbirdDistributedError.self) {
            let _: Int = try decoder.decodeNextArgument()
        }
    }

    @Test func resultHandlerCapturesReturnValue() async throws {
        let handler = SongbirdResultHandler()
        try await handler.onReturn(value: "hello")
        #expect(handler.isSuccess)
        let decoded = try JSONDecoder().decode(String.self, from: handler.resultData!)
        #expect(decoded == "hello")
    }

    @Test func resultHandlerCapturesVoid() async throws {
        let handler = SongbirdResultHandler()
        try await handler.onReturnVoid()
        #expect(handler.isSuccess)
        #expect(handler.resultData == nil)
    }

    @Test func resultHandlerCapturesError() async throws {
        let handler = SongbirdResultHandler()
        try await handler.onThrow(error: SongbirdDistributedError.actorNotFound(
            SongbirdActorID(processName: "test", actorName: "test")
        ))
        #expect(!handler.isSuccess)
        #expect(handler.errorMessage != nil)
    }
}
