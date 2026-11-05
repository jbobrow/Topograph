"""Hydration: fetch media and text for items that arrived as bare links.

Liked and saved posts appear in exports as a URL and a timestamp. This module
fetches what it can, politely (one request at a time, with a delay), and
marks items it cannot reach so they are not retried forever.

Strategies
  X          the public syndication endpoint behind embedded tweets (no login).
             Unofficial, may change.
  Instagram  the post's public embed page, then the post page's Open Graph tags.
             Instagram often requires a login; the native app will hydrate
             through a web view signed in as you (see docs/SPEC.md §4).
"""

from __future__ import annotations

import html
import json
import math
import re
import time
import urllib.error
import urllib.request

from . import media as media_mod
from .config import USER_AGENT
from .util import instagram_shortcode, parse_twitter_date

MAX_ATTEMPTS = 3


class FetchError(Exception):
    pass


def fetch(url: str, timeout: float = 20.0, accept: str = "*/*") -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT, "Accept": accept, "Accept-Language": "en-US,en;q=0.8"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        raise FetchError(f"{url}: {e}") from e


# --- X ----------------------------------------------------------------------

def _js_base36(x: float, max_frac_digits: int = 11) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    ip, fp = int(x), x - int(x)
    s = ""
    while True:
        s = digits[ip % 36] + s
        ip //= 36
        if ip == 0:
            break
    frac = ""
    for _ in range(max_frac_digits):
        fp *= 36
        d = int(fp)
        frac += digits[d]
        fp -= d
        if fp == 0:
            break
    return s + ("." + frac if frac else "")


def x_token(tweet_id: str) -> str:
    """Token the embed endpoint expects (mirrors react-tweet's implementation)."""
    tok = _js_base36((int(tweet_id) / 1e15) * math.pi)
    return re.sub(r"(0+|\.)", "", tok) or "a"


def parse_x_syndication(data: dict) -> dict:
    user = data.get("user") or {}
    media = []
    for m in data.get("mediaDetails") or []:
        if m.get("media_url_https"):
            media.append({"url": m["media_url_https"],
                          "video": m.get("type") in ("video", "animated_gif")})
    if not media and (data.get("video") or {}).get("poster"):
        media.append({"url": data["video"]["poster"], "video": True})
    if not media and (data.get("card") or {}).get("binding_values"):
        bv = data["card"]["binding_values"]
        for key in ("photo_image_full_size_large", "thumbnail_image_large", "summary_photo_image_large"):
            img = (bv.get(key) or {}).get("image_value", {}).get("url")
            if img:
                media.append({"url": img, "video": False})
                break
    return {
        "text": data.get("text"),
        "author": user.get("screen_name"),
        "created_at": parse_twitter_date(data.get("created_at", "")) if data.get("created_at") else None,
        "media": media,
    }


def hydrate_x(item) -> dict | None:
    tid = item["id"].split(":", 1)[1]
    url = f"https://cdn.syndication.twimg.com/tweet-result?id={tid}&lang=en&token={x_token(tid)}"
    body = fetch(url, accept="application/json")
    if not body.strip():
        return None
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return None
    if data.get("__typename") == "TweetTombstone" or not data:
        return None
    return parse_x_syndication(data)


# --- Instagram ----------------------------------------------------------------

OG_RX = re.compile(r'<meta[^>]+property="og:([a-z:_]+)"[^>]+content="([^"]*)"', re.I)
OG_RX2 = re.compile(r'<meta[^>]+content="([^"]*)"[^>]+property="og:([a-z:_]+)"', re.I)
IG_DESC_RX = re.compile(r'^.*?-\s*([A-Za-z0-9_.]+)\s+on\s+[^:]+:\s*"?(.*?)"?\.?$', re.S)
EMBED_IMG_RX = re.compile(r'<img[^>]+class="[^"]*EmbeddedMediaImage[^"]*"[^>]+src="([^"]+)"', re.I)
EMBED_IMG_RX2 = re.compile(r'<img[^>]+src="([^"]+)"[^>]+class="[^"]*EmbeddedMediaImage[^"]*"', re.I)
EMBED_CAPTION_RX = re.compile(r'<div class="Caption">(.*?)<div class="CaptionComments">', re.S)
EMBED_USER_RX = re.compile(r'<a class="CaptionUsername"[^>]*>([^<]+)</a>')
TAG_RX = re.compile(r"<[^>]+>")


def parse_og(page: str) -> dict:
    og = {k.lower(): html.unescape(v) for k, v in OG_RX.findall(page)}
    og.update({k.lower(): html.unescape(v) for v, k in OG_RX2.findall(page)})
    return og


def parse_instagram_embed(page: str) -> dict | None:
    m = EMBED_IMG_RX.search(page) or EMBED_IMG_RX2.search(page)
    if not m:
        return None
    caption = None
    cm = EMBED_CAPTION_RX.search(page)
    author = None
    if cm:
        raw = cm.group(1)
        um = EMBED_USER_RX.search(raw)
        author = html.unescape(um.group(1)).strip() if um else None
        raw = EMBED_USER_RX.sub("", raw)
        caption = html.unescape(TAG_RX.sub(" ", raw.replace("<br />", "\n")))
        caption = re.sub(r"[ \t]+", " ", caption).strip() or None
    return {"text": caption, "author": author,
            "media": [{"url": html.unescape(m.group(1)), "video": False}]}


