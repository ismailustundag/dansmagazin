"""Add the existing brand PNG as the static site's favicon, preserving news hashes."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
from datetime import datetime, timezone

root = Path('/srv/dansmagazin-static/current')
feed = Path('/home/ubuntu/mobil_backend/data/static-news.json')
logo = root / 'wp-content/uploads/2024/05/Yeni-Logo1-TEMIZ-1.png'
assert logo.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
pages = list(root.rglob('*.html'))
backup = Path('/home/ubuntu/backups') / ('favicon-' + datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S'))
backup.mkdir()
with tarfile.open(backup / 'pages.tar.gz', 'w:gz') as archive:
    for page in pages:
        archive.add(page, arcname=str(page.relative_to(root)))
shutil.copy2(feed, backup / 'static-news.json')
rows = json.loads(feed.read_text())
changes = {}
tag = '<link rel="icon" type="image/png" href="/favicon.png?v=20261008">'
for page in pages:
    original = page.read_text(encoding='utf-8')
    if '</head>' not in original or tag in original:
        continue
    updated = original.replace('</head>', '  ' + tag + '\n</head>', 1)
    changes[hashlib.sha256(original.encode()).hexdigest()] = hashlib.sha256(updated.encode()).hexdigest()
    page.write_text(updated, encoding='utf-8')
shutil.copy2(logo, root / 'favicon.png')
for row in rows:
    old_hash = row.get('_static_hash')
    if old_hash in changes:
        row['_static_hash'] = changes[old_hash]
temporary = feed.with_suffix('.favicon-next.json')
temporary.write_text(json.dumps(rows, ensure_ascii=False), encoding='utf-8')
temporary.replace(feed)
assert all(tag in page.read_text(encoding='utf-8') for page in pages if '</head>' in page.read_text(encoding='utf-8'))
print(f'Updated {len(changes)} pages. Backup: {backup}')
