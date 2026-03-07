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

    @Test func returnsResponseEvenWhenPipelineIsNotRunning() async throws {
        // Pipeline is created but never run — waitForIdle will return immediately
        // because enqueuedPosition < 0. But if an event were enqueued without run(),
        // waitForIdle would time out. The middleware catches all errors from
        // waitForIdle, so the HTTP response is always returned regardless.
        // A short timeout avoids a 5-second wait in this test.
        let pipeline = ProjectionPipeline()

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware {
            ProjectionFlushMiddleware<SongbirdRequestContext>(
                pipeline: pipeline, timeout: .milliseconds(100)
            )
        }
        router.get("/test") { _, _ -> String in
            // Enqueue an event that will never be projected (pipeline not running)
            await pipeline.enqueue(try RecordedEvent(event: FlushTestEvent()))
            return "ok"
        }
        let app = Application(router: router)

        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/test", method: .get)
            #expect(response.status == .ok)
        }
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
