"""Instagram "Download your information" (JSON) importer.

Instagram has changed the export's shape several times, so this importer does
not trust a single schema. For likes and saves it walks every record looking
for an Instagram post URL and a timestamp; for your own posts it looks for
media entries with a `uri` and `creation_timestamp`.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import PurePosixPath

from ..db import Record
from ..util import (Archive, VIDEO_EXT, clean_text, deep_fix_mojibake, ext_of,
                    instagram_shortcode, instagram_shortcode_time, plausible_ts)


def detect(archive: Archive) -> bool:
    return bool(archive.find(
        r"(your_instagram_activity/|liked_posts\.json$|saved_posts\.json$|"
        r"(^|/)content/posts_\d+\.json$)"))


def _load(archive: Archive, name: str):
    try:
        return deep_fix_mojibake(json.loads(archive.read_text(name)))
    except json.JSONDecodeError:
        return None


def _main_list(obj):
    """Top-level list of records, whether the file is a list or {key: [list]}."""
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        lists = [v for v in obj.values() if isinstance(v, list)]
        if len(lists) == 1:
            return lists[0]
        return [x for v in lists for x in v]
    return []


def _walk(obj):
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from _walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk(v)


def _flatten_record(rec) -> dict:
    """Pull URL(s), timestamp(s), author and a name out of one record, any shape."""
    urls, stamps, author, name, text = [], [], None, None, None
    for d in _walk(rec):
        for k, v in d.items():
            if isinstance(v, str) and v.startswith("http"):
                urls.append(v)
            elif "timestamp" in k.lower() and plausible_ts(v):
                stamps.append(int(v))
        label = (d.get("label") or "").lower()
        val = d.get("value")
        if label in ("username", "owner", "author") and isinstance(val, str):
            author = author or val
        if label == "name" and isinstance(val, str):
            name = name or val
        if label in ("caption", "comment", "text") and isinstance(val, str):
            text = text or val
        if "string_map_data" in d:
            for key, inner in (d["string_map_data"] or {}).items():
                if not isinstance(inner, dict):
                    continue
                kl = key.lower()
                if kl == "name" and inner.get("value"):
                    name = name or inner["value"]
                if kl in ("comment", "text") and inner.get("value"):
                    text = text or inner["value"]
                if kl in ("media owner", "owner", "username") and inner.get("value"):
                    author = author or inner["value"]
    title = rec.get("title") if isinstance(rec, dict) else None
    if title and not author:
        author = title
    return {"urls": urls, "stamps": stamps, "author": clean_text(author),
            "name": clean_text(name), "text": clean_text(text)}


def _labels(rec) -> dict | None:
    """Read a 2025-style record: label_values with URL, Caption, Hashtags and Owner.

    Returns None for older shapes, which go through _flatten_record instead.
    """
    if not isinstance(rec, dict) or not isinstance(rec.get("label_values"), list):
        return None
    out = {"url": None, "caption": None, "author": None, "hashtags": [], "name": None, "items": []}
    for lv in rec["label_values"]:
        label = (lv.get("label") or "").lower()
        title = (lv.get("title") or "").lower()
        if label == "url" and isinstance(lv.get("value"), str):
            out["url"] = lv.get("href") or lv["value"]
        elif label == "caption":
            out["caption"] = clean_text(lv.get("value"))
        elif label == "name":
            out["name"] = clean_text(lv.get("value"))
        elif title == "hashtags":
            out["hashtags"] = [clean_text(v.get("value")) for d in lv.get("dict") or []
                               for v in d.get("dict") or [] if v.get("value")]
        elif title == "owner" or label == "owner":
            for d in lv.get("dict") or []:
                for v in d.get("dict") or []:
                    if (v.get("label") or "").lower() == "username" and v.get("value"):
                        out["author"] = clean_text(v["value"])
        elif "dict" in lv and title in ("", "media"):
            # A saved collection lists its posts as nested records (titled "Media").
            out["items"] += [{"label_values": d.get("dict") or [], "timestamp": rec.get("timestamp")}
                             for d in lv.get("dict") or [] if isinstance(d, dict)]
    return out


def _post_text(caption, hashtags):
    if caption:
        return caption
    return " ".join("#" + h for h in hashtags if h) or None


def _link_record(code, at, estimated, author, text, ix_type, collection, source):
    created = instagram_shortcode_time(code)
    return Record(
        id=f"ig:{code}",
        platform="instagram",
        kind="text" if text else "link",
        url=f"https://www.instagram.com/p/{code}/",
        author=author,
        text=text,
        created_at=created,
        created_estimated=created is not None,
        interactions=[{"type": ix_type, "at": at, "estimated": estimated,
                       "collection": collection, "source": source}],
    )


def _link_records(archive, name, ix_type, collection_aware=False):
    data = _load(archive, name)
    if data is None:
        return
    current_collection = None
    for rec in _main_list(data):
        at_rec = rec.get("timestamp") if isinstance(rec, dict) and plausible_ts(rec.get("timestamp")) else 0
        lab = _labels(rec)
        if lab is not None:
            if lab["items"] and lab["name"]:          # a collection with its posts inside
                for item in lab["items"]:
                    il = _labels(item)
                    code = instagram_shortcode(il["url"] or "") if il else None
                    if code:
                        yield _link_record(code, at_rec, False, il["author"],
                                           _post_text(il["caption"], il["hashtags"]),
                                           ix_type, lab["name"], name)
                continue
            code = instagram_shortcode(lab["url"] or "")
            if code:
                yield _link_record(code, at_rec, not at_rec, lab["author"],
                                   _post_text(lab["caption"], lab["hashtags"]),
                                   ix_type, None, name)
            continue
        # Older shapes: string_list_data / string_map_data, and header rows for collections.
        f = _flatten_record(rec)
        code = next((instagram_shortcode(u) for u in f["urls"] if instagram_shortcode(u)), None)
        if collection_aware and not code and f["name"]:
            current_collection = f["name"]   # a collection header row
            continue
        if not code:
            continue
        at = max(f["stamps"]) if f["stamps"] else 0
        yield _link_record(code, at, not f["stamps"], f["author"], f["text"], ix_type,
                           current_collection if collection_aware else None, name)


def _media_entries(obj):
    """Media dicts ({uri, creation_timestamp, title?}) anywhere in a structure."""
    for d in _walk(obj):
        if isinstance(d.get("uri"), str) and ("creation_timestamp" in d or "title" in d):
            yield d


def _own_posts(archive: Archive, username: str | None):
    profile = f"https://www.instagram.com/{username}/" if username else None
    # Older exports keep your posts in content/, newer ones in your_instagram_activity/media/.
    files = archive.find(r"(^|/)(content|media)/(posts_\d+|reels|stories|igtv_videos|profile_photos)\.json$")
    for name in files:
        data = _load(archive, name)
        if data is None:
            continue
        collection = {"stories": "stories", "reels": "reels", "profile_photos": "profile photos"}.get(
            PurePosixPath(name).stem, None)
        for post in _main_list(data):
            entries = list(_media_entries(post))
            if not entries:
                continue
            caption = clean_text((post.get("title") if isinstance(post, dict) else None)
                                 or entries[0].get("title"))
            stamp = (post.get("creation_timestamp") if isinstance(post, dict) else None) \
                or entries[0].get("creation_timestamp") or 0
            media, kinds = [], set()
            for i, e in enumerate(entries):
                member = archive.find_suffix(e["uri"])
                is_video = ext_of(e["uri"]) in VIDEO_EXT
                kinds.add("video" if is_video else "image")
                if member:
                    media.append({"ord": i, "kind": "video" if is_video else "image",
                                  "data": archive.read(member), "name": member})
            pid = hashlib.sha1(entries[0]["uri"].encode()).hexdigest()[:16]
            yield Record(
                id=f"ig:own:{pid}",
                platform="instagram",
                kind="video" if kinds == {"video"} else "image",
                url=profile,
                author=username,
                text=caption,
                created_at=int(stamp) if stamp else None,
                hydrated=1,
                interactions=[{"type": "post", "at": stamp, "collection": collection,
                               "source": name}],
                media=media,
            )


def _comments(archive: Archive, username: str | None):
    for name in archive.find(r"(^|/)comments/[^/]*comments[^/]*\.json$"):
        data = _load(archive, name)
        if data is None:
            continue
        for rec in _main_list(data):
            f = _flatten_record(rec)
            if not f["text"]:
                continue
            at = max(f["stamps"]) if f["stamps"] else 0
            cid = hashlib.sha1(f"{at}:{f['text']}".encode()).hexdigest()[:16]
            yield Record(
                id=f"ig:comment:{cid}",
                platform="instagram",
                kind="text",
                author=username,
                text=f["text"],
                created_at=at or None,
                hydrated=1,
                interactions=[{"type": "comment", "at": at, "source": name}],
            )


def _username(archive: Archive) -> str | None:
    for name in archive.find(r"personal_information/personal_information\.json$"):
        data = _load(archive, name)
        for d in _walk(data):
            smd = d.get("string_map_data")
            if isinstance(smd, dict):
                u = (smd.get("Username") or {}).get("value")
                if u:
                    return u
    return None


def parse(archive: Archive):
    username = _username(archive)
    yield from _own_posts(archive, username)
    for name in archive.find(r"(^|/)liked_posts\.json$"):
        yield from _link_records(archive, name, "like")
    # Collections first, so a save keeps its collection name when it also
    # appears (without one) in saved_posts.json.
    for name in archive.find(r"(^|/)saved_collections\.json$"):
        yield from _link_records(archive, name, "save", collection_aware=True)
    for name in archive.find(r"(^|/)saved_posts\.json$"):
        yield from _link_records(archive, name, "save")
    yield from _comments(archive, username)
