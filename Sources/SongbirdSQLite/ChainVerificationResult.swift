public struct ChainVerificationResult: Sendable, Equatable {
    public let intact: Bool
    public let eventsVerified: Int
    public let brokenAtSequence: Int64?

    public init(intact: Bool, eventsVerified: Int, brokenAtSequence: Int64? = nil) {
        self.intact = intact
        self.eventsVerified = eventsVerified
        self.brokenAtSequence = brokenAtSequence
    }
}
