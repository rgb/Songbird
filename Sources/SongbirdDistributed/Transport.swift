import Foundation
import Logging
import NIOCore
import NIOPosix

// MARK: - Message Handler Protocol

/// Protocol for handling incoming wire messages (used by the actor system).
public protocol WireMessageHandler: Sendable {
    func handleMessage(_ message: WireMessage, channel: any Channel) async
}

// MARK: - Transport Server

/// A NIO-based Unix domain socket server that accepts connections and dispatches
/// incoming `WireMessage` calls to a `WireMessageHandler`.
public final class TransportServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let handler: any WireMessageHandler
    private let serverChannelBox = LockedBox<(any Channel)?>(nil)
    private let socketPath: String

    public init(socketPath: String, handler: any WireMessageHandler) {
        self.socketPath = socketPath
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.handler = handler
    }

    /// Starts listening on the Unix domain socket.
    public func start() async throws {
        // Remove stale socket file if it exists
        try? FileManager.default.removeItem(atPath: socketPath)

        let handler = self.handler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(MessageFrameDecoder())).flatMap {
                    channel.pipeline.addHandler(MessageFrameEncoder())
                }.flatMap {
                    channel.pipeline.addHandler(ServerInboundHandler(messageHandler: handler))
                }
            }

        let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        serverChannelBox.withLock { $0 = channel }
    }

    /// Stops the server and cleans up the socket file.
    public func stop() async throws {
        let channel = serverChannelBox.withLock { $0 }
        try await channel?.close()
        try? FileManager.default.removeItem(atPath: socketPath)
        try await group.shutdownGracefully()
    }
}

// MARK: - Transport Client

/// A NIO-based Unix domain socket client that connects to a server and sends
/// `WireMessage` calls, awaiting responses via continuations.
public actor TransportClient {
    private let group: MultiThreadedEventLoopGroup
    private var channel: (any Channel)?
    private var pendingCalls: [UInt64: CheckedContinuation<WireMessage, any Error>] = [:]
    private var nextRequestId: UInt64 = 0
    private let callTimeout: Duration

    public init(callTimeout: Duration = .seconds(30)) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.callTimeout = callTimeout
    }

    /// Connects to a Unix domain socket server.
    public func connect(socketPath: String) async throws {
        let clientHandler = ClientInboundHandler(client: self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(MessageFrameDecoder())).flatMap {
                    channel.pipeline.addHandler(MessageFrameEncoder())
                }.flatMap {
                    channel.pipeline.addHandler(clientHandler)
                }
            }

        self.channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
    }

    /// Sends a call and waits for the response.
    public func call(actorName: String, targetName: String, arguments: Data) async throws -> WireMessage {
        guard let channel else {
            throw SongbirdDistributedError.notConnected("no connection")
        }

        let requestId = nextRequestId
        nextRequestId += 1

        let message = WireMessage.call(.init(
            requestId: requestId,
            actorName: actorName,
            targetName: targetName,
            arguments: arguments
        ))

        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            throw SongbirdDistributedError.connectionFailed("Failed to encode message: \(error)")
        }

        return try await withThrowingTaskGroup(of: WireMessage.self) { group in
            group.addTask {
                try await self.sendAndAwaitResponse(requestId: requestId, data: data, channel: channel)
            }
            group.addTask {
                try await Task.sleep(for: self.callTimeout)
                await self.cancelPendingCall(requestId: requestId, error: SongbirdDistributedError.remoteCallFailed("Call timed out"))
                throw SongbirdDistributedError.remoteCallFailed("Call timed out")
            }
            guard let result = try await group.next() else {
                throw SongbirdDistributedError.remoteCallFailed("Call cancelled")
            }
            group.cancelAll()
            return result
        }
    }

    /// Registers a pending call continuation and sends the encoded message over the channel.
    private func sendAndAwaitResponse(requestId: UInt64, data: Data, channel: any Channel) async throws -> WireMessage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCalls[requestId] = continuation
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                let promise = channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenFailure { error in
                    Task { await self.cancelPendingCall(requestId: requestId, error: SongbirdDistributedError.connectionFailed("Write failed: \(error)")) }
                }
                channel.writeAndFlush(buffer, promise: promise)

                // Guard against cancellation racing with registration.
                // If the task was cancelled before the continuation was registered,
                // the onCancel handler found nothing to cancel. Clean up now.
                if Task.isCancelled {
                    if let cont = pendingCalls.removeValue(forKey: requestId) {
                        cont.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelPendingCall(requestId: requestId, error: CancellationError()) }
        }
    }

    /// Cancels a pending call by resuming its continuation with the given error.
    private func cancelPendingCall(requestId: UInt64, error: any Error) {
        if let continuation = pendingCalls.removeValue(forKey: requestId) {
            continuation.resume(throwing: error)
        }
    }

    /// Called by the inbound handler when a response arrives.
    func receiveResponse(_ message: WireMessage) {
        let requestId: UInt64
        switch message {
        case .result(let r): requestId = r.requestId
        case .error(let e): requestId = e.requestId
        case .call: return  // Clients don't receive calls
        }

        if let continuation = pendingCalls.removeValue(forKey: requestId) {
            continuation.resume(returning: message)
        }
    }

    /// Called when the channel closes unexpectedly (server crash, network error).
    func handleUnexpectedDisconnect() {
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: SongbirdDistributedError.notConnected("connection lost"))
        }
        pendingCalls.removeAll()
        channel = nil
    }

    /// Disconnects from the server.
    public func disconnect() async throws {
        // Resume all pending continuations before closing
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: SongbirdDistributedError.notConnected("disconnected"))
        }
        pendingCalls.removeAll()

        try await channel?.close()
        channel = nil
        try await group.shutdownGracefully()
    }
}

