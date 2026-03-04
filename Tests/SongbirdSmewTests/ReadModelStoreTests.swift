import Testing
import Smew

@testable import SongbirdSmew

private struct Widget: Decodable, Equatable {
    let id: Int64
    let name: String
}

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

    @Test func queryDecodesRows() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE widgets (id INTEGER, name VARCHAR)")
            try conn.execute("INSERT INTO widgets VALUES (1, 'Sprocket')")
            try conn.execute("INSERT INTO widgets VALUES (2, 'Gear')")
        }
        let widgets: [Widget] = try await store.query(Widget.self) {
            "SELECT id, name FROM widgets ORDER BY id"
        }
        #expect(widgets.count == 2)
        #expect(widgets[0] == Widget(id: 1, name: "Sprocket"))
        #expect(widgets[1] == Widget(id: 2, name: "Gear"))
    }

    @Test func queryFirstReturnsSingleRow() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE items (item_id INTEGER, item_name VARCHAR)")
            try conn.execute("INSERT INTO items VALUES (1, 'Alpha')")
        }
        struct Item: Decodable, Equatable {
            let itemId: Int64
            let itemName: String
        }
        let item: Item? = try await store.queryFirst(Item.self) {
            "SELECT item_id, item_name FROM items WHERE item_id = \(param: Int64(1))"
        }
        #expect(item == Item(itemId: 1, itemName: "Alpha"))
    }

    @Test func queryFirstReturnsNilWhenEmpty() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE empty_table (id INTEGER)")
        }
        struct Row: Decodable { let id: Int64 }
        let result: Row? = try await store.queryFirst(Row.self) {
            "SELECT id FROM empty_table"
        }
        #expect(result == nil)
    }
}
