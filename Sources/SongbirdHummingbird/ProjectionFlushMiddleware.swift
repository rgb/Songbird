import Hummingbird
import Songbird

/// Middleware that waits for the projection pipeline to become idle after the
/// route handler completes. This ensures read-after-write consistency and is
/// intended for use in tests. Timeout errors from the pipeline are silently
/// swallowed so they never surface to the caller.
public struct ProjectionFlushMiddleware<Context: RequestContext>: RouterMiddleware {
    let pipeline: ProjectionPipeline

    public init(pipeline: ProjectionPipeline) {
        self.pipeline = pipeline
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        try? await pipeline.waitForIdle()
        return response
    }
}
