import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SongbirdHummingbird

@Suite("SongbirdRequestContext")
struct SongbirdRequestContextTests {
    @Test func requestIdIsNilByDefault() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.get("/test") { _, context -> String in
            let hasRequestId = context.requestId != nil
            return "\(hasRequestId)"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            #expect(String(buffer: response.body) == "false")
        }
    }

    @Test func contextWorksWithRouter() async throws {
        let router = Router(context: SongbirdRequestContext.self)
        router.get("/hello") { _, _ -> String in
            "hello"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/hello", method: .get)
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "hello")
        }
    }
}
