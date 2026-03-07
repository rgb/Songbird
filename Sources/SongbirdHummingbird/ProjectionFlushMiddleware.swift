import Hummingbird
import Songbird

/// Middleware that waits for the projection pipeline to become idle after the
/// route handler completes. This ensures read-after-write consistency and is
/// intended for use in tests. Timeout errors from the pipeline are silently
/// swallowed so they never surface to the caller.
public struct ProjectionFlushMiddleware<Context: RequestContext>: RouterMiddleware {
    let pipeline: ProjectionPipeline
    let timeout: Duration

    public init(pipeline: ProjectionPipeline, timeout: Duration = .seconds(5)) {
        self.pipeline = pipeline
        self.timeout = timeout
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        do {
            try await pipeline.waitForIdle(timeout: timeout)
        } catch {
            // waitForIdle throws timeout or cancellation — both are safe to ignore
            // because the HTTP response is already computed. We're just waiting for
            // projections to catch up for read-after-write consistency.
        }
        return response
    }
}
