import Foundation

/// Messages exchanged over the Unix domain socket between gateway and workers.
///
/// All messages are length-prefixed (4-byte big-endian UInt32) followed by a JSON body.
/// Request/response pairs are matched by `requestId`.
enum WireMessage: Codable {
    case call(Call)
    case result(Result)
    case error(ErrorResult)

    struct Call: Codable {
        let requestId: UInt64
        let actorName: String
        let targetName: String
        let arguments: Data
    }

    struct Result: Codable {
        let requestId: UInt64
        let value: Data
    }

    struct ErrorResult: Codable {
        let requestId: UInt64
        let message: String
    }

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum MessageType: String, Codable {
        case call, result, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .call(let call):
            try container.encode(MessageType.call, forKey: .type)
            try container.encode(call, forKey: .payload)
        case .result(let result):
            try container.encode(MessageType.result, forKey: .type)
            try container.encode(result, forKey: .payload)
        case .error(let error):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(error, forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .call:
            self = .call(try container.decode(Call.self, forKey: .payload))
        case .result:
            self = .result(try container.decode(Result.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(ErrorResult.self, forKey: .payload))
        }
    }
}

/// Errors specific to the SongbirdDistributed module.
public enum SongbirdDistributedError: Error, CustomStringConvertible {
    case actorNotFound(SongbirdActorID)
    case invalidArgumentEncoding
    case argumentCountMismatch
    case remoteCallFailed(String)
    case connectionFailed(String)
    case notConnected(String)

    public var description: String {
        switch self {
        case .actorNotFound(let id): "Actor not found: \(id)"
        case .invalidArgumentEncoding: "Invalid argument encoding (expected base64)"
        case .argumentCountMismatch: "Argument count mismatch during decoding"
        case .remoteCallFailed(let msg): "Remote call failed: \(msg)"
        case .connectionFailed(let msg): "Connection failed: \(msg)"
        case .notConnected(let process): "Not connected to process: \(process)"
        }
    }
}
