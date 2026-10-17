"""Read-only public news image smoke test."""
import concurrent.futures
import json
import urllib.request


def check(url):
    try:
        with urllib.request.urlopen(url, timeout=12) as response:
            kind = response.headers.get("Content-Type", "")
            data = response.read(32)
            return url, response.status == 200 and kind.startswith("image/") and bool(data), kind
    except Exception as error:
        return url, False, str(error)


if __name__ == "__main__":
    url = "https://api2.dansmagazin.net/discover?news_limit=59&events_limit=0&albums_limit=0"
    with urllib.request.urlopen(url, timeout=15) as response:
        rows = json.load(response)["news"]
    images = {row["image"] for row in rows}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(check, images))
    errors = [result for result in results if not result[1]]
    print(f"News: {len(rows)}; unique images: {len(images)}; failed images: {len(errors)}")
    for result in errors:
        print(result)
    raise SystemExit(bool(errors))
