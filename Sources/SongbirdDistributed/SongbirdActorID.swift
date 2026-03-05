import Distributed

/// A process-aware identity for distributed actors in the Songbird system.
///
/// Each actor is identified by the process it lives in (`processName`) and a
/// local name within that process (`actorName`). The process name corresponds
/// to the worker executable (e.g., "identity-worker") and determines which
/// Unix domain socket to route calls to.
public struct SongbirdActorID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The name of the process that owns this actor (e.g., "identity-worker").
    public let processName: String
    /// The local name of the actor within its process (e.g., "command-handler").
    public let actorName: String

    public init(processName: String, actorName: String) {
        self.processName = processName
        self.actorName = actorName
    }

    public var description: String {
        "\(processName)/\(actorName)"
    }
}
