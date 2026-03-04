import Foundation
import Hummingbird
import HummingbirdTesting
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

private actor CountingProjector: Projector {
    let projectorId = "counting"
    private(set) var count = 0

    func apply(_ event: RecordedEvent) async throws {
        count += 1
    }
}

private struct FlushTestEvent: Event {
    var eventType: String { "FlushTestEvent" }
}

@Suite("ProjectionFlushMiddleware")
struct ProjectionFlushMiddlewareTests {
    @Test func waitsForPipelineAfterHandler() async throws {
        let pipeline = ProjectionPipeline()
        let projector = CountingProjector()
        await pipeline.register(projector)
        let pipelineTask = Task { await pipeline.run() }

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware {
            ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline)
        }
        router.get("/test") { _, _ -> String in
            await pipeline.enqueue(try RecordedEvent(event: FlushTestEvent()))
            return "ok"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            #expect(response.status == .ok)
        }

        let count = await projector.count
        #expect(count == 1)

        await pipeline.stop()
        await pipelineTask.value
    }

    @Test func worksWithAnyRequestContext() async throws {
        let pipeline = ProjectionPipeline()
        let pipelineTask = Task { await pipeline.run() }

        let router = Router(context: BasicRequestContext.self)
        router.addMiddleware {
            ProjectionFlushMiddleware<BasicRequestContext>(pipeline: pipeline)
        }
        router.get("/test") { _, _ -> String in "ok" }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            #expect(response.status == .ok)
        }

        await pipeline.stop()
        await pipelineTask.value
    }
}
