# Warbler Demo App

A full-featured video tutorial platform that demonstrates every Songbird primitive in a realistic, end-to-end application.

**Design doc:** `docs/plans/2026-03-04-warbler-demo-app-design.md`
**Implementation plan:** `docs/plans/2026-03-04-warbler-demo-app-implementation.md`

## Overview

Warbler is a Hummingbird-based HTTP application in `demo/warbler/` that showcases Songbird's event-sourced architecture across four bounded contexts: Identity, Catalog, Subscriptions, and Analytics. It serves as both a reference implementation and a validation of the framework's APIs.

## Bounded Contexts

### Identity (`WarblerIdentity`)

- **UserAggregate** — validates registration, profile updates, and deactivation
- **UserProjector** — materializes `users` table in DuckDB read model
- Commands: `RegisterUser`, `UpdateProfile`, `DeactivateUser`
- Events: `UserEvent` (registered, profileUpdated, deactivated)

### Catalog (`WarblerCatalog`)

- **VideoAggregate** — state machine (initial → transcoding → published → unpublished)
- **VideoCatalogProjector** — materializes `videos` table
- **Event Versioning** — `VideoPublishedV1` with `VideoPublishedUpcast` (v1 → v2)
- Commands: `PublishVideo`, `UpdateVideoMetadata`, `CompleteTranscoding`, `UnpublishVideo`
- Events: `VideoEvent` (v2 with `creatorId`), `VideoPublishedV1` (legacy)

### Subscriptions (`WarblerSubscriptions`)

- **SubscriptionLifecycleProcess** — process manager coordinating subscription workflow
- **EmailNotificationGateway** — gateway for outbound email notifications
- **SubscriptionProjector** — materializes `subscriptions` table
- Reactions: `OnSubscriptionRequested`, `OnPaymentConfirmed`, `OnPaymentFailed`
- Events: `SubscriptionEvent` (requested, paymentConfirmed, paymentFailed), `SubscriptionLifecycleEvent` (accessGranted, cancelled)

### Analytics (`WarblerAnalytics`)

- **PlaybackAnalyticsProjector** — materializes `video_views` table with tiered storage
- **ViewCountAggregate** — aggregate with `Codable` state for snapshot support
- **PlaybackInjector** — injector for external event ingestion via `AsyncStream`
- Events: `AnalyticsEvent` (videoViewed), `ViewCountEvent` (viewed)

## Songbird Primitives Demonstrated

| Primitive | Warbler Usage |
|-----------|---------------|
| Aggregate | `UserAggregate`, `VideoAggregate`, `ViewCountAggregate` |
| CommandHandler | 7 command handlers across Identity and Catalog |
| Projector | `UserProjector`, `VideoCatalogProjector`, `SubscriptionProjector`, `PlaybackAnalyticsProjector` |
| Process Manager | `SubscriptionLifecycleProcess` with 3 event reactions |
| Gateway | `EmailNotificationGateway` for welcome/cancellation emails |
| Injector | `PlaybackInjector` for analytics event ingestion |
| Event Versioning | `VideoPublishedV1` → `VideoEvent` upcast |
| Snapshots | `ViewCountAggregate` with `everyNEvents(100)` policy |
| Tiered Storage | `PlaybackAnalyticsProjector` registers `video_views` for tiering |
| SongbirdHummingbird | `executeAndProject`, `appendAndProject`, middleware, request context |

## HTTP Endpoints

### Identity
- `POST /users/{id}` — register user
- `GET /users/{id}` — get user profile
- `PATCH /users/{id}` — update display name
- `DELETE /users/{id}` — deactivate user

### Catalog
- `POST /videos/{id}` — publish video
- `GET /videos` — list all videos
- `GET /videos/{id}` — get video details
- `PATCH /videos/{id}` — update metadata
- `POST /videos/{id}/transcode-complete` — mark transcoding done
- `DELETE /videos/{id}` — unpublish video

### Subscriptions
- `POST /subscriptions/{id}` — request subscription
- `GET /subscriptions/{userId}` — list user subscriptions
- `POST /subscriptions/{id}/pay` — confirm payment

### Analytics
- `POST /analytics/views` — record video view (via injector)
- `GET /analytics/videos/{id}/views` — get view count
- `GET /analytics/top-videos` — top 10 videos by views

## Test Suite

45 tests across 11 test suites covering all aggregates, projectors, process managers, gateways, and injectors.

## Package Structure

```
demo/warbler/
├── Package.swift
├── Sources/
│   ├── Warbler/          # Executable target (main.swift)
│   ├── WarblerIdentity/  # Identity bounded context
│   ├── WarblerCatalog/   # Catalog bounded context
│   ├── WarblerSubscriptions/ # Subscriptions bounded context
│   └── WarblerAnalytics/ # Analytics bounded context
└── Tests/
    ├── WarblerIdentityTests/
    ├── WarblerCatalogTests/
    ├── WarblerSubscriptionsTests/
    └── WarblerAnalyticsTests/
```
