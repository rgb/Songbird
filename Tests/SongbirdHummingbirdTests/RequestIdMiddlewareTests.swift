import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SongbirdHummingbird

@Suite("RequestIdMiddleware")
struct RequestIdMiddlewareTests {
    @Test func extractsExistingRequestId() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.get("/test") { _, context -> String in
            context.requestId ?? "none"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/test",
                method: .get,
                headers: [.init("X-Request-ID")!: "my-trace-123"]
            )
            #expect(String(buffer: response.body) == "my-trace-123")
            #expect(response.headers[.init("X-Request-ID")!] == "my-trace-123")
        }
    }

    @Test func generatesUUIDWhenHeaderMissing() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.get("/test") { _, context -> String in
            context.requestId ?? "none"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            let body = String(buffer: response.body)
            #expect(body != "none")
            #expect(UUID(uuidString: body) != nil)
            #expect(response.headers[.init("X-Request-ID")!] == body)
        }
    }

    @Test func echoesRequestIdInResponse() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.get("/test") { _, _ -> String in "ok" }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/test",
                method: .get,
                headers: [.init("X-Request-ID")!: "echo-me"]
            )
            #expect(response.headers[.init("X-Request-ID")!] == "echo-me")
        }
    }
}