// MARK: - NIO Handlers
//
// These handlers are marked @unchecked Sendable because NIO channel handlers
// must be classes, and NIO's own ByteToMessageHandler has Sendable conformance
// explicitly unavailable (a known SwiftNIO upstream issue). Our handlers are
// either stateless (MessageFrameDecoder, MessageFrameEncoder) or hold only
// Sendable references (ServerInboundHandler holds `any WireMessageHandler`,
// ClientInboundHandler holds `TransportClient` which is an actor). The
// @unchecked Sendable is safe because NIO guarantees handler methods are
// called on the channel's EventLoop thread.
//
// Build warning "Conformance of 'ByteToMessageHandler<Decoder>' to 'Sendable'
// is unavailable" comes from SwiftNIO upstream and cannot be fixed in our code.

/// Maximum allowed wire message size (16 MB).
private let maxWireMessageSize: UInt32 = 16 * 1024 * 1024

/// Length-prefixed frame decoder: reads 4-byte big-endian length + payload.
final class MessageFrameDecoder: ByteToMessageDecoder, @unchecked Sendable {
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 4 else { return .needMoreData }

        let lengthIndex = buffer.readerIndex
        guard let length = buffer.getInteger(at: lengthIndex, as: UInt32.self) else {
            return .needMoreData
        }

        guard length <= maxWireMessageSize else {
            let logger = Logger(label: "songbird.transport.decoder")
            logger.error("Inbound message exceeds max size", metadata: [
                "size": "\(length)", "max": "\(maxWireMessageSize)",
            ])
            context.close(promise: nil)
            throw SongbirdDistributedError.connectionFailed("Inbound message exceeds max size: \(length) > \(maxWireMessageSize)")
        }

        let totalLength = 4 + Int(length)
        guard buffer.readableBytes >= totalLength else { return .needMoreData }

        buffer.moveReaderIndex(forwardBy: 4)
        guard let payload = buffer.readSlice(length: Int(length)) else {
            return .needMoreData
        }

        context.fireChannelRead(NIOAny(payload))
        return .continue
    }
}

/// Length-prefixed frame encoder: writes 4-byte big-endian length + payload.
final class MessageFrameEncoder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let payload = unwrapOutboundIn(data)
        guard payload.readableBytes <= maxWireMessageSize else {
            let error = SongbirdDistributedError.remoteCallFailed(
                "Outbound message exceeds max size (\(payload.readableBytes) > \(maxWireMessageSize))"
            )
            promise?.fail(error)
            return
        }
        var frame = context.channel.allocator.buffer(capacity: 4 + payload.readableBytes)
        frame.writeInteger(UInt32(payload.readableBytes))
        frame.writeImmutableBuffer(payload)
        context.write(NIOAny(frame), promise: promise)
    }
}

/// Server-side handler: decodes incoming messages and dispatches to the WireMessageHandler.
final class ServerInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private static let logger = Logger(label: "songbird.transport.server")

    let messageHandler: any WireMessageHandler

    init(messageHandler: any WireMessageHandler) {
        self.messageHandler = messageHandler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        let message: WireMessage
        do {
            message = try JSONDecoder().decode(WireMessage.self, from: Data(bytes))
        } catch {
            Self.logger.warning("Failed to decode incoming message, dropping", metadata: [
                "error": "\(error)",
            ])
            return
        }

        let channel = context.channel
        let handler = messageHandler
        Task {
            await handler.handleMessage(message, channel: channel)
        }
    }
}

/// Client-side handler: receives responses and forwards them to the TransportClient actor.
final class ClientInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private static let logger = Logger(label: "songbird.transport.client")

    let client: TransportClient

    init(client: TransportClient) {
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: Data(bytes)) else {
            Self.logger.warning("Failed to decode response message, dropping")
            return
        }

        Task {
            await client.receiveResponse(message)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task {
            await client.handleUnexpectedDisconnect()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Self.logger.warning("Channel error", metadata: ["error": "\(error)"])
        context.close(promise: nil)
    }
}
