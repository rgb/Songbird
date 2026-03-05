# LISTEN/NOTIFY Subscriptions + S3 Cloud Tiering

## PostgresEventSubscription

Added `PostgresEventSubscription` to `SongbirdPostgres` — a LISTEN/NOTIFY-based `AsyncSequence<RecordedEvent>` that is a drop-in replacement for the polling-based `EventSubscription`.

- **Dedicated LISTEN connection**: Uses a standalone `PostgresConnection` (not from pool) for `LISTEN songbird_events`
- **Hybrid wakeup**: LISTEN for near-instant delivery, fallback poll (default 5s) as safety net
- **Auto-reconnect**: If fallback poll detects missed notifications, the LISTEN connection is re-established
- **Same API shape**: `AsyncSequence<RecordedEvent>` with subscriberId, categories, positionStore, batchSize

## S3 Cloud Tiering

Extended `DuckLakeConfig.Backend` with `.s3(S3Config)` for S3-compatible cold-tier storage.

- **S3Config**: region, accessKeyId, secretAccessKey, endpoint, useSsl — nil fields fall back to AWS env vars
- **ReadModelStore**: Automatically loads httpfs extension and configures DuckDB S3 settings on init
- **Compatible stores**: AWS S3, rustfs, Garage, MinIO, Cloudflare R2 (via endpoint override)
- **Tiering unchanged**: `tierProjections(olderThan:)` works transparently — DuckLake handles S3 I/O
