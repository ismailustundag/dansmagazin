from __future__ import annotations

import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source block, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: retire_photo_writes.py /path/to/main.py")

    path = Path(sys.argv[1])
    original = path.read_text()
    updated = original
    updated = replace_once(
        updated,
        'FACE_MATCHING_ENABLED = False\n',
        'FACE_MATCHING_ENABLED = False\nPHOTO_ALBUM_WRITES_ENABLED = False\n',
        "feature flag",
    )
    updated = replace_once(
        updated,
        '_WP_SYNC_LAST_ERR = ""\n\n\ndef fmt_dt',
        '''_WP_SYNC_LAST_ERR = ""

_RETIRED_PHOTO_WRITE_PATHS = (
    re.compile(r"^/panel/events/create$"),
    re.compile(r"^/panel/events/\\d+/(?:subalbums/create|upload_photos|frames|reprocess)$"),
    re.compile(r"^/(?:register|register_file|lookup)$"),
    re.compile(r"^/admin/mobile/submissions/\\d+/album/create$"),
    re.compile(r"^/console/event/create$"),
    re.compile(
        r"^/console/event/[^/]+/(?:subalbums/create|users/create|frames|reprocess|upload_photos|match)$"
    ),
)


@app.middleware("http")
async def block_retired_photo_writes(request: Request, call_next):
    if (
        not PHOTO_ALBUM_WRITES_ENABLED
        and request.method.upper() == "POST"
        and any(pattern.match(request.url.path) for pattern in _RETIRED_PHOTO_WRITE_PATHS)
    ):
        return HTMLResponse(
            "Etkinlik albümü ve yüz tanıma sistemi kullanımdan kaldırıldı.",
            status_code=410,
        )
    return await call_next(request)


def fmt_dt''',
        "write middleware",
    )
    updated = replace_once(
        updated,
        'create_photo_album = _boolish(row.get("create_photo_album"), default=True)',
        "create_photo_album = False",
        "live event album flag",
    )
    updated = replace_once(
        updated,
        "create_photo_album_flag = _boolish(create_photo_album, default=False)",
        "create_photo_album_flag = False",
        "admin event album flag",
    )

    if updated != original:
        path.write_text(updated)
        print(f"updated {path}")
    else:
        print(f"already updated {path}")


if __name__ == "__main__":
    main()
