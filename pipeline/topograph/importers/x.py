"""X (Twitter) archive importer.

The archive's data/*.js files are JavaScript shims:
    window.YTD.tweets.part0 = [ {"tweet": {...}}, ... ]
Large feeds are split across tweets.js, tweets-part1.js, ...
"""

from __future__ import annotations

import json
import re
from pathlib import PurePosixPath

from ..db import Record
from ..util import (Archive, clean_text, ext_of, is_unavailable, parse_twitter_date,
                    snowflake_time, VIDEO_EXT)

SHIM_RX = re.compile(r"^\s*window\.YTD\.[A-Za-z0-9_]+\.part\d+\s*=\s*", re.S)
TCO_RX = re.compile(r"\s*https://t\.co/\w+\s*$")


def detect(archive: Archive) -> bool:
    return bool(archive.find(r"(^|/)data/(tweets|like|account)(-part\d+)?\.js$"))


def read_feed(archive: Archive, feed: str) -> list:
    """All parts of one feed, concatenated."""
    out = []
    for name in archive.find(rf"(^|/)data/{feed}(-part\d+)?\.js$"):
        raw = archive.read_text(name)
        body = SHIM_RX.sub("", raw, count=1).strip().rstrip(";")
        try:
            data = json.loads(body)
        except json.JSONDecodeError as e:
            raise ValueError(f"Could not parse {name}: {e}") from e
        out.extend((name, entry) for entry in data)
    return out


def _unwrap(entry: dict, key: str) -> dict:
    return entry.get(key, entry) if isinstance(entry, dict) else {}


def account_username(archive: Archive) -> str | None:
    for _, entry in read_feed(archive, "account"):
        acc = _unwrap(entry, "account")
        if acc.get("username"):
            return acc["username"]
    return None


def _media_index(archive: Archive) -> dict[str, list[str]]:
    """tweet id -> local media files (data/tweets_media/<id>-<key>.<ext>)."""
    idx: dict[str, list[str]] = {}
    for name in archive.find(r"(^|/)data/tweets?_media/[^/]+$"):
        base = PurePosixPath(name).name
        tid = base.split("-", 1)[0]
        idx.setdefault(tid, []).append(name)
    return idx


def _expand_text(tw: dict) -> str | None:
    text = tw.get("full_text") or tw.get("text") or ""
    ents = tw.get("entities") or {}
    for u in ents.get("urls") or []:
        if u.get("url") and u.get("expanded_url"):
            text = text.replace(u["url"], u["expanded_url"])
    # Trailing t.co link that points at attached media.
    if (tw.get("extended_entities") or ents).get("media"):
        text = TCO_RX.sub("", text)
    return clean_text(text)


def parse(archive: Archive):
    me = account_username(archive) or "i"
    media_idx = _media_index(archive)

    # --- your posts, replies and reposts -----------------------------------
    for src, entry in read_feed(archive, "tweets"):
        tw = _unwrap(entry, "tweet")
        tid = tw.get("id_str") or str(tw.get("id", ""))
        if not tid:
            continue
        at = parse_twitter_date(tw.get("created_at", "")) or snowflake_time(tid)
        full = tw.get("full_text") or ""
        author = me
        if full.startswith("RT @"):
            ix_type = "repost"
            m = re.match(r"RT @([A-Za-z0-9_]+):", full)
            author = m.group(1) if m else None
        elif tw.get("in_reply_to_status_id_str"):
            ix_type = "reply"
        else:
            ix_type = "post"

        media_entities = (tw.get("extended_entities") or {}).get("media") or \
                         (tw.get("entities") or {}).get("media") or []
        media = []
        local_files = sorted(media_idx.get(tid, []))
        local_images = [f for f in local_files if ext_of(f) not in VIDEO_EXT]
        for i, me_ in enumerate(media_entities):
            mtype = me_.get("type", "photo")
            kind = "video" if mtype in ("video", "animated_gif") else "image"
            remote = me_.get("media_url_https") or me_.get("media_url")
            local = None
            if kind == "image" and remote:
                key = PurePosixPath(remote).name
                local = next((f for f in local_images if f.endswith("-" + key)), None)
            if local:
                media.append({"ord": i, "kind": "image", "url": remote,
                              "data": archive.read(local), "name": local})
            else:
                # For videos, media_url_https is the poster frame: fetch it later.
                media.append({"ord": i, "kind": "image", "url": remote, "data": None,
                              "video": kind == "video"})

        has_video = any(m.get("video") for m in media)
        kind = "video" if has_video else ("image" if media else
                                          ("link" if (tw.get("entities") or {}).get("urls") else "text"))
        yield Record(
            id=f"x:{tid}",
            platform="x",
            kind=kind,
            url=f"https://x.com/{author or me}/status/{tid}",
            author=author,
            text=_expand_text(tw),
            created_at=at,
            hydrated=1 if (ix_type != "repost" or media) else 0,
            interactions=[{"type": ix_type, "at": at, "source": src}],
            media=media,
        )

    # --- likes and bookmarks ----------------------------------------------
    for feed, key, ix_type in (("like", "like", "like"), ("bookmark", "bookmark", "bookmark"),
                               ("bookmarks", "bookmark", "bookmark")):
        for src, entry in read_feed(archive, feed):
            obj = _unwrap(entry, key)
            tid = str(obj.get("tweetId") or obj.get("tweet_id") or obj.get("id") or "")
            if not tid:
                continue
            created = snowflake_time(tid)
            # The archive does not say WHEN you liked something. The post's own
            # creation time is a lower bound, so we use it and flag it as estimated.
            at = None
            for k in ("createdAt", "created_at", "bookmarkedAt", "timestamp"):
                if obj.get(k):
                    at = parse_twitter_date(str(obj[k]))
                    break
            url = obj.get("expandedUrl") or f"https://x.com/i/web/status/{tid}"
            text = clean_text(obj.get("fullText") or obj.get("full_text"))
            gone = is_unavailable(text)
            if gone:
                text = None     # X's notice, not the post; the post itself is gone
            yield Record(
                id=f"x:{tid}",
                platform="x",
                kind="text" if text else "link",
                url=url,
                text=text,
                created_at=created,
                created_estimated=False,
                hydrated=-1 if gone else 0,
                interactions=[{"type": ix_type, "at": at or created or 0,
                               "estimated": at is None, "source": src}],
            )
