"""Publishing adapter for the static website and existing mobile news contract."""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import tempfile


def enabled():
    return bool(os.getenv("STATIC_NEWS_FILE"))


def atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        stream.write(text)
        temporary = Path(stream.name)
    temporary.chmod(0o644)
    temporary.replace(path)


@contextmanager
def locked_feed():
    feed = Path(os.environ["STATIC_NEWS_FILE"])
    with feed.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = json.loads(feed.read_text())
        yield feed, rows


def root_path():
    return Path(os.getenv("STATIC_NEWS_ROOT", "/srv/dansmagazin-static/current"))


def refresh_indexes(root, rows):
    cards = []
    for row in sorted(rows, key=lambda r: r["date"], reverse=True):
        if not row.get("_panel_submission_id"):
            continue
        image = row["_embedded"]["wp:featuredmedia"][0]["source_url"]
        link = html.escape(row["link"], quote=True)
        cards.append(f'<article class="dm-card"><a href="{link}" class="dm-card-image"><img src="{html.escape(image, quote=True)}" alt="" loading="lazy"></a><div class="dm-card-body"><h2><a href="{link}">{row["title"]["rendered"]}</a></h2><p>{row["excerpt"]["rendered"]}</p></div></article>')
    block = '<!-- panel-news:start -->' + ''.join(cards) + '<!-- panel-news:end -->'
    featured = sorted([row for row in rows if row.get("_panel_submission_id")], key=lambda r: r["date"], reverse=True)[:3]
    hero = ""
    if featured:
        lead = featured[0]
        lead_link = html.escape(lead["link"], quote=True)
        lead_image = html.escape(lead["_embedded"]["wp:featuredmedia"][0]["source_url"], quote=True)
        side_cards = []
        for row in featured[1:]:
            link = html.escape(row["link"], quote=True)
            image = html.escape(row["_embedded"]["wp:featuredmedia"][0]["source_url"], quote=True)
            side_cards.append(
                f'<article class="dm-side-card" data-latest-slide><a class="dm-card-image" href="{link}"><img src="{image}" alt="" loading="lazy"></a>'
                f'<div class="dm-card-body"><div class="dm-meta"><span>Yeni</span><span>Dans Magazin</span></div>'
                f'<h2><a href="{link}">{row["title"]["rendered"]}</a></h2><p>{row["excerpt"]["rendered"]}</p></div></article>'
            )
        slider_tail = (
            '<div class="dm-slider-dots" data-slider-dots role="tablist" aria-label="Son haberler"></div>'
            '<style>.dm-latest-slider{display:block;position:relative;min-height:360px}.dm-latest-slider .dm-lead,.dm-latest-slider .dm-side-card{display:none}.dm-latest-slider [data-latest-slide].is-current{display:grid}.dm-latest-slider .dm-side-list{display:contents}.dm-slider-dots{display:flex;justify-content:center;gap:8px;margin:12px 0 0}.dm-slider-dot{width:8px;height:8px;border:0;border-radius:50%;padding:0;background:#c7b7ad;cursor:pointer}.dm-slider-dot.is-active{background:#8e201b;transform:scale(1.25)}</style>'
            '<script>(function(){var root=document.querySelector(".dm-latest-slider");if(!root)return;var slides=[].slice.call(root.querySelectorAll("[data-latest-slide]"));var dots=root.querySelector("[data-slider-dots]");if(!slides.length||!dots)return;var current=0;slides.forEach(function(slide,i){var dot=document.createElement("button");dot.className="dm-slider-dot";dot.type="button";dot.setAttribute("aria-label","Haberi göster "+(i+1));dot.onclick=function(){show(i)};dots.appendChild(dot)});function show(i){current=(i+slides.length)%slides.length;slides.forEach(function(slide,n){slide.classList.toggle("is-current",n===current)});dots.querySelectorAll("button").forEach(function(dot,n){dot.classList.toggle("is-active",n===current)})}function next(){show(current+1)}show(0);setInterval(next,5000)})();</script></section>'
        )
        hero = (
            '<section class="dm-hero-grid dm-latest-slider"><article class="dm-lead" data-latest-slide>'
            f'<a class="dm-lead-image" href="{lead_link}"><img src="{lead_image}" alt="" loading="lazy"></a>'
            f'<div class="dm-lead-copy"><div class="dm-meta"><span>Yeni</span><span>Dans Magazin</span></div>'
            f'<h1><a href="{lead_link}">{lead["title"]["rendered"]}</a></h1><p>{lead["excerpt"]["rendered"]}</p>'
            f'<a class="dm-read" href="{lead_link}">Haberi oku</a></div></article>'
            f'<div class="dm-side-list" data-side-list>{"".join(side_cards)}</div>' + slider_tail
        )
    for index in (root / "index.html", root / "haberler/index.html"):
        if not index.exists():
            continue
        text = index.read_text()
        if hero:
            text = re.sub(r'<section class="dm-hero-grid.*?</section>\s*', hero + "\n", text, count=1, flags=re.S)
        if '<!-- panel-news:start -->' in text:
            updated = re.sub(r'<!-- panel-news:start -->.*?<!-- panel-news:end -->', lambda _: block, text, flags=re.S)
        else:
            updated, count = re.subn(r'(<section class="dm-card-grid[^\"]*">)', lambda m: m[1] + block, text, count=1)
            if not count:
                raise ValueError(f"News grid missing from {index}")
        atomic(index, updated)