def parse_instagram_og(page: str) -> dict | None:
    og = parse_og(page)
    img = og.get("image")
    if not img:
        return None
    text, author = None, None
    desc = og.get("description") or og.get("title")
    if desc:
        m = IG_DESC_RX.match(desc)
        if m:
            author, text = m.group(1), m.group(2).strip() or None
        else:
            text = desc
    return {"text": text, "author": author,
            "media": [{"url": img, "video": og.get("type") == "video"}]}


def hydrate_instagram(item) -> dict | None:
    code = instagram_shortcode(item["url"] or "")
    if not code:
        return None
    for url, parser in ((f"https://www.instagram.com/p/{code}/embed/captioned/", parse_instagram_embed),
                        (f"https://www.instagram.com/p/{code}/", parse_instagram_og)):
        try:
            page = fetch(url, accept="text/html").decode("utf-8", errors="replace")
        except FetchError:
            continue
        found = parser(page)
        if found:
            return found
    return None


HYDRATORS = {"x": hydrate_x, "instagram": hydrate_instagram}


# --- driver -----------------------------------------------------------------

def download_pending_media(lib, item_id: str | None = None, delay: float = 0.3, log=print,
                           progress=None) -> int:
    """Download media rows that only have a remote URL."""
    q = "select item_id, ord, original_url, kind from media where status='pending' and original_url is not null"
    args = ()
    if item_id:
        q += " and item_id=?"
        args = (item_id,)
    done = 0
    rows = lib.conn.execute(q, args).fetchall()
    if progress:
        progress.set_total(len(rows))
        log = progress.write
    for row in rows:
        if progress:
            progress.advance(note=row["item_id"])
        try:
            data = fetch(row["original_url"], accept="image/*")
        except FetchError as e:
            log(f"  media failed: {e}")
            lib.conn.execute("update media set status='failed' where item_id=? and ord=?",
                             (row["item_id"], row["ord"]))
            continue
        # The URL already points at a poster frame for videos.
        if media_mod.ingest(lib, row["item_id"], row["ord"], data, "image"):
            if row["kind"] == "video":
                lib.conn.execute("update media set kind='video' where item_id=? and ord=?",
                                 (row["item_id"], row["ord"]))
            done += 1
        time.sleep(delay)
    lib.conn.commit()
    return done


def hydrate(lib, limit: int | None = None, delay: float = 1.5, platforms=None, log=print,
            progress=None) -> dict:
    stats = {"hydrated": 0, "unreachable": 0, "skipped": 0, "media": 0}
    q = ("select * from item where hydrated=0 and hydrate_attempts<? "
         "order by (select max(at) from interaction where item_id=item.id) desc")
    rows = lib.conn.execute(q, (MAX_ATTEMPTS,)).fetchall()
    if platforms:
        rows = [r for r in rows if r["platform"] in platforms]
    if limit:
        rows = rows[:limit]
    consecutive_failures = 0
    if progress:
        progress.set_total(len(rows))
        log = progress.write
    for i, item in enumerate(rows, 1):
        if progress:
            progress.advance(note=f"{stats['hydrated']:,} fetched, {stats['unreachable']:,} unreachable")
        fn = HYDRATORS.get(item["platform"])
        if not fn:
            stats["skipped"] += 1
            continue
        try:
            found = fn(item)
            net_ok = True
        except FetchError as e:
            found, net_ok = None, False
            log(f"  {item['id']}: {e}")
        if found:
            consecutive_failures = 0
            c = lib.conn
            has_video = any(m["video"] for m in found["media"])
            kind = "video" if has_video else ("image" if found["media"] else "text")
            c.execute(
                "update item set hydrated=1, kind=?, text=coalesce(?, text), author=coalesce(?, author), "
                "created_at=coalesce(?, created_at), created_estimated=case when ? is null "
                "then created_estimated else 0 end where id=?",
                (kind, found.get("text"), found.get("author"), found.get("created_at"),
                 found.get("created_at"), item["id"]))
            c.execute("delete from embedding where item_id=?", (item["id"],))  # now stale
            for o, m in enumerate(found["media"][:4]):
                c.execute("insert or ignore into media(item_id, ord, kind, original_url) values (?,?,?,?)",
                          (item["id"], o, "video" if m["video"] else "image", m["url"]))
            stats["media"] += download_pending_media(lib, item["id"], delay=0.2, log=log)
            stats["hydrated"] += 1
        else:
            consecutive_failures += 1 if not net_ok else 0
            attempts = item["hydrate_attempts"] + 1
            lib.conn.execute(
                "update item set hydrate_attempts=?, hydrated=case when ? >= ? then -1 else 0 end where id=?",
                (attempts, attempts, MAX_ATTEMPTS, item["id"]))
            if attempts >= MAX_ATTEMPTS:
                stats["unreachable"] += 1
        if i % 10 == 0:
            lib.conn.commit()
            if not progress:
                log(f"  {i}/{len(rows)}  hydrated {stats['hydrated']}, unreachable {stats['unreachable']}")
        if consecutive_failures >= 10:
            log("  10 network failures in a row; stopping. Check your connection and run again.")
            break
        time.sleep(delay)
    lib.conn.commit()
    return stats
