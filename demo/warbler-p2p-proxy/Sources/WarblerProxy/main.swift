import AsyncHTTPClient
import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import NIOHTTP1

@main
struct WarblerProxy {
    // Backend ports are configured to match the P2P service defaults (8081-8084).
    // Override via individual service PORT env vars if needed.
    static let backends: [(prefix: String, port: Int, name: String)] = [
        ("/users", 8081, "identity"),
        ("/videos", 8082, "catalog"),
        ("/subscriptions", 8083, "subscriptions"),
        ("/analytics", 8084, "analytics"),
    ]

    static func main() async throws {
        let logger = Logger(label: "warbler.proxy")
        let httpClient = HTTPClient()
        let bindHost = ProcessInfo.processInfo.environment["BIND_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
        let router = Router()

        // Health check route
        router.get("/health") { _, _ -> Response in
            try await healthCheck(httpClient: httpClient)
        }

        // Proxy middleware handles all other requests
        router.addMiddleware { ProxyMiddleware(backends: backends, httpClient: httpClient, logger: logger) }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(bindHost, port: port))
        )

        logger.info("WarblerProxy starting on http://\(bindHost):\(port)")
        logger.info("Routing:")
        for b in backends {
            logger.info("  \(b.prefix)/* -> localhost:\(b.port) (\(b.name))")
        }
        do {
            try await app.runService()
        } catch {
            try? await httpClient.shutdown()
            throw error
        }
        try await httpClient.shutdown()
    }

    static func healthCheck(httpClient: HTTPClient) async throws -> Response {
        struct HealthResponse: Codable, Sendable {
            let status: String
            let services: [String: String]
        }

        var serviceStatuses: [String: String] = [:]
        var allHealthy = true

        for backend in backends {
            // Probe a known route for each backend service
            let url = "http://localhost:\(backend.port)\(backend.prefix)"
            var request = HTTPClientRequest(url: url)
            request.method = .GET

            do {
                let response = try await httpClient.execute(request, timeout: .seconds(5))
                _ = try? await response.body.collect(upTo: 1024)
                serviceStatuses[backend.name] = "up"
            } catch {
                serviceStatuses[backend.name] = "down"
                allHealthy = false
            }
        }

        let healthResponse = HealthResponse(
            status: allHealthy ? "healthy" : "degraded",
            services: serviceStatuses
        )
        let data = try JSONEncoder().encode(healthResponse)
        return Response(
            status: allHealthy ? .ok : .serviceUnavailable,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}

struct ProxyMiddleware: RouterMiddleware {
    let backends: [(prefix: String, port: Int, name: String)]
    let httpClient: HTTPClient
    let logger: Logger

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        let path = request.uri.path

        guard let backend = backends.first(where: { path.hasPrefix($0.prefix) }) else {
            // No matching backend — let the router handle it (e.g., /health, or 404)
            return try await next(request, context)
        }

        let start = ContinuousClock.now
        let response = await forward(request: request, path: path, backend: backend)
        let elapsed = ContinuousClock.now - start

        logger.info("\(request.method) \(path) → :\(backend.port) (\(backend.name)) → \(response.status.code) [\(elapsed)]")

        return response
    }

    func forward(
        request: Request,
        path: String,
        backend: (prefix: String, port: Int, name: String)
    ) async -> Response {
        let query = request.uri.query.map { "?\($0)" } ?? ""
        let url = "http://localhost:\(backend.port)\(path)\(query)"

        var clientRequest = HTTPClientRequest(url: url)
        clientRequest.method = .RAW(value: String(request.method.rawValue))

        // Forward headers (skip host — AsyncHTTPClient sets it from the URL)
        for header in request.headers {
            guard header.name.rawName.lowercased() != "host" else { continue }
            clientRequest.headers.add(name: String(header.name.rawName), value: String(header.value))
        }

        // Forward body
        if let contentLength = request.headers[.contentLength], let length = Int(contentLength) {
            clientRequest.body = .stream(request.body, length: .known(Int64(length)))
        } else {
            clientRequest.body = .stream(request.body, length: .unknown)
        }

        do {
            let response = try await httpClient.execute(clientRequest, timeout: .seconds(30))

            var responseHeaders = HTTPFields()
            for header in response.headers {
                if let name = HTTPField.Name(header.name) {
                    responseHeaders.append(HTTPField(name: name, value: header.value))
                }
            }

            return Response(
                status: .init(code: Int(response.status.code)),
                headers: responseHeaders,
                body: .init(asyncSequence: response.body)
            )
        } catch {
            let body = #"{"error":"Service unavailable: \#(backend.name) (port \#(backend.port))"}"#
            return Response(
                status: .badGateway,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
    }
}
