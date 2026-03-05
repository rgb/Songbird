import Distributed
import Foundation

/// Deserializes distributed function call arguments from a JSON byte buffer.
///
/// Arguments are decoded one at a time in the order they were encoded by
/// `SongbirdInvocationEncoder`. Each call to `decodeNextArgument` advances
/// the internal cursor.
public final class SongbirdInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable

    private let argumentChunks: [Data]
    private var index: Int = 0

    public init(data: Data) throws {
        let base64Args = try JSONDecoder().decode([String].self, from: data)
        self.argumentChunks = try base64Args.map { base64 in
            guard let data = Data(base64Encoded: base64) else {
                throw SongbirdDistributedError.invalidArgumentEncoding
            }
            return data
        }
    }

    public func decodeGenericSubstitutions() throws -> [Any.Type] {
        []  // No generic support
    }

    public func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard index < argumentChunks.count else {
            throw SongbirdDistributedError.argumentCountMismatch
        }
        let data = argumentChunks[index]
        index += 1
        return try JSONDecoder().decode(Argument.self, from: data)
    }

    public func decodeErrorType() throws -> Any.Type? {
        nil  // Errors transmitted as strings
    }

    public func decodeReturnType() throws -> Any.Type? {
        nil  // Return type inferred from target
    }
}
