public protocol EventStore: Sendable {
    func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent

    func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent]

    func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent]

    func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent?

    func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64
}

public struct VersionConflictError: Error, CustomStringConvertible {
    public let streamName: StreamName
    public let expectedVersion: Int64
    public let actualVersion: Int64

    public init(streamName: StreamName, expectedVersion: Int64, actualVersion: Int64) {
        self.streamName = streamName
        self.expectedVersion = expectedVersion
        self.actualVersion = actualVersion
    }

    public var description: String {
        "Version conflict on stream \(streamName): expected \(expectedVersion), actual \(actualVersion)"
    }
}
