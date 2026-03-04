# Warbler Demo App Design

## Overview

Warbler is a video tutorial platform demo app that showcases every Songbird feature. Inspired by Garofolo's "Practical Microservices" video streaming service, adapted to demonstrate Songbird's event-sourced CQRS patterns in a single-executable Hummingbird application.

**Name:** Warbler (bird theme: Songbird framework, Hummingbird web, Smew DuckDB, Warbler demo)

**Scope:** API only — no frontend, no real email sending. Four bounded contexts, each demonstrating different Songbird features.

## Package Structure

Lives in `demo/warbler/` as its own Swift package with a local path dependency on Songbird.

```
demo/warbler/
├── Package.swift
├── Sources/
│   ├── Warbler/                # Executable — Hummingbird app, routes, bootstrap
│   ├── WarblerIdentity/        # Domain: users & authentication
│   ├── WarblerCatalog/         # Domain: videos & creator portal
│   ├── WarblerSubscriptions/   # Domain: subscription plans & billing
│   └── WarblerAnalytics/       # Domain: playback tracking & view counts
└── Tests/
    ├── WarblerIdentityTests/
    ├── WarblerCatalogTests/
    ├── WarblerSubscriptionsTests/
    └── WarblerAnalyticsTests/
```

**Dependencies:**
- Domain modules depend on `Songbird` (core types) only
- `Warbler` executable depends on all domain modules + `SongbirdSQLite` + `SongbirdSmew` + `SongbirdHummingbird`
- Test targets depend on `SongbirdTesting`

## Domain Model

Each domain naturally showcases different Songbird features:

| Domain | Primary Pattern | Also Showcases |
|--------|----------------|----------------|
| **Identity** | Aggregate + CommandHandler | Projector, basic CQRS read/write split |
| **Catalog** | Aggregate + CommandHandler | Event Versioning (upcast chain), Projector |
| **Subscriptions** | Process Manager | Gateway (mock email notifications), cross-domain coordination |
| **Analytics** | Projector (no aggregate) | Tiered Storage, Snapshots, Injector (simulated playback events) |

### Identity Domain

Users and authentication. Demonstrates the basic event sourcing cycle.

**Aggregate:** `UserAggregate`
- State: `userId`, `email`, `displayName`, `isActive`
- Validates: no duplicate registration, no commands on deactivated users

**Events:**
- `UserRegistered(userId, email, displayName)`
- `ProfileUpdated(displayName)`
- `UserDeactivated`

**Commands:**
- `RegisterUser(email, displayName)`
- `UpdateProfile(displayName)`
- `DeactivateUser`

**Projector:** `UserProjector` → `users` table (id, email, display_name, is_active)

### Catalog Domain

Video publishing and creator portal. Demonstrates event versioning.

