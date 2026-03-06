/// Escapes a string for use in SQL string literals (single-quoted values).
/// Doubles any single quotes: `O'Brien` -> `O''Brien`.
func escapeSQLString(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

/// Escapes a string for use as a SQL identifier (double-quoted).
/// Doubles any double quotes: `my"table` -> `my""table`.
func escapeSQLIdentifier(_ value: String) -> String {
    value.replacingOccurrences(of: "\"", with: "\"\"")
}
