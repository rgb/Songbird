# 0001 — Project Scaffold

Set up the Songbird repository with:

- `Package.swift` (Swift 6.2+, macOS 14+) with multi-module structure planned:
  - `Songbird` — Core protocols and types (active)
  - `SongbirdSQLite` — SQLite event store (future)
  - `SongbirdSmew` — DuckDB read model via Smew (future)
  - `SongbirdHummingbird` — Hummingbird integration (future)
  - `SongbirdTesting` — In-memory implementations and test utilities (future)
- `.gitignore` excluding local reference materials (ether/, smew/, *.epub)
- `concept/` and `changelog/` folders
- `CLAUDE.md` with project overview, architecture notes, and conventions
- `books.md` with comparative analysis of two event sourcing reference books
- `plan.md` with the phased evolution plan
- `research/` with Swift concurrency learning materials
