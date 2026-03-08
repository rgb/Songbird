import Distributed
import Foundation
import Hummingbird
import NIOCore
import SongbirdDistributed
import SongbirdHummingbird

// MARK: - Remote Actor Proxies
//
// These distributed actor declarations mirror the worker-side command handlers.
// Swift Distributed Actors match by mangled target name, so the type names and
// distributed func signatures must match exactly.

distributed actor IdentityCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    distributed func registerUser(id: String, email: String, displayName: String) async throws { fatalError() }
    distributed func updateProfile(userId: String, displayName: String) async throws { fatalError() }
    distributed func deactivateUser(userId: String) async throws { fatalError() }
    distributed func getUser(id: String) async throws -> UserDTO? { fatalError() }
}

distributed actor CatalogCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    distributed func publishVideo(id: String, title: String, description: String, creatorId: String) async throws { fatalError() }
    distributed func updateVideoMetadata(id: String, title: String, description: String) async throws { fatalError() }
    distributed func completeTranscoding(id: String) async throws { fatalError() }
    distributed func unpublishVideo(id: String) async throws { fatalError() }
    distributed func getVideo(id: String) async throws -> VideoDTO? { fatalError() }
    distributed func listVideos() async throws -> [VideoDTO] { fatalError() }
}

distributed actor SubscriptionsCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    distributed func requestSubscription(id: String, userId: String, plan: String) async throws { fatalError() }
    distributed func confirmPayment(subscriptionId: String) async throws { fatalError() }
    distributed func getSubscriptions(userId: String) async throws -> [SubscriptionDTO] { fatalError() }
}

distributed actor AnalyticsCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    distributed func recordView(videoId: String, userId: String, watchedSeconds: Int) async throws { fatalError() }
    distributed func getVideoViews(videoId: String) async throws -> ViewCountDTO? { fatalError() }
    distributed func getTopVideos() async throws -> [TopVideoDTO] { fatalError() }
}

// MARK: - DTOs (must match worker-side definitions exactly)

public struct UserDTO: Codable, Sendable {
    public let id: String
    public let email: String
    public let displayName: String
    public let isActive: Bool
}

public struct VideoDTO: Codable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let creatorId: String
    public let status: String
}

public struct SubscriptionDTO: Codable, Sendable {
    public let id: String
    public let userId: String
    public let plan: String
    public let status: String
}

public struct ViewCountDTO: Codable, Sendable {
    public let viewCount: Int64
    public let totalSeconds: Int64
}

public struct TopVideoDTO: Codable, Sendable {
    public let videoId: String
    public let viewCount: Int64
    public let totalSeconds: Int64
}

// MARK: - Bootstrap

@main
struct WarblerGatewayApp {
    static func main() async throws {
        // Socket paths (configurable via env or defaults)
        let identitySocket = ProcessInfo.processInfo.environment["IDENTITY_SOCKET"] ?? "/tmp/songbird/identity.sock"
        let catalogSocket = ProcessInfo.processInfo.environment["CATALOG_SOCKET"] ?? "/tmp/songbird/catalog.sock"
        let subscriptionsSocket = ProcessInfo.processInfo.environment["SUBSCRIPTIONS_SOCKET"] ?? "/tmp/songbird/subscriptions.sock"
        let analyticsSocket = ProcessInfo.processInfo.environment["ANALYTICS_SOCKET"] ?? "/tmp/songbird/analytics.sock"
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080

        // Create actor system and connect to all workers
        let system = SongbirdActorSystem(processName: "gateway")
        try await system.connect(processName: "identity-worker", socketPath: identitySocket)
        try await system.connect(processName: "catalog-worker", socketPath: catalogSocket)
        try await system.connect(processName: "subscriptions-worker", socketPath: subscriptionsSocket)
        try await system.connect(processName: "analytics-worker", socketPath: analyticsSocket)

        // Resolve remote command handlers (using auto-assigned actor names)
        let identity = try IdentityCommandHandler.resolve(
            id: SongbirdActorID(processName: "identity-worker", actorName: "auto-0"),
            using: system
        )
        let catalog = try CatalogCommandHandler.resolve(
            id: SongbirdActorID(processName: "catalog-worker", actorName: "auto-0"),
            using: system
        )
        let subscriptions = try SubscriptionsCommandHandler.resolve(
            id: SongbirdActorID(processName: "subscriptions-worker", actorName: "auto-0"),
            using: system
        )
        let analytics = try AnalyticsCommandHandler.resolve(
            id: SongbirdActorID(processName: "analytics-worker", actorName: "auto-0"),
            using: system
        )

        // MARK: - Router

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }

        // MARK: - Identity Routes

        router.post("/users/{id}") { request, context in
            let id = try context.parameters.require("id")
            struct Body: Codable { let email: String; let displayName: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await identity.registerUser(id: id, email: body.email, displayName: body.displayName)
            return Response(status: .created)
        }

        router.get("/users/{id}") { _, context in
            let id = try context.parameters.require("id")
            guard let user = try await identity.getUser(id: id) else {
                return Response(status: .notFound)
            }
            let data = try JSONEncoder().encode(user)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.patch("/users/{id}") { request, context in
            let id = try context.parameters.require("id")
            struct Body: Codable { let displayName: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await identity.updateProfile(userId: id, displayName: body.displayName)
            return Response(status: .ok)
        }

        router.delete("/users/{id}") { _, context in
            let id = try context.parameters.require("id")
            try await identity.deactivateUser(userId: id)
            return Response(status: .ok)
        }

        // MARK: - Catalog Routes

        router.post("/videos/{id}") { request, context in
            let id = try context.parameters.require("id")
            struct Body: Codable { let title: String; let description: String; let creatorId: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await catalog.publishVideo(id: id, title: body.title, description: body.description, creatorId: body.creatorId)
            return Response(status: .created)
        }

        router.get("/videos") { _, _ in
            let videos = try await catalog.listVideos()
            let data = try JSONEncoder().encode(videos)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.get("/videos/{id}") { _, context in
            let id = try context.parameters.require("id")
            guard let video = try await catalog.getVideo(id: id) else {
                return Response(status: .notFound)
            }
            let data = try JSONEncoder().encode(video)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.patch("/videos/{id}") { request, context in
            let id = try context.parameters.require("id")
            struct Body: Codable { let title: String; let description: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await catalog.updateVideoMetadata(id: id, title: body.title, description: body.description)
            return Response(status: .ok)
        }

        router.post("/videos/{id}/transcode-complete") { _, context in
            let id = try context.parameters.require("id")
            try await catalog.completeTranscoding(id: id)
            return Response(status: .ok)
        }

        router.delete("/videos/{id}") { _, context in
            let id = try context.parameters.require("id")
            try await catalog.unpublishVideo(id: id)
            return Response(status: .ok)
        }

        // MARK: - Subscription Routes

        router.post("/subscriptions/{id}") { request, context in
            let id = try context.parameters.require("id")
            struct Body: Codable { let userId: String; let plan: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await subscriptions.requestSubscription(id: id, userId: body.userId, plan: body.plan)
            return Response(status: .created)
        }

        router.get("/subscriptions/{userId}") { _, context in
            let userId = try context.parameters.require("userId")
            let subs = try await subscriptions.getSubscriptions(userId: userId)
            let data = try JSONEncoder().encode(subs)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.post("/subscriptions/{id}/pay") { _, context in
            let id = try context.parameters.require("id")
            try await subscriptions.confirmPayment(subscriptionId: id)
            return Response(status: .ok)
        }

        // MARK: - Analytics Routes

        router.post("/analytics/views") { request, context in
            struct Body: Codable { let videoId: String; let userId: String; let watchedSeconds: Int }
            let body = try await request.decode(as: Body.self, context: context)
            try await analytics.recordView(videoId: body.videoId, userId: body.userId, watchedSeconds: body.watchedSeconds)
            return Response(status: .accepted)
        }

        router.get("/analytics/videos/{id}/views") { _, context in
            let id = try context.parameters.require("id")
            let result = try await analytics.getVideoViews(videoId: id)
            let data = try JSONEncoder().encode(result)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.get("/analytics/top-videos") { _, _ in
            let top = try await analytics.getTopVideos()
            let data = try JSONEncoder().encode(top)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: port))
        )

        print("Warbler Gateway starting on http://localhost:\(port)")
        do {
            try await app.runService()
        } catch {
            try? await system.shutdown()
            throw error
        }
        try await system.shutdown()
    }
}
