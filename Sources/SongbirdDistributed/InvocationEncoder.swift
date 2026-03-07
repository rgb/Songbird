import Distributed
import Foundation

/// Serializes distributed function call arguments into a JSON byte buffer.
///
/// Each argument is JSON-encoded individually and collected into an array.
/// The complete invocation (target name + arguments) is sent as a `WireMessage.Call`.
public struct SongbirdInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable

    private let encoder = JSONEncoder()
    var targetName: String = ""
    var arguments: [Data] = []

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        // We don't support generic distributed functions in Songbird.
        // All distributed funcs use concrete Codable types.
    }

    public mutating func recordArgument<Value: Codable>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        let data = try encoder.encode(argument.value)
        arguments.append(data)
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
        // No-op: we transmit errors as strings
    }

    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {
        // No-op: return type is known from the target
    }

    public mutating func doneRecording() throws {
        // No-op: arguments are already collected
    }

    /// Serializes all recorded arguments into a single Data blob (JSON array of base64 chunks).
    func encodeArguments() throws -> Data {
        let base64Args = arguments.map { $0.base64EncodedString() }
        return try encoder.encode(base64Args)
    }
}
