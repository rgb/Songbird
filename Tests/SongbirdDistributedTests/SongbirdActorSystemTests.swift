import Distributed
import Foundation
import Testing
@testable import SongbirdDistributed

// A simple distributed actor for testing
distributed actor Greeter {
    typealias ActorSystem = SongbirdActorSystem

    distributed func greet(name: String) -> String {
        "Hello, \(name)!"
    }

    distributed func add(a: Int, b: Int) -> Int {
        a + b
    }

    distributed func ping() {
        // void-returning: exercises remoteCallVoid
    }

    distributed func failIfEmpty(name: String) throws -> String {
        guard !name.isEmpty else {
            throw GreeterError.nameIsEmpty
        }
        return "Hello, \(name)!"
    }
}

enum GreeterError: Error, CustomStringConvertible {
    case nameIsEmpty

    var description: String {
        switch self {
        case .nameIsEmpty: "Name must not be empty"
        }
    }
}

@Suite("SongbirdActorSystem")
struct SongbirdActorSystemTests {
    @Test func localActorCallWorks() async throws {
        let system = SongbirdActorSystem(processName: "test")
        let greeter = Greeter(actorSystem: system)
        let result = try await greeter.greet(name: "World")
        #expect(result == "Hello, World!")
    }

    @Test func remoteActorCallOverSocket() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        // Worker side
        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)

        let greeter = Greeter(actorSystem: workerSystem)

        // Client side
        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)

        do {
            // Resolve using the greeter's actual auto-assigned actor name
            let remoteId = SongbirdActorID(processName: "worker", actorName: greeter.id.actorName)
            let remoteGreeter = try Greeter.resolve(id: remoteId, using: clientSystem)
            let result = try await remoteGreeter.greet(name: "Alice")
            #expect(result == "Hello, Alice!")
        } catch {
            try? await clientSystem.shutdown()
            try? await workerSystem.shutdown()
            throw error
        }

        try await clientSystem.shutdown()
        try await workerSystem.shutdown()
    }

    @Test func multipleArgumentsWork() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)

        let greeter = Greeter(actorSystem: workerSystem)

        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)

        do {
            let remote = try Greeter.resolve(
                id: SongbirdActorID(processName: "worker", actorName: greeter.id.actorName),
                using: clientSystem
            )
            let result = try await remote.add(a: 3, b: 4)
            #expect(result == 7)
        } catch {
            try? await clientSystem.shutdown()
            try? await workerSystem.shutdown()
            throw error
        }

        try await clientSystem.shutdown()
        try await workerSystem.shutdown()
    }

    @Test func unresolvedActorThrowsError() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)

        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)

        do {
            let fakeId = SongbirdActorID(processName: "worker", actorName: "nonexistent")
            let remote = try Greeter.resolve(id: fakeId, using: clientSystem)

            await #expect {
                _ = try await remote.greet(name: "Fail")
            } throws: { error in
                guard let distributed = error as? SongbirdDistributedError,
                      case .remoteCallFailed = distributed else {
                    return false
                }
                return true
            }
        } catch {
            try? await clientSystem.shutdown()
            try? await workerSystem.shutdown()
            throw error
        }

        try await clientSystem.shutdown()
        try await workerSystem.shutdown()
    }

    @Test func assignIDAutoIncrements() async throws {
        let system = SongbirdActorSystem(processName: "test")
        let id1 = system.assignID(Greeter.self)
        let id2 = system.assignID(Greeter.self)
        #expect(id1.actorName == "auto-0")
        #expect(id2.actorName == "auto-1")
        #expect(id1.processName == "test")
    }

    @Test func resignIDRemovesActor() async throws {
        let system = SongbirdActorSystem(processName: "test")
        let greeter = Greeter(actorSystem: system)
        let id = greeter.id

        // After resignation, resolving should return nil
        system.resignID(id)
        let afterResign = try system.resolve(id: id, as: Greeter.self)
        #expect(afterResign == nil)
    }

    @Test func voidReturningRemoteCallWorks() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)

        let greeter = Greeter(actorSystem: workerSystem)

        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)

        do {
            let remote = try Greeter.resolve(
                id: SongbirdActorID(processName: "worker", actorName: greeter.id.actorName),
                using: clientSystem
            )
            // This exercises remoteCallVoid end-to-end
            try await remote.ping()
        } catch {
            try? await clientSystem.shutdown()
            try? await workerSystem.shutdown()
            throw error
        }

        try await clientSystem.shutdown()
        try await workerSystem.shutdown()
    }

    @Test func throwingRemoteCallReturnsError() async throws {
        let socketPath = "/tmp/songbird-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let workerSystem = SongbirdActorSystem(processName: "worker")
        try await workerSystem.startServer(socketPath: socketPath)

        let greeter = Greeter(actorSystem: workerSystem)

        let clientSystem = SongbirdActorSystem(processName: "gateway")
        try await clientSystem.connect(processName: "worker", socketPath: socketPath)

        do {
            let remote = try Greeter.resolve(
                id: SongbirdActorID(processName: "worker", actorName: greeter.id.actorName),
                using: clientSystem
            )

            // Calling with an empty name should trigger the error wire path
            await #expect {
                _ = try await remote.failIfEmpty(name: "")
            } throws: { error in
                guard let distributed = error as? SongbirdDistributedError,
                      case .remoteCallFailed(let message) = distributed else {
                    return false
                }
                return message.contains("Name must not be empty")
            }
        } catch {
            try? await clientSystem.shutdown()
            try? await workerSystem.shutdown()
            throw error
        }

        try await clientSystem.shutdown()
        try await workerSystem.shutdown()
    }
}
