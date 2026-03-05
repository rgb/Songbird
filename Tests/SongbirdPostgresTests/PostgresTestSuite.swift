import Testing

/// Parent suite that serializes all PostgreSQL tests.
/// Tests share a single database, so they must not run concurrently.
@Suite(.serialized)
struct AllPostgresTests {}
