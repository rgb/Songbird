import Foundation
import NIOCore
import Testing
@testable import SongbirdDistributed

/// Echo handler for testing: echoes calls back as results.
struct EchoHandler: WireMessageHandler {
    func handleMessage(_ message: WireMessage, channel: any Channel) async {
        guard case .call(let call) = message else { return }
        let response = WireMessage.result(.init(
            requestId: call.requestId,
            value: call.arguments  // Echo arguments back as the result
        ))
        guard let data = try? JSONEncoder().encode(response) else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer, promise: nil)
    }
}

@Suite("Transport")
struct TransportTests {
    @Test func clientServerRoundTrip() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
        try await server.start()
        defer { Task { try await server.stop() } }

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)
        defer { Task { try await client.disconnect() } }

        let testData = Data("hello".utf8)
        let response = try await client.call(
            actorName: "test",
            targetName: "echo",
            arguments: testData
        )

        if case .result(let result) = response {
            #expect(result.value == testData)
        } else {
            Issue.record("Expected .result, got \(response)")
        }
    }

    @Test func multipleCallsInSequence() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
        try await server.start()
        defer { Task { try await server.stop() } }

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)
        defer { Task { try await client.disconnect() } }

        for i in 0..<5 {
            let data = Data("msg-\(i)".utf8)
            let response = try await client.call(actorName: "a", targetName: "t", arguments: data)
            if case .result(let result) = response {
                #expect(result.value == data)
            } else {
                Issue.record("Call \(i) failed")
            }
        }
    }
}
