import Testing
import Smew

@testable import SongbirdSmew

@Suite("ReadModelStore")
struct ReadModelStoreTests {

    @Test func initializesInMemory() async throws {
        let store = try ReadModelStore()
        let result = try await store.withConnection { conn in
            try conn.query("SELECT 42 AS value").scalarInt64()
        }
        #expect(result == 42)
    }

    @Test func withConnectionProvidesAccess() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE test (id INTEGER, name VARCHAR)")
            try conn.execute("INSERT INTO test VALUES (1, 'hello')")
        }
        let count = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM test").scalarInt64()
        }
        #expect(count == 1)
    }
}
