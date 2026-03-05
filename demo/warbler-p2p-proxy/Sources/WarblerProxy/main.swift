import Hummingbird

@main
struct WarblerProxy {
    static func main() async throws {
        let router = Router()
        router.get("/") { _, _ in "WarblerProxy placeholder" }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: 8080))
        )

        print("WarblerProxy starting on http://localhost:8080")
        try await app.runService()
    }
}
