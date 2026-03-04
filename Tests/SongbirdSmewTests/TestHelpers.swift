@testable import SongbirdSmew

/// Creates a ReadModelStore with a simulated cold tier for testing.
/// Uses `ATTACH ':memory:' AS lake` instead of real DuckLake.
func makeTieredStore() async throws -> ReadModelStore {
    let store = try ReadModelStore()
    try await store.withConnection { conn in
        try conn.execute("ATTACH ':memory:' AS lake")
    }
    await store.enableTieredModeForTesting()
    return store
}
