"""Facebook "Download your information" (JSON) importer.

Facebook exports come from the same Accounts Center as Instagram and share its
quirks (mis-encoded text, shapes that change between years), so this reuses
the Instagram importer's tolerant record walker.

What's in a Facebook export, and what it becomes here:
  your posts, photos, albums  -> items with media (often your oldest images)
  saved items                  -> links you saved
  pages you liked              -> short text items (a page name says something)
  comments                     -> your words
  likes and reactions          -> usually just "You liked Ann's photo": no link and
                                  no image, so they are kept as traces that count
                                  in Strata but are not placed on the map
"""

from __future__ import annotations

import hashlib

from ..db import Record
from ..util import Archive, VIDEO_EXT, clean_text, ext_of, plausible_ts
from .instagram import _flatten_record, _load, _main_list, _media_entries, _walk


def detect(archive: Archive) -> bool:
    return bool(archive.find(
        r"(your_facebook_activity/|(^|/)posts/your_posts[^/]*\.json$|likes_and_reactions[^/]*\.json$|"
        r"(^|/)photos_and_videos/album/)"))


def _h(*parts) -> str:
    return hashlib.sha1("|".join(str(p) for p in parts).encode()).hexdigest()[:16]


def _post_text(rec) -> str | None:
    """Your words in a post: data[].post, then a description, then nothing."""
    if not isinstance(rec, dict):
        return None
    for d in rec.get("data") or []:
        if isinstance(d, dict) and d.get("post"):
            return clean_text(d["post"])
    for m in _media_entries(rec):
        if m.get("description"):
            return clean_text(m["description"])
    return None


def _links(rec) -> list[str]:
    out = []
    for d in _walk(rec):
        ctx = d.get("external_context")
        if isinstance(ctx, dict) and isinstance(ctx.get("url"), str):
            out.append(ctx["url"])
        if (d.get("label") or "").lower() == "url" and isinstance(d.get("value"), str):
            out.append(d["value"])
        if isinstance(d.get("href"), str):
            out.append(d["href"])
    return [u for u in out if u.startswith("http")]


def _stamp(rec) -> int:
    if isinstance(rec, dict) and plausible_ts(rec.get("timestamp")):
        return int(rec["timestamp"])
    stamps = [v for d in _walk(rec) for k, v in d.items() if "timestamp" in k and plausible_ts(v)]
    return int(max(stamps)) if stamps else 0


def _own_posts(archive: Archive):
    names = archive.find(r"(^|/)(posts|photos_and_videos)/(?!.*(comment|like|react))[^\n]*\.json$")
    for name in names:
        data = _load(archive, name)
        if data is None:
            continue
        # Albums are {"name": ..., "photos": [...]}: one item per photo.
        if isinstance(data, dict) and isinstance(data.get("photos"), list):
            album = clean_text(data.get("name"))
            records = [{"_album": album, **p} for p in data["photos"] if isinstance(p, dict)]
        else:
            records = _main_list(data)
        for rec in records:
            entries = [e for e in _media_entries(rec)]
            text = _post_text(rec) or clean_text(rec.get("description") if isinstance(rec, dict) else None)
            at = _stamp(rec)
            if not entries and not text:
                continue
            media, kinds = [], set()
            for i, e in enumerate(entries[:10]):
                member = archive.find_suffix(e["uri"])
                video = ext_of(e["uri"]) in VIDEO_EXT
                kinds.add("video" if video else "image")
                if member:
                    media.append({"ord": i, "kind": "video" if video else "image",
                                  "data": archive.read(member), "name": member})
            key = entries[0]["uri"] if entries else f"{at}:{text}"
            album = rec.get("_album") if isinstance(rec, dict) else None
            yield Record(
                id=f"fb:own:{_h(key)}",
                platform="facebook",
                kind=("video" if kinds == {"video"} else "image") if entries else "text",
                url=next(iter(_links(rec)), None),
                text=text,
                created_at=at or None,
                hydrated=1,
                interactions=[{"type": "post", "at": at, "collection": album, "source": name}],
                media=media,
            )


def _saved(archive: Archive):
    for name in archive.find(r"(^|/)saved_items_and_collections/[^/]*\.json$|(^|/)saved_items[^/]*\.json$"):
        data = _load(archive, name)
        if data is None:
            continue
        collection = "collections" in name and None
        for rec in _main_list(data):
            urls = _links(rec)
            if not urls:
                continue
            f = _flatten_record(rec)
            title = None
            for d in _walk(rec):
                ctx = d.get("external_context")
                if isinstance(ctx, dict) and ctx.get("name"):
                    title = clean_text(ctx["name"])
                    break
            at = _stamp(rec)
            yield Record(
                id=f"fb:link:{_h(urls[0])}",
                platform="facebook",
                kind="link",
                url=urls[0],
                author=f["author"] if f["author"] and "saved" not in (f["author"] or "") else None,
                text=title,
                interactions=[{"type": "save", "at": at, "collection": collection or f["name"],
                               "source": name}],
            )


def _pages(archive: Archive):
    for name in archive.find(r"(^|/)pages/[^/]*liked[^/]*\.json$|(^|/)pages_you'?ve_liked\.json$"):
        data = _load(archive, name)
        for rec in _main_list(data) if data is not None else []:
            page = clean_text((rec.get("name") or rec.get("title")) if isinstance(rec, dict) else None)
            if not page:
                continue
            at = _stamp(rec)
            yield Record(
                id=f"fb:page:{_h(page)}",
                platform="facebook",
                kind="text",
                url=next(iter(_links(rec)), None),
                text=page,
                hydrated=1,
                interactions=[{"type": "like", "at": at, "collection": "Pages", "source": name}],
            )


def _comments(archive: Archive):
    for name in archive.find(r"(^|/)comments_and_reactions/comments[^/]*\.json$|(^|/)comments/comments[^/]*\.json$"):
        data = _load(archive, name)
        for rec in _main_list(data) if data is not None else []:
            text = None
            for d in _walk(rec):
                c = d.get("comment")
                if isinstance(c, dict) and c.get("comment"):
                    text = clean_text(c["comment"])
                    break
                if isinstance(c, str) and c.strip():
                    text = clean_text(c)
                    break
            if not text:
                continue
            at = _stamp(rec)
            yield Record(
                id=f"fb:comment:{_h(at, text)}",
                platform="facebook",
                kind="text",
                text=text,
                hydrated=1,
                interactions=[{"type": "comment", "at": at, "source": name}],
            )


def _reactions(archive: Archive):
    for name in archive.find(r"likes_and_reactions[^/]*\.json$|(^|/)reactions[^/]*\.json$"):
        data = _load(archive, name)
        for rec in _main_list(data) if data is not None else []:
            at = _stamp(rec)
            urls = _links(rec)
            title = clean_text(rec.get("title")) if isinstance(rec, dict) else None
            if urls:
                yield Record(id=f"fb:link:{_h(urls[0])}", platform="facebook", kind="link", url=urls[0],
                             interactions=[{"type": "like", "at": at, "source": name}])
            elif title or at:
                yield Record(id=f"fb:trace:{_h(at, title)}", platform="facebook", kind="trace",
                             text=title, hydrated=-1,
                             interactions=[{"type": "react", "at": at, "source": name}])


def parse(archive: Archive):
    yield from _own_posts(archive)
    yield from _saved(archive)
    yield from _pages(archive)
    yield from _comments(archive)
    yield from _reactions(archive)
