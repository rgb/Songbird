import Foundation
import HTTPTypes
import Hummingbird

public struct RequestIdMiddleware: RouterMiddleware {
    public typealias Context = SongbirdRequestContext

    /// Force unwrap is safe: "X-Request-ID" is a compile-time constant that is a valid
    /// HTTP field name per RFC 9110 (alphabetic characters and hyphens only).
    static let headerName = HTTPField.Name("X-Request-ID")!

    public init() {}

    public func handle(
        _ request: Request,
        context: SongbirdRequestContext,
        next: (Request, SongbirdRequestContext) async throws -> Response
    ) async throws -> Response {
        var context = context
        context.requestId = request.headers[Self.headerName] ?? UUID().uuidString
        var response = try await next(request, context)
        response.headers[Self.headerName] = context.requestId
        return response
    }
}
