# Mobile news after the static-site migration

The mobile API reads `STATIC_NEWS_FILE` when configured. Without that setting,
the existing WordPress integration remains in effect. Both list and detail
responses preserve the mobile contract and original post IDs.

Live file: `/home/ubuntu/mobil_backend/data/static-news.json`.
Systemd setting: `/etc/systemd/system/mobil-backend.service.d/static-news.conf`.
Rollback copy: `/home/ubuntu/backups/news-20260929/discover.original.py`.

The initial feed contains 51 published posts from the 2026-09-07 migration
snapshot. `ops/export_static_news.py SOURCE OUTPUT` exports public posts and
uses the adjacent `media.json` for covers.

`dansmagazin-news-sync.timer` now runs `ops/sync_static_news.py` every minute.
It reads published `*/index.html` article pages under
`/srv/dansmagazin-static/current`, retaining original IDs and assigning stable
integer IDs to new articles. Classification uses `static-news-catalog.json`
beside the feed, generated from the original WordPress posts/pages export.
Known ordinary pages are excluded even if the template uses og:type=article.
New news pages must explicitly include
`<meta name="dm:content-type" content="news">` or be added to the catalog's
`news_paths`. Generic article markup alone is insufficient. New articles, subsequent edits and removed tracked
pages propagate atomically to the feed. Complete archive text is preserved on
the first discovery of an existing page. An empty site scan fails without
replacing the feed. List cache expires within 90 seconds, giving a normal
publication delay of up to about three minutes. This consumes published HTML;
Panel publishing now uses `app/static_news.py` whenever STATIC_NEWS_FILE is set.
Approval writes an explicitly classified static article, the mobile feed, and
cards on the homepage/news index. Approved edits update the same post ID;
deletion archives the HTML and removes the entry. Synchronization and publishing
share a file lock. Legacy automatic pruning is disabled in static mode.
New panel IDs use 500000000 + submission ID; original WordPress IDs are retained
when editing existing entries. Rollback code/feed and HTML backup:
`/home/ubuntu/backups/news-publish-20261010/`.

Missing covers are recovered from uploaded static-export assets and existing
news_submission_covers directories. Equivalent image variants are reused when
available; unrecoverable originals use the site logo and are logged by systemd.
Run `ops/check_news_images.py` to verify every unique public cover URL.
The pre-sync feed is backed up at
`/home/ubuntu/backups/news-sync-20260929/static-news.before.json`.
Stop/disable `dansmagazin-news-sync.timer` before restoring that feed.

Rollback: restore the original discover.py, remove only static-news.conf,
reload systemd and restart mobil-backend.service. This restores the old
WordPress integration, including its dependency on a working WordPress API.

Validation: static list sorting/limit, detail, missing ID and invalid-source
tests passed on the production Python environment before deployment. All 51
exported details have nonempty content. Live API returns the expected news.
