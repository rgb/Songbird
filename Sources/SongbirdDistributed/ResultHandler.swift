import Distributed
import Foundation

/// Captures the result of a distributed function invocation on the receiving side.
///
/// After `executeDistributedTarget` completes, the result handler holds either the
/// serialized return value or error message, ready to be sent back as a `WireMessage`.
public final class SongbirdResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable

    /// The serialized return value, or nil if the call was void or threw an error.
    public private(set) var resultData: Data?
    /// The error message if the call threw.
    public private(set) var errorMessage: String?
    /// Whether the call completed successfully (including void returns).
    public private(set) var isSuccess: Bool = false

    public init() {}

    public func onReturn<Success: Codable>(value: Success) async throws {
        resultData = try JSONEncoder().encode(value)
        isSuccess = true
    }

    public func onReturnVoid() async throws {
        resultData = nil
        isSuccess = true
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        errorMessage = String(describing: error)
        isSuccess = false
    }
}
