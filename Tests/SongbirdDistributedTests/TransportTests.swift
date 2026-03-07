import Foundation
import NIOCore
import Testing
@testable import SongbirdDistributed

/// Handler that receives calls but never responds -- used to test timeouts.
struct SilentHandler: WireMessageHandler {
    func handleMessage(_ message: WireMessage, channel: any Channel) async {
        // Intentionally do nothing
    }
}

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

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)

        do {
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
        } catch {
            try? await client.disconnect()
            try? await server.stop()
            throw error
        }

        try await client.disconnect()
        try await server.stop()
    }

    @Test func multipleCallsInSequence() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
        try await server.start()

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)

        do {
            for i in 0..<5 {
                let data = Data("msg-\(i)".utf8)
                let response = try await client.call(actorName: "a", targetName: "t", arguments: data)
                if case .result(let result) = response {
                    #expect(result.value == data)
                } else {
                    Issue.record("Call \(i) failed")
                }
            }
        } catch {
            try? await client.disconnect()
            try? await server.stop()
            throw error
        }

        try await client.disconnect()
        try await server.stop()
    }

    @Test func callTimesOutWhenServerDoesNotRespond() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: SilentHandler())
        try await server.start()

        let client = TransportClient(callTimeout: .milliseconds(200))
        try await client.connect(socketPath: socketPath)

        await #expect(throws: SongbirdDistributedError.remoteCallFailed("Call timed out")) {
            _ = try await client.call(actorName: "a", targetName: "t", arguments: Data())
        }

        try await client.disconnect()
        try await server.stop()
    }

    @Test func externalCancellationProducesCancellationError() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: SilentHandler())
        try await server.start()

        let client = TransportClient(callTimeout: .seconds(30))  // long timeout so it doesn't fire
        try await client.connect(socketPath: socketPath)

        let task = Task {
            try await client.call(actorName: "a", targetName: "t", arguments: Data())
        }

        // Give the call time to register
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        // External cancellation should produce CancellationError, not a timeout
        do {
            _ = try await task.value
            Issue.record("Expected error")
        } catch is CancellationError {
            // Correct: external cancellation produces CancellationError
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }

        try await client.disconnect()
        try await server.stop()
    }

    @Test func serverCrashResolvesPendingCalls() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: SilentHandler())
        try await server.start()

        let client = TransportClient(callTimeout: .seconds(30))
        try await client.connect(socketPath: socketPath)

        // Start a call that will never get a response
        let task = Task {
            try await client.call(actorName: "a", targetName: "t", arguments: Data())
        }

        // Give the call time to register
        try await Task.sleep(for: .milliseconds(50))

        // Kill the server (simulating a crash)
        try await server.stop()

        // The pending call should resolve with an error (not hang for 30s)
        // Use a timeout to ensure the test doesn't hang
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    _ = try await task.value
                    Issue.record("Expected error from pending call after server crash")
                } catch is SongbirdDistributedError {
                    // Correct: disconnect produces SongbirdDistributedError.notConnected
                } catch {
                    // Any other error is also acceptable -- the key point is it doesn't hang
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                Issue.record("Pending call did not resolve within 5 seconds after server crash")
                throw CancellationError()
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    @Test func disconnectDoesNotHang() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
        try await server.start()

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)

        // Disconnect immediately without any calls
        try await client.disconnect()
        try await server.stop()
    }

    @Test func callBeforeConnectThrowsNotConnected() async throws {
        let client = TransportClient(callTimeout: .seconds(5))

        await #expect(throws: SongbirdDistributedError.notConnected("no connection")) {
            _ = try await client.call(
                actorName: "test",
                targetName: "doSomething",
                arguments: Data()
            )
        }
    }

    @Test func concurrentCallsResolveIndependently() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = TransportServer(socketPath: socketPath, handler: EchoHandler())
        try await server.start()

        let client = TransportClient()
        try await client.connect(socketPath: socketPath)

        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for i in 0..<5 {
                    let data = Data("concurrent-\(i)".utf8)
                    group.addTask {
                        let response = try await client.call(
                            actorName: "a",
                            targetName: "t",
                            arguments: data
                        )
                        guard case .result(let result) = response else {
                            Issue.record("Concurrent call \(i) did not return .result")
                            return (i, Data())
                        }
                        return (i, result.value)
                    }
                }

                var results: [Int: Data] = [:]
                for try await (index, value) in group {
                    results[index] = value
                }

                #expect(results.count == 5)
                for i in 0..<5 {
                    let expected = Data("concurrent-\(i)".utf8)
                    #expect(results[i] == expected)
                }
            }
        } catch {
            try? await client.disconnect()
            try? await server.stop()
            throw error
        }

        try await client.disconnect()
        try await server.stop()
    }
}
