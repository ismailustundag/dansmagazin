# Event location filters (local review, not deployed)

## API

`GET /events/filter-options` returns `countries` (`code`, `name`) and `cities`
(`country_code`, `city_id`, `city`, `legacy_location`). It queries all approved,
active, current events, independently of the event list's limit. Optional
`event_kind` and comma-separated `dance_styles` use the same predicates as the
event list. No persistent options cache is used. Mobile fetches the catalog each
time the filter opens, with visible loading/error handling.

`GET /events` retains `city`, `event_kind`, `dance_styles` and `limit`, adding
`country_code` and `city_id`. All specified dimensions are ANDed; selected dance
styles retain the existing OR behavior. Country `__unknown__` explicitly selects
records without country metadata; omitted country/city selects all. Current
means the end date (or event/start date) is today or later in the existing event
date convention. Undated/unparseable records cannot contribute location options.
Multi-day events are not expired merely because their start date is in the past.

## Identity and compatibility

Additive nullable columns on `mobile_event_submissions`: `country_code TEXT`,
`city_id TEXT`, plus a partial approved-event index. Existing rows are not rewritten.
ISO alpha-2 country codes are validated and stored uppercase. Some display country
names are localized; other countries display their ISO code.

No geographic guessing, accent folding, transliteration or splitting on `/` is
performed. `Massanassa / Valencia` remains exactly that legacy locality, with no
inferred country. Unclassified records appear under “Ülkesi belirtilmemiş”. Legacy
identity is `text:` plus MD5 of country, U+001F and trimmed original city text.
This denotes a text bucket, not a verified geographic ID; historical homonyms
cannot be resolved without explicit operator metadata.

Known provider IDs are preserved. New manually entered locations with a country
receive an opaque `manual:` UUID. Choosing an existing suggestion reuses its ID.
Thus identical labels need not imply the same place. Country is always part of
the selection. Editing an unrelated field preserves the location; changing a
location without selecting an identity resets it. Copies and weekly instances
inherit metadata. Profile city selection is unchanged.

## UI

Discover uses server-provided country then city options, including all-country
and all-city choices. Requests include identities rather than labels. Event
create/edit uses the same suggestions, with free-text locality and ISO country
entry for places without published events. Unrecognized legacy cities are no
longer overwritten with “Belirtilmedi”. Admin-v2 forms/proxy also accept metadata.

## Validation and release order

Python unit tests: `python3 -m unittest discover -s mobil_backend/tests -p 'test_event*.py'`.
SQL integration: `tests/event_locations_postgres.mjs` uses an isolated PGlite
PostgreSQL engine (`PGLITE_MODULE` points to its index.js); no live database.
Tests cover 650+ locations, Unicode text identity, active/approval conditions,
compound filters, new publications, repeated migration and distinct homonyms.
Flutter tests: event_locations_test, event_location_picker_test,
event_filters_widget_test (390x844). Admin-v2 TypeScript/Vite build is local.

Before rollout: preserve live-only backend changes, back up the database, apply
the additive migration (also present in startup initialization), deploy backend
and panel, verify options against real production records, then release mobile.
One mobile release is required to introduce the new UI. Subsequent countries and
cities arrive from the server without another release. No live deployment,
database migration or store submission was performed for this change.