def publish(submission_id, *, title, body_text, source_link, submitter_name,
            cover_path, submitter_account_id=None, post_id=None,
            default_language="tr", translations=None):
    root = root_path()
    sid = int(submission_id)
    pid = int(post_id or (500000000 + sid))
    path = root / f"haber-{sid}" / "index.html"
    link = f"https://dansmagazin.net/haber-{sid}/"
    image = "https://dansmagazin.net/wp-content/uploads/2024/05/Yeni-Logo1-TEMIZ-1.png"
    if cover_path:
        name = Path(cover_path).name
        sources = [Path(__file__).resolve().parents[1] / "media/news_submission_covers",
                   Path("/home/ubuntu/etkinlik_fotograf_projesi/media/news_submission_covers")]
        source = next((folder / name for folder in sources if (folder / name).is_file()), None)
        if source is None:
            raise ValueError("Haber kapak dosyasi bulunamadi")
        target = root / "wp-content/uploads/panel-news" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        image = f"https://dansmagazin.net/wp-content/uploads/panel-news/{name}"
    title_html = html.escape(title)
    excerpt = html.escape(body_text[:210])
    content = '<p>' + html.escape(body_text).replace('\n', '<br>') + '</p>'
    if source_link and source_link.startswith(("https://", "http://")):
        content += f'<p><a href="{html.escape(source_link, quote=True)}" rel="noopener noreferrer">Kaynak</a></p>'
    with locked_feed() as (feed, rows):
        previous = next((r for r in rows if r["id"] == pid), {})
        if previous:
            from urllib.parse import urlsplit
            link = previous["link"]
            path = (root / urlsplit(link).path.lstrip("/") / "index.html").resolve()
            if not path.is_relative_to(root.resolve()):
                raise ValueError("Invalid news path")
        if previous and previous.get("_panel_submission_id") not in (None, sid):
            raise ValueError("News ID collision")
        date = previous.get("date") or datetime.now(timezone.utc).isoformat()
        page = f'''<!doctype html><html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title_html} - Dans Magazin</title><meta name="dm:content-type" content="news">
<meta property="og:type" content="article"><meta property="og:image" content="{html.escape(image, quote=True)}">
<meta property="article:published_time" content="{date}"><meta name="description" content="{excerpt}">
<link rel="stylesheet" href="/assets/dm-modern.css"><link rel="icon" type="image/png" href="/favicon.png">
</head><body><header class="dm-header"><a class="dm-brand" href="/">Dans Magazin</a><nav class="dm-nav"><a href="/haberler/">Haberler</a><a href="/magaza/">Mağaza</a></nav></header>
<main><article class="dm-article"><header class="dm-article-head"><h1>{title_html}</h1><p>{html.escape(submitter_name)}</p></header><div class="dm-article-image"><img src="{html.escape(image, quote=True)}" alt=""></div><div class="dm-article-body">{content}</div></article></main></body></html>'''
        row = {"id": pid, "date": date, "link": link, "title": {"rendered": title_html},
               "excerpt": {"rendered": excerpt}, "content": {"rendered": content},
               "_embedded": {"wp:featuredmedia": [{"source_url": image}], "author": [{"name": submitter_name}]},
               "_panel_submission_id": sid,
               "_dm_default_language": default_language,
               "_dm_translations": translations or {},
               "_static_hash": hashlib.sha256(page.encode()).hexdigest()}
        updated = [r for r in rows if r["id"] != pid] + [row]
        atomic(path, page)
        refresh_indexes(root, updated)
        atomic(feed, json.dumps(updated, ensure_ascii=False))
    return {"post_id": pid, "link": link}


def delete(post_id):
    with locked_feed() as (feed, rows):
        row = next((r for r in rows if r["id"] == int(post_id)), None)
        if row is None:
            return {"ok": True, "already_missing": True}
        from urllib.parse import urlsplit
        root = root_path()
        path = (root / urlsplit(row["link"]).path.lstrip("/") / "index.html").resolve()
        if not path.is_relative_to(root.resolve()):
            raise ValueError("Invalid news path")
        if path.exists():
            archive = feed.parent / "deleted-news"
            archive.mkdir(exist_ok=True)
            shutil.copy2(path, archive / f'{post_id}-{datetime.now().strftime("%Y%m%d%H%M%S%f")}.html')
            path.unlink()
        updated = [r for r in rows if r["id"] != int(post_id)]
        refresh_indexes(root, updated)
        atomic(feed, json.dumps(updated, ensure_ascii=False))
    return {"ok": True}
