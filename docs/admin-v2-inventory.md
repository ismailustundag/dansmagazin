# DansMagazin Admin V2 Inventory

## Scope

Admin V2 replaces the legacy panel without changing the ticketing, guest,
notification, store, news, poll, or social-feed contracts. The event photo
album and face-recognition product is retired separately after its callers are
removed.

## Navigation and ownership

| Area | Source of truth | Admin V2 route | Legacy route |
| --- | --- | --- | --- |
| Overview | PostgreSQL + mobile API | `/admin-v2/overview` | mixed |
| Events | mobile backend | `/admin-v2/events` | `/admin/mobile?tab=events` |
| Guest lists | mobile backend | `/admin-v2/guests` | `/admin/mobile?tab=events&view=guest-lists` |
| Users | shared PostgreSQL | `/admin-v2/users` | `/admin/users` |
| Social feed | mobile backend | `/admin-v2/feed` | report-only |
| News | mobile backend | `/admin-v2/news` | `/admin/mobile?tab=news` |
| Store | mobile backend | `/admin-v2/store` | embedded in reports/targets |
| Polls | mobile backend | `/admin-v2/polls` | embedded in reports/targets |
| Notifications | mobile backend | `/admin-v2/notifications` | `/admin/mobile?tab=notifications` |
| Reports | shared PostgreSQL | `/admin-v2/reports` | `/admin/mobile?tab=reports` |
| Settings | service configuration | `/admin-v2/settings` | scattered |

## Retired photo product

The following are removed after backups and caller verification:

- selfie registration and face matching
- event albums and subalbums
- upload/match/reprocess jobs and frames
- personal gallery tokens and gallery email flow
- photo credits
- album and legacy event-photo reactions/favorites
- mobile album and My Photos screens and deep links

The following are explicitly preserved:

- profile avatars
- event and news covers
- store product images
- community feed posts and their media
- photo polls
- ticket and QR images

## Data baseline (2026-07-29)

The live database backup and source/media archive were verified before work
started. The face and event-album data tables had no active rows:

- `event_photos`: 0
- `photo_matches`: 0
- `users`: 0
- `jobs`: 0
- `event_subalbums`: 0
- `selfie_embeddings`: 0
- `photo_face_embeddings`: 0
- album and legacy photo reactions/favorites: 0

`saas_events` still has legacy event mappings and must not be dropped until all
admin/event callers have moved away from it.

## Release gates

1. Admin V2 is deployed in parallel under `/admin-v2`.
2. Every non-photo legacy action has a tested Admin V2 equivalent.
3. Mobile routes no longer reference albums or My Photos.
4. Feed and polls remain healthy after the album router split.
5. A database dump and media archive pass integrity checks.
6. Only then can the legacy photo console and its runtime dependencies stop.

