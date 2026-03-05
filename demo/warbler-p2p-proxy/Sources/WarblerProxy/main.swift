import AsyncHTTPClient
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import NIOHTTP1

@main
struct WarblerProxy {
    static let backends: [(prefix: String, port: Int, name: String)] = [
        ("/users", 8081, "identity"),
        ("/videos", 8082, "catalog"),
        ("/subscriptions", 8083, "subscriptions"),
        ("/analytics", 8084, "analytics"),
    ]

    static func main() async throws {
        let router = Router()

        // Health check route
        router.get("/health") { _, _ -> Response in
            try await healthCheck()
        }

        // Proxy middleware handles all other requests
        router.addMiddleware { ProxyMiddleware(backends: backends) }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: 8080))
        )

        print("WarblerProxy starting on http://localhost:8080")
        print("Routing:")
        for b in backends {
            print("  \(b.prefix)/* → localhost:\(b.port) (\(b.name))")
        }
        print("")
        try await app.runService()
    }

    static func healthCheck() async throws -> Response {
        var services: [(String, String)] = []
        var allHealthy = true

        for backend in backends {
            let url = "http://localhost:\(backend.port)/"
            var request = HTTPClientRequest(url: url)
            request.method = .GET

            let status: String
            do {
                let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
                _ = try? await response.body.collect(upTo: 1024)
                status = "up"
            } catch {
                status = "down"
                allHealthy = false
            }
            services.append((backend.name, status))
        }

        var json = #"{"status":"\#(allHealthy ? "healthy" : "degraded")","services":{"#
        json += services.map { #""\#($0.0)":"\#($0.1)""# }.joined(separator: ",")
        json += "}}"

        return Response(
            status: allHealthy ? .ok : .serviceUnavailable,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }
}

struct ProxyMiddleware: RouterMiddleware {
    let backends: [(prefix: String, port: Int, name: String)]

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

        print("\(request.method) \(path) → :\(backend.port) (\(backend.name)) → \(response.status.code) [\(elapsed)]")

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
            let response = try await HTTPClient.shared.execute(clientRequest, timeout: .seconds(30))

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
