public protocol CommandHandler {
    associatedtype Agg: Aggregate
    associatedtype Cmd: Command

    static func handle(
        _ command: Cmd,
        given state: Agg.State
    ) throws(Agg.Failure) -> [Agg.Event]
}