**Aggregate:** `VideoAggregate`
- State: `videoId`, `title`, `description`, `creatorId`, `status` (draft → transcoding → published → unpublished)
- Validates: state machine transitions (e.g., can't unpublish a draft)

**Events:**
- `VideoPublished_v1(videoId, title, creatorId)` — original version
- `VideoPublished(videoId, title, description, creatorId)` — current version (v2)
- `VideoMetadataUpdated(title, description)`
- `TranscodingCompleted`
- `VideoUnpublished`

**Event Versioning:** `VideoPublished_v1` → `VideoPublished` upcast (adds empty description)

**Commands:**
- `PublishVideo(title, description, creatorId)`
- `UpdateVideoMetadata(title, description)`
- `CompleteTranscoding`
- `UnpublishVideo`

**Projector:** `VideoCatalogProjector` → `videos` table (id, title, description, creator_id, status)

### Subscriptions Domain

Subscription lifecycle management. Demonstrates process managers and gateways.

**Process Manager:** `SubscriptionLifecycleProcess`
- State: `status` (requested → paymentPending → active | cancelled)
- Consumes: `SubscriptionRequested`, `PaymentInitiated`, `PaymentConfirmed`, `PaymentFailed`
- Emits: `AccessGranted`, `SubscriptionCancelled`

**Gateway:** `EmailNotificationGateway`
- Listens for `AccessGranted`, `SubscriptionCancelled`
- Logs "would send email to {userId}" (no real email)

**Projector:** `SubscriptionProjector` → `subscriptions` table (id, user_id, plan, status)

### Analytics Domain

Playback tracking and view counts. Demonstrates injector, tiered storage, and snapshots.

**Injector:** `PlaybackInjector`
- Simulates external playback events arriving from a video player client

**Events:**
- `VideoViewed(videoId, userId, watchedSeconds)`

**Projector:** `PlaybackAnalyticsProjector` → `video_views` table (video_id, user_id, watched_seconds, recorded_at)
- Table registered for tiered storage — old views move to cold tier
- Queries via `v_video_views` span both tiers transparently

**Aggregate:** `ViewCountAggregate`
- Lightweight aggregate tracking total views per video
- Snapshot policy: every 100 events (demonstrates snapshot optimization)

## HTTP API

```
POST   /users                           → RegisterUser
GET    /users/:id                        → Query UserProjector
PATCH  /users/:id                        → UpdateProfile
DELETE /users/:id                        → DeactivateUser

POST   /videos                           → PublishVideo
GET    /videos                           → Query VideoCatalogProjector (list)
GET    /videos/:id                       → Query VideoCatalogProjector (detail)
PATCH  /videos/:id                       → UpdateVideoMetadata
POST   /videos/:id/transcode-complete    → CompleteTranscoding
DELETE /videos/:id                       → UnpublishVideo

POST   /subscriptions                    → SubscriptionRequested (starts process)
GET    /subscriptions/:userId            → Query SubscriptionProjector
POST   /subscriptions/:id/pay            → PaymentConfirmed (simulates payment)

POST   /analytics/views                  → Inject VideoViewed via PlaybackInjector
GET    /analytics/videos/:id/views       → Query view count
GET    /analytics/top-videos             → Query top videos by view count
```

**Bootstrap flow (main.swift):**
1. Create `SQLiteEventStore` + `EventTypeRegistry` (register all event types + upcasts)
2. Create `ReadModelStore` with tiered mode for analytics tables
3. Create `SongbirdServices` wiring event store, pipeline, position store, registry
4. Register all projectors, process managers, gateways, injectors
5. Configure Hummingbird with `RequestIdMiddleware` + `ProjectionFlushMiddleware`
6. Register routes per domain
7. Start the app (`services.run()`)

**Route patterns:**
- Command routes use `executeAndProject()`
- Event-only routes use `appendAndProject()`
- Query routes use `readModel.query()` / `readModel.queryFirst()`

## Testing Strategy

Each domain module has its own test target using Songbird's test harnesses exclusively. No SQLite, no DuckDB, no HTTP — pure domain logic.

**Identity Tests:**
- `UserAggregateTests` (TestAggregateHarness) — register, update, deactivate; reject invalid commands
- `UserProjectorTests` (TestProjectorHarness) — feed events, verify projected read model

**Catalog Tests:**
- `VideoAggregateTests` (TestAggregateHarness) — state machine transitions, rejection rules
- `VideoCatalogProjectorTests` (TestProjectorHarness) — feed events, verify read model
- `VideoEventUpcastTests` — verify v1→v2 upcast produces correct event

**Subscription Tests:**
- `SubscriptionProcessTests` (TestProcessManagerHarness) — happy path, sad path
- `EmailNotificationGatewayTests` (TestGatewayHarness) — verify event→notification mapping

**Analytics Tests:**
- `PlaybackAnalyticsProjectorTests` (TestProjectorHarness) — feed view events, verify counts
- `ViewCountAggregateTests` (TestAggregateHarness) — count tracking, snapshot serialization

## Feature Coverage Matrix

| Songbird Feature | Where in Warbler |
|------------------|-----------------|
| Aggregate + CommandHandler | Identity, Catalog, Analytics |
| Projector | All 4 domains |
| Process Manager | Subscriptions (SubscriptionLifecycleProcess) |
| Gateway | Subscriptions (EmailNotificationGateway) |
| Injector | Analytics (PlaybackInjector) |
| Event Versioning | Catalog (VideoPublished v1→v2) |
| Snapshots | Analytics (ViewCountAggregate, every 100 events) |
| Tiered Storage | Analytics (video_views, hot/cold with UNION ALL view) |
| SongbirdServices | Warbler executable (full lifecycle wiring) |
| RequestIdMiddleware | Warbler executable |
| ProjectionFlushMiddleware | Warbler executable |
| appendAndProject | Subscriptions, Analytics routes |
| executeAndProject | Identity, Catalog routes |
| TestAggregateHarness | Identity, Catalog, Analytics tests |
| TestProjectorHarness | All 4 domain tests |
| TestProcessManagerHarness | Subscriptions tests |
| TestGatewayHarness | Subscriptions tests |

## Future: Multi-Executable Version

After Warbler is complete, a second demo app could split the domains into separate executables sharing the same SQLite event store, closer to Garofolo's microservices architecture. This would demonstrate how Songbird supports distributed deployment without changing domain logic.

## Known Limitations

- No real authentication — user IDs are passed in request bodies
- No real payment processing — payment confirmation is a manual API call
- No real email — gateway logs messages instead of sending
- No frontend — API only, test with curl/httpie
- Tiered storage uses simulated DuckLake in tests (ATTACH ':memory:' AS lake)
