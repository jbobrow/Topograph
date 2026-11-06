"""Live sync with open APIs: Bluesky and Are.na.

Only your own public activity is read, at a human pace (about 1.5 s per request), and it
stops after 10 network failures in a row. Pictures are fetched afterward like any others,
by `topograph hydrate`. No login and no write access: these read what's already public.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

from .config import USER_AGENT
from .db import Library, Record, upsert_record
from .media import ingest
from .util import clean_text
from .importers.youtube import _time

BSKY_PDS = "https://bsky.social/xrpc"
BSKY_APP = "https://public.api.bsky.app/xrpc"
ARENA = "https://api.are.na/v2"
MAX_FAILURES = 10


class Fetcher:
    """Gets JSON one request at a time, politely. Tests replace `opener`."""

    def __init__(self, delay: float = 1.5, opener=None, sleep=time.sleep):
        self.delay = delay
        self.opener = opener or self._open
        self.sleep = sleep
        self.failures = 0

    @staticmethod
    def _open(url: str) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()

    def json(self, base: str, path: str, **params) -> dict:
        query = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}, doseq=True)
        url = f"{base}/{path}" + (f"?{query}" if query else "")
        self.sleep(self.delay)
        try:
            data = json.loads(self.opener(url))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            self.failures += 1
            if self.failures >= MAX_FAILURES:
                raise SystemExit("10 network failures in a row; stopping. Check your connection and run again.") from e
            raise
        self.failures = 0
        return data


# --- Bluesky ------------------------------------------------------------------

def _bsky_post(post: dict, interaction: dict) -> Record:
    uri = post["uri"]
    author = post.get("author") or {}
    record = post.get("record") or {}
    images = ((post.get("embed") or {}).get("images")) or []
    media = [{"ord": i, "kind": "image", "url": image.get("fullsize") or image.get("thumb")}
             for i, image in enumerate(images[:4])]
    rkey = uri.rsplit("/", 1)[-1]
    handle = author.get("handle")
    return Record(id=f"bluesky:{uri}", platform="bluesky", kind="image" if media else "text",
                  url=f"https://bsky.app/profile/{handle or author.get('did')}/post/{rkey}",
                  author=handle, text=clean_text(record.get("text")), hydrated=1,
                  created_at=_time(record.get("createdAt")) or None,
                  interactions=[interaction], media=media)


def sync_bluesky(handle: str, fetcher: Fetcher, limit: int | None = None):
    """Your posts, reposts and likes, newest first. Likes are public records on your repo."""
    did = fetcher.json(BSKY_APP, "com.atproto.identity.resolveHandle", handle=handle)["did"]
    count, cursor = 0, None
    while True:
        page = fetcher.json(BSKY_APP, "app.bsky.feed.getAuthorFeed", actor=did, limit=100, cursor=cursor)
        for entry in page.get("feed") or []:
            post = entry["post"]
            reason = (entry.get("reason") or {})
            if reason.get("$type", "").endswith("reasonRepost"):
                yield _bsky_post(post, {"type": "repost", "at": _time(reason.get("indexedAt")), "source": "bluesky"})
            elif (post.get("author") or {}).get("did") == did:
                yield _bsky_post(post, {"type": "post", "at": _time((post.get("record") or {}).get("createdAt")), "source": "bluesky"})
            count += 1
        cursor = page.get("cursor")
        if not cursor or (limit and count >= limit):
            break

    count, cursor = 0, None
    while True:
        page = fetcher.json(BSKY_PDS, "com.atproto.repo.listRecords", repo=did, collection="app.bsky.feed.like",
                            limit=100, cursor=cursor)
        likes = {r["value"]["subject"]["uri"]: _time(r["value"].get("createdAt")) for r in page.get("records") or []}
        uris = list(likes)
        for start in range(0, len(uris), 25):
            posts = fetcher.json(BSKY_APP, "app.bsky.feed.getPosts", **{"uris": uris[start:start + 25]})
            for post in posts.get("posts") or []:
                yield _bsky_post(post, {"type": "like", "at": likes.get(post["uri"], 0), "source": "bluesky"})
                count += 1
        cursor = page.get("cursor")
        if not cursor or (limit and count >= limit):
            break


# --- Are.na -------------------------------------------------------------------

def _arena_block(block: dict, channel: dict) -> Record | None:
    if block.get("base_class") != "Block" and block.get("class") == "Channel":
        return None
    image = (block.get("image") or {})
    url = ((image.get("large") or {}).get("url") or (image.get("original") or {}).get("url"))
    text = clean_text(block.get("content") or block.get("title") or block.get("generated_title"))
    source = (block.get("source") or {}).get("url")
    return Record(id=f"arena:{block['id']}", platform="arena", kind="image" if url else "text",
                  url=source or f"https://www.are.na/block/{block['id']}",
                  author=(block.get("user") or {}).get("slug"), text=text, hydrated=1,
                  created_at=_time(block.get("created_at")) or None,
                  interactions=[{"type": "save", "at": _time(block.get("connected_at") or block.get("created_at")),
                                 "collection": channel.get("title"), "source": "arena"}],
                  media=[{"ord": 0, "kind": "image", "url": url}] if url else [])


def sync_arena(slug: str, fetcher: Fetcher, limit: int | None = None):
    """The blocks in your channels. Each channel is a collection."""
    count, page = 0, 1
    while True:
        listing = fetcher.json(ARENA, f"users/{urllib.parse.quote(slug)}/channels", page=page, per=50)
        channels = listing.get("channels") or []
        for channel in channels:
            inner = 1
            while True:
                contents = fetcher.json(ARENA, f"channels/{channel['slug']}/contents", page=inner, per=100)
                blocks = contents.get("contents") or []
                for block in blocks:
                    record = _arena_block(block, channel)
                    if record:
                        yield record
                        count += 1
                        if limit and count >= limit:
                            return
                if len(blocks) < 100:
                    break
                inner += 1
        if page >= (listing.get("total_pages") or 1) or not channels:
            return
        page += 1


SOURCES = {"bluesky": sync_bluesky, "arena": sync_arena}


def run(lib: Library, source: str, account: str, fetcher: Fetcher | None = None, limit: int | None = None,
        progress=None) -> tuple[int, int]:
    """Returns records read and new items."""
    seen = new = 0
    for record in SOURCES[source](account, fetcher or Fetcher(), limit=limit):
        new += upsert_record(lib, record, ingest)
        seen += 1
        if progress:
            progress.advance(note=f"{new:,} new")
        if seen % 100 == 0:
            lib.conn.commit()
    lib.conn.commit()
    lib.set_meta(f"sync_{source}", account)
    lib.conn.commit()
    return seen, new
