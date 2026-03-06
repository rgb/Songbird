import Distributed
import Foundation
import NIOCore

/// A custom `DistributedActorSystem` for same-machine IPC over Unix domain sockets.
///
/// Each process creates a `SongbirdActorSystem` and binds a Unix domain socket.
/// Workers register local distributed actors. The gateway connects to worker sockets
/// and calls their distributed functions transparently.
///
/// Usage (worker side):
/// ```swift
/// let system = SongbirdActorSystem(processName: "identity-worker")
/// try await system.startServer(socketPath: "/tmp/songbird/identity.sock")
/// let handler = IdentityHandler(actorSystem: system)
/// ```
///
/// Usage (gateway/client side):
/// ```swift
/// let system = SongbirdActorSystem(processName: "gateway")
/// try await system.connect(processName: "identity-worker", socketPath: "/tmp/songbird/identity.sock")
/// let handler = try IdentityHandler.resolve(
///     id: SongbirdActorID(processName: "identity-worker", actorName: "handler"),
///     using: system
/// )
/// let result = try await handler.doSomething()
/// ```
public final class SongbirdActorSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = SongbirdActorID
    public typealias InvocationEncoder = SongbirdInvocationEncoder
    public typealias InvocationDecoder = SongbirdInvocationDecoder
    public typealias ResultHandler = SongbirdResultHandler
    public typealias SerializationRequirement = Codable

    /// The process name for this system instance.
    public let processName: String

    /// Registered local actors, keyed by actor name.
    private let localActors = LockedBox<[String: any DistributedActor]>([:])

    /// Auto-increment counter for actor names when not explicitly assigned.
    private let nextAutoId = LockedBox<Int>(0)

    /// Transport clients connected to remote processes, keyed by process name.
    private let clients = LockedBox<[String: TransportClient]>([:])

    /// Transport server (if this system is a worker).
    private let serverBox = LockedBox<TransportServer?>(nil)

    public init(processName: String) {
        self.processName = processName
    }

    // MARK: - Server / Client Management

    /// Starts listening for incoming distributed actor calls on a Unix domain socket.
    public func startServer(socketPath: String) async throws {
        let server = TransportServer(socketPath: socketPath, handler: ActorSystemMessageHandler(system: self))
        try await server.start()
        serverBox.withLock { $0 = server }
    }

    /// Connects to a remote worker process.
    public func connect(processName: String, socketPath: String) async throws {
        let client = TransportClient()
        try await client.connect(socketPath: socketPath)
        clients.withLock { $0[processName] = client }
    }

    /// Stops the server and disconnects all clients.
    public func shutdown() async throws {
        if let server = serverBox.withLock({ $0 }) {
            try await server.stop()
            serverBox.withLock { $0 = nil }
        }
        let allClients = clients.withLock { dict -> [TransportClient] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for client in allClients {
            try await client.disconnect()
        }
    }

    // MARK: - DistributedActorSystem Protocol

    public func resolve<Act>(id: SongbirdActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == SongbirdActorID {
        // Return local actor if it's ours
        if id.processName == processName {
            return localActors.withLock { $0[id.actorName] } as? Act
        }
        // For remote actors, return nil — Swift creates a remote proxy
        return nil
    }

    public func assignID<Act>(_ actorType: Act.Type) -> SongbirdActorID
    where Act: DistributedActor {
        let autoId = nextAutoId.withLock { id -> Int in
            let current = id
            id += 1
            return current
        }
        return SongbirdActorID(processName: processName, actorName: "auto-\(autoId)")
    }

    public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == SongbirdActorID {
        localActors.withLock { $0[actor.id.actorName] = actor }
    }

    public func resignID(_ id: SongbirdActorID) {
        localActors.withLock { _ = $0.removeValue(forKey: id.actorName) }
    }

    public func makeInvocationEncoder() -> SongbirdInvocationEncoder {
        SongbirdInvocationEncoder()
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout SongbirdInvocationEncoder,
        throwing _: Err.Type,
        returning _: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == SongbirdActorID, Err: Error, Res: Codable {
        let id = actor.id
        guard let client = clients.withLock({ $0[id.processName] }) else {
            throw SongbirdDistributedError.notConnected(id.processName)
        }

        let arguments = try invocation.encodeArguments()
        let response = try await client.call(
            actorName: id.actorName,
            targetName: target.identifier,
            arguments: arguments
        )

        switch response {
        case .result(let result):
            return try JSONDecoder().decode(Res.self, from: result.value)
        case .error(let err):
            throw SongbirdDistributedError.remoteCallFailed(err.message)
        case .call:
            throw SongbirdDistributedError.remoteCallFailed("Unexpected call message in response")
        }
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout SongbirdInvocationEncoder,
        throwing _: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == SongbirdActorID, Err: Error {
        let id = actor.id
        guard let client = clients.withLock({ $0[id.processName] }) else {
            throw SongbirdDistributedError.notConnected(id.processName)
        }

        let arguments = try invocation.encodeArguments()
        let response = try await client.call(
            actorName: id.actorName,
            targetName: target.identifier,
            arguments: arguments
        )

        switch response {
        case .result:
            return  // void success
        case .error(let err):
            throw SongbirdDistributedError.remoteCallFailed(err.message)
        case .call:
            throw SongbirdDistributedError.remoteCallFailed("Unexpected call message in response")
        }
    }

    // MARK: - Incoming Call Dispatch

    /// Handles an incoming distributed actor call from the transport layer.
    func handleIncomingCall(actorName: String, targetName: String, arguments: Data) async throws -> (data: Data?, error: String?) {
        guard let actor = localActors.withLock({ $0[actorName] }) else {
            throw SongbirdDistributedError.actorNotFound(
                SongbirdActorID(processName: processName, actorName: actorName)
            )
        }

        var decoder = try SongbirdInvocationDecoder(data: arguments)
        let handler = SongbirdResultHandler()

        try await executeDistributedTarget(
            on: actor,
            target: RemoteCallTarget(targetName),
            invocationDecoder: &decoder,
            handler: handler
        )

        if handler.isSuccess {
            return (data: handler.resultData, error: nil)
        } else {
            return (data: nil, error: handler.errorMessage ?? "Unknown error")
        }
    }
}

// MARK: - LockedBox

/// A simple thread-safe wrapper for mutable state.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Message Handler

/// Bridges incoming wire messages to the actor system's call dispatch.
struct ActorSystemMessageHandler: WireMessageHandler {
    let system: SongbirdActorSystem

    func handleMessage(_ message: WireMessage, channel: any Channel) async {
        guard case .call(let call) = message else { return }

        let response: WireMessage
        do {
            let (data, error) = try await system.handleIncomingCall(
                actorName: call.actorName,
                targetName: call.targetName,
                arguments: call.arguments
            )
            if let error {
                response = .error(.init(requestId: call.requestId, message: error))
            } else {
                response = .result(.init(requestId: call.requestId, value: data ?? Data()))
            }
        } catch {
            response = .error(.init(requestId: call.requestId, message: String(describing: error)))
        }

        guard let responseData = try? JSONEncoder().encode(response) else { return }
        var buffer = channel.allocator.buffer(capacity: responseData.count)
        buffer.writeBytes(responseData)
        channel.writeAndFlush(buffer, promise: nil)
    }
}
