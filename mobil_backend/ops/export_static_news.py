"""Export public WordPress posts for STATIC_NEWS_FILE; no account data is copied."""
import argparse
import json
from pathlib import Path


def export(source, media=None):
    rows = source["items"] if isinstance(source, dict) else source
    result = []
    for row in rows:
        if row.get("status") != "publish" or row.get("type") != "post":
            continue
        seo = row.get("yoast_head_json") or {}
        images = seo.get("og_image") or []
        embedded = row.get("_embedded") or {
            "wp:featuredmedia": [{"source_url": images[0]["url"]}] if images else [],
            "author": [{"name": seo.get("author", "Dans Magazin")}],
        }
        featured = (media or {}).get(row.get("featured_media"))
        if featured:
            embedded = {**embedded, "wp:featuredmedia": [featured]}
        result.append({
            "id": int(row["id"]), "date": row["date"], "link": row["link"],
            "title": row["title"], "excerpt": row["excerpt"],
            "content": {"rendered": row["content"]["rendered"]},
            "_embedded": embedded,
        })
    if not result or len({row["id"] for row in result}) != len(result):
        raise ValueError("Empty export or duplicate news IDs")
    return sorted(result, key=lambda row: row["date"], reverse=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    media_path = args.source.with_name("media.json")
    media = {}
    if media_path.exists():
        data = json.loads(media_path.read_text(encoding="utf-8"))
        media = {row["id"]: {"source_url": row["source_url"]}
                 for row in (data["items"] if isinstance(data, dict) else data)}
    result = export(json.loads(args.source.read_text(encoding="utf-8")), media)
    args.output.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    print(f"Exported {len(result)} published news items")
