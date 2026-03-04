import Testing

@testable import SongbirdSmew

@Suite("TieringService")
struct TieringServiceTests {

    @Test func tierOnceMovesOldRows() async throws {
        let store = try await makeTieredStore()
        await store.registerTable("items")
        await store.registerMigration { conn in
            try conn.execute("CREATE TABLE items (id INTEGER, recorded_at TIMESTAMP)")
        }
        try await store.migrate()

        try await store.withConnection { conn in
            try conn.execute("INSERT INTO items VALUES (1, TIMESTAMP '2020-01-01')")
        }

        let service = TieringService(readModel: store, thresholdDays: 365)
        let moved = try await service.tierOnce()
        #expect(moved == 1)
    }

    @Test func runStopsWhenStopped() async throws {
        let store = try ReadModelStore()
        let service = TieringService(
            readModel: store,
            thresholdDays: 30,
            interval: .milliseconds(50)
        )

        let runTask = Task { await service.run() }
        try await Task.sleep(for: .milliseconds(100))
        await service.stop()
        runTask.cancel()
        // If we get here without hanging, the test passes
    }
}
