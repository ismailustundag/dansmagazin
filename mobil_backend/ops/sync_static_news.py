"""Synchronize published static articles with the mobile news feed."""
import argparse
import fcntl
import hashlib
import html
from html.parser import HTMLParser
import json
import os
import re
from pathlib import Path
import shutil
import sys
from datetime import datetime, timezone
from urllib.parse import unquote, urljoin, urlsplit


class Article(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=False)
        self.meta = {}
        self.body = []
        self.depth = 0
        self.title = []
        self.in_title = False
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "meta":
            self.meta[values.get("property", values.get("name", ""))] = values.get("content", "")
        if tag == "h1":
            self.in_title = True
        if self.depth:
            self.body.append(self.get_starttag_text())
            if tag == "div":
                self.depth += 1
        elif tag == "div" and "dm-article-body" in values.get("class", "").split():
            self.depth = 1

    def handle_endtag(self, tag):
        if tag == "h1":
            self.in_title = False
        if self.depth:
            if tag == "div":
                self.depth -= 1
            if self.depth:
                self.body.append(f"</{tag}>")

    def handle_data(self, data):
        if self.depth:
            self.body.append(data)
        if self.in_title:
            self.title.append(data)

    def handle_entityref(self, name):
        self.handle_data(f"&{name};")

    def handle_charref(self, name):
        self.handle_data(f"&#{name};")


def recover_image(url, root, sources):
    path = unquote(urlsplit(url).path)
    if not path.startswith("/wp-content/uploads/"):
        return url
    target = (root / path.lstrip("/")).resolve()
    if not target.is_relative_to(root.resolve()) or target.exists():
        return url
    for source in sources:
        candidate = source / target.name
        if candidate.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(candidate, target)
            return url
    stem = re.sub(r"-\d+x\d+$", "", target.stem)
    stem = re.sub(r"-\d+$", "", stem)
    for source in sources:
        candidates = [p for p in source.glob(stem + ".*") if p.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp")]
        if candidates:
            candidate = candidates[0]
            destination = target.with_name(candidate.name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(candidate, destination)
            return urljoin(url, destination.name)
    variants = [p for p in target.parent.glob(stem + "-*") if p.is_file()]
    if variants:
        return urljoin(url, max(variants, key=lambda p: p.stat().st_size).name)
    print(f"Missing original image: {path}; using site logo")
    return "https://dansmagazin.net/wp-content/uploads/2024/05/Yeni-Logo1-TEMIZ-1.png"


def synchronize(root, feed, sources=(), base="https://dansmagazin.net"):
    catalog = json.loads(feed.with_name("static-news-catalog.json").read_text(encoding="utf-8"))
    news_paths = set(catalog["news_paths"])
    page_paths = set(catalog["page_paths"])
    rows = json.loads(feed.read_text(encoding="utf-8"))
    by_path = {urlsplit(row["link"]).path.rstrip("/"): row for row in rows}
    ids = {row["id"] for row in rows}
    seen = set()
    for page in sorted(root.glob("*/index.html")):
        text = page.read_text(encoding="utf-8")
        article = Article(text)
        if article.meta.get("og:type") != "article" or not article.body or not article.title:
            continue
        path = "/" + page.parent.name
        # The static template labels ordinary pages as og:type=article too.
        # Only known posts or explicitly classified new news may enter the feed.
        if path in page_paths or (path not in news_paths and article.meta.get("dm:content-type") != "news"):
            continue
        seen.add(path)
        digest = hashlib.sha256(text.encode()).hexdigest()
        row = by_path.get(path)
        if row is None:
            # Positive signed-32-bit IDs fit the existing reaction tables.
            post_id = 1000000000 + int(hashlib.sha256(path.encode()).hexdigest()[:8], 16) % 1000000000
            while post_id in ids:
                post_id += 1
            ids.add(post_id)
            row = {"id": post_id, "date": article.meta.get("article:published_time") or
                   datetime.fromtimestamp(page.stat().st_mtime, timezone.utc).isoformat(),
                   "link": base + path + "/", "content": {"rendered": ""}}
            rows.append(row)
        # Keep complete migration content on first discovery; later edits win.
        if not row["content"]["rendered"] or (row.get("_static_hash") and row["_static_hash"] != digest):
            row["content"] = {"rendered": "".join(article.body).strip()}
        row["title"] = {"rendered": html.unescape("".join(article.title))}
        row["excerpt"] = {"rendered": article.meta.get("description", "")}
        image = article.meta.get("og:image", "")
        if image:
            image = urljoin(base + "/", image)
            image = recover_image(image, root, sources)
            row.setdefault("_embedded", {})["wp:featuredmedia"] = [{"source_url": image}]
        row.setdefault("_embedded", {}).setdefault("author", [{"name": "Dans Magazin"}])
        row["_static_hash"] = digest
    if not seen:
        raise ValueError("No published article pages found; retaining previous feed")
    rows = [row for row in rows if urlsplit(row["link"]).path.rstrip("/") in seen]
    for row in rows:
        for media in row.get("_embedded", {}).get("wp:featuredmedia", []):
            media["source_url"] = recover_image(media.get("source_url", ""), root, sources)
    result = json.dumps(sorted(rows, key=lambda row: row["date"], reverse=True), ensure_ascii=False)
    if result != feed.read_text(encoding="utf-8"):
        temporary = feed.with_suffix(".next.json")
        temporary.write_text(result, encoding="utf-8")
        os.replace(temporary, feed)
    sys.path.insert(0, "/home/ubuntu/mobil_backend")
    from app.static_news import refresh_indexes
    refresh_indexes(root, rows)
    print(f"Synchronized {len(seen)} static articles; {len(rows)} mobile news items")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--feed", type=Path, required=True)
    parser.add_argument("--image-source", type=Path, action="append", default=[])
    args = parser.parse_args()
    with args.feed.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        synchronize(args.root, args.feed, args.image_source)
