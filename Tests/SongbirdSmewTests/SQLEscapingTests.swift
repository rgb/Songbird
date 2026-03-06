@testable import SongbirdSmew
import Testing

@Suite("SQL Escaping")
struct SQLEscapingTests {
    // MARK: - escapeSQLString

    @Test("escapeSQLString passes through plain strings")
    func plainString() {
        #expect(escapeSQLString("hello world") == "hello world")
    }

    @Test("escapeSQLString doubles single quotes")
    func singleQuotes() {
        #expect(escapeSQLString("O'Brien") == "O''Brien")
    }

    @Test("escapeSQLString handles multiple single quotes")
    func multipleSingleQuotes() {
        #expect(escapeSQLString("it's a 'test'") == "it''s a ''test''")
    }

    @Test("escapeSQLString handles empty string")
    func emptyString() {
        #expect(escapeSQLString("") == "")
    }

    @Test("escapeSQLString handles string of only quotes")
    func onlyQuotes() {
        #expect(escapeSQLString("'''") == "''''''")
    }

    @Test("escapeSQLString does not escape double quotes")
    func doubleQuotesUntouched() {
        #expect(escapeSQLString("say \"hello\"") == "say \"hello\"")
    }

    @Test("escapeSQLString handles path with single quote")
    func pathWithQuote() {
        #expect(escapeSQLString("/data/user's/catalog.db") == "/data/user''s/catalog.db")
    }

    // MARK: - escapeSQLIdentifier

    @Test("escapeSQLIdentifier passes through plain strings")
    func identifierPlain() {
        #expect(escapeSQLIdentifier("my_table") == "my_table")
    }

    @Test("escapeSQLIdentifier doubles double quotes")
    func identifierDoubleQuotes() {
        #expect(escapeSQLIdentifier("my\"table") == "my\"\"table")
    }

    @Test("escapeSQLIdentifier handles multiple double quotes")
    func identifierMultipleQuotes() {
        #expect(escapeSQLIdentifier("a\"b\"c") == "a\"\"b\"\"c")
    }

    @Test("escapeSQLIdentifier handles empty string")
    func identifierEmpty() {
        #expect(escapeSQLIdentifier("") == "")
    }

    @Test("escapeSQLIdentifier does not escape single quotes")
    func identifierSingleQuotesUntouched() {
        #expect(escapeSQLIdentifier("it's") == "it's")
    }
}
