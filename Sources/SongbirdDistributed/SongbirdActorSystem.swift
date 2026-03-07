import Distributed
import Foundation
import Logging
import NIOCore
import Synchronization

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
///
/// `@unchecked Sendable` is justified because all mutable state (`localActors`,
/// `nextAutoId`, `clients`, `serverBox`) is protected by `LockedBox` (backed by `Mutex`).
/// Every read and write acquires the lock first. The `DistributedActorSystem` protocol
/// requires synchronous (non-`async`) methods, preventing the use of an actor.
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
    ///
    /// If a client for the given `processName` already exists, it is disconnected
    /// before being replaced, preventing event-loop thread leaks.
    public func connect(processName: String, socketPath: String) async throws {
        let client = TransportClient()
        try await client.connect(socketPath: socketPath)
        let oldClient = clients.withLock { state -> TransportClient? in
            let old = state[processName]
            state[processName] = client
            return old
        }
        if let oldClient {
            try await oldClient.disconnect()
        }
    }

    /// Stops the server and disconnects all clients.
    ///
    /// All resources are cleaned up regardless of individual failures. If any
    /// step throws, the first error is re-thrown after all cleanup completes.
    public func shutdown() async throws {
        var firstError: (any Error)?
        if let server = serverBox.withLock({ val -> TransportServer? in
            let s = val; val = nil; return s
        }) {
            do { try await server.stop() }
            catch { firstError = error }
        }
        let allClients = clients.withLock { dict -> [TransportClient] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for client in allClients {
            do { try await client.disconnect() }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
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

/// A simple thread-safe wrapper for mutable state using Swift 6.2 Mutex.
final class LockedBox<T: Sendable>: Sendable {
    private let mutex: Mutex<T>

    init(_ value: T) {
        self.mutex = Mutex(value)
    }

    func withLock<R: Sendable>(_ body: @Sendable (inout T) -> R) -> R {
        mutex.withLock { body(&$0) }
    }
}

// MARK: - Message Handler

/// Bridges incoming wire messages to the actor system's call dispatch.
struct ActorSystemMessageHandler: WireMessageHandler {
    private static let logger = Logger(label: "songbird.actor-system.handler")
    let system: SongbirdActorSystem

    func handleMessage(_ message: WireMessage, channel: any Channel) async {
        guard case .call(let call) = message else {
            Self.logger.warning("Server received non-call message, ignoring")
            return
        }

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

        let responseData: Data
        do {
            responseData = try JSONEncoder().encode(response)
        } catch {
            Self.logger.error("Failed to encode response", metadata: [
                "requestId": "\(call.requestId)",
                "error": "\(error)",
            ])
            // Send an error response so the client doesn't hang
            let fallback = WireMessage.error(.init(
                requestId: call.requestId,
                message: "Internal: response encoding failed"
            ))
            if let fallbackData = try? JSONEncoder().encode(fallback) {
                var buffer = channel.allocator.buffer(capacity: fallbackData.count)
                buffer.writeBytes(fallbackData)
                let p = channel.eventLoop.makePromise(of: Void.self)
                p.futureResult.whenFailure { err in
                    Self.logger.error("Failed to write error response", metadata: ["error": "\(err)"])
                }
                channel.writeAndFlush(buffer, promise: p)
            }
            return
        }
        var buffer = channel.allocator.buffer(capacity: responseData.count)
        buffer.writeBytes(responseData)
        let p = channel.eventLoop.makePromise(of: Void.self)
        p.futureResult.whenFailure { err in
            Self.logger.error("Failed to write response", metadata: ["error": "\(err)"])
        }
        channel.writeAndFlush(buffer, promise: p)
    }
}
