"""YouTube, from a Google Takeout export (choose JSON for history).

    Takeout/YouTube and YouTube Music/history/watch-history.json
    Takeout/YouTube and YouTube Music/playlists/<name>-videos.csv   (Video ID, timestamp)
    Takeout/YouTube and YouTube Music/comments/comments.csv

Videos arrive with no picture. `topograph hydrate` fetches each one's thumbnail from
the public thumbnail address, by video id.
"""

from __future__ import annotations

import csv
import io
import json
import re
from datetime import datetime
from pathlib import PurePosixPath

from ..db import Record
from ..util import Archive, clean_text

ROOT = r"(^|/)YouTube[^/]*/"
VIDEO_RX = re.compile(r"[?&]v=([\w-]{6,})")


def thumbnail_url(video_id: str) -> str:
    return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"


def _time(value: str | None) -> int:
    """Takeout's ISO times, with or without fractions, and its `+00:00` style."""
    if not value:
        return 0
    text = value.strip().replace("Z", "+00:00").replace(" UTC", "+00:00")
    try:
        return int(datetime.fromisoformat(text).timestamp())
    except ValueError:
        return 0


def _rows(archive: Archive, name: str):
    return csv.DictReader(io.StringIO(archive.read_text(name)))


def detect(archive: Archive) -> bool:
    return bool(archive.find(ROOT + r"history/watch-history\.json$")
                or archive.find(ROOT + r"playlists/[^/]+\.csv$"))


def _video(video_id: str, interactions: list[dict], title=None, author=None) -> Record:
    return Record(id=f"youtube:{video_id}", platform="youtube", kind="video",
                  url=f"https://www.youtube.com/watch?v={video_id}",
                  text=title, author=author, interactions=interactions)


def parse(archive: Archive):
    for name in archive.find(ROOT + r"history/watch-history\.json$"):
        for entry in json.loads(archive.read_text(name)):
            match = VIDEO_RX.search(entry.get("titleUrl") or "")
            if not match:
                continue    # a video that's since been removed leaves no link
            title = re.sub(r"^Watched\s+", "", clean_text(entry.get("title")) or "") or None
            channel = (entry.get("subtitles") or [{}])[0].get("name")
            yield _video(match.group(1), [{"type": "view", "at": _time(entry.get("time")), "source": name}],
                         title=title, author=channel)

    for name in archive.find(ROOT + r"playlists/[^/]+\.csv$"):
        stem = PurePosixPath(name).stem
        if stem.lower() in ("playlists", "playlist"):
            continue    # the list of playlists, not a playlist
        playlist = re.sub(r"-videos$", "", stem)
        liked = playlist.lower() in ("liked videos", "liked", "likes", "favorites")
        for row in _rows(archive, name):
            video_id = (row.get("Video ID") or row.get("Video Id") or "").strip()
            if not video_id:
                continue
            when = _time(row.get("Playlist Video Creation Timestamp") or row.get("Playlist video creation timestamp"))
            kind = {"type": "like", "at": when, "source": name} if liked else \
                {"type": "save", "at": when, "collection": playlist, "source": name}
            yield _video(video_id, [kind])

    for name in archive.find(ROOT + r"comments/[^/]*comments[^/]*\.csv$"):
        for row in _rows(archive, name):
            video_id = (row.get("Video ID") or "").strip()
            if video_id:
                yield _video(video_id, [{"type": "comment", "at": _time(row.get("Comment Create Timestamp")), "source": name}])
