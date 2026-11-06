"""Small helpers: archives, dates, text repair, platform id tricks."""

from __future__ import annotations

import json
import re
import zipfile
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path, PurePosixPath


class Archive:
    """A uniform view over one or more export ZIPs and/or unzipped folders.

    Instagram splits large exports into several ZIPs; they are merged here into
    one namespace. Member names always use forward slashes.
    """

    def __init__(self, paths):
        self._members: dict[str, tuple] = {}
        self.sources = [Path(p).expanduser() for p in paths]
        for src in self.sources:
            if src.is_dir():
                for f in src.rglob("*"):
                    if f.is_file():
                        name = f.relative_to(src).as_posix()
                        self._members.setdefault(name, ("dir", f))
            elif zipfile.is_zipfile(src):
                z = zipfile.ZipFile(src)
                for info in z.infolist():
                    if not info.is_dir():
                        self._members.setdefault(info.filename, ("zip", z, info.filename))
            else:
                raise ValueError(f"Not a folder or ZIP: {src}")
        # Exports are sometimes zipped inside a top folder ("Archive of …"), so
        # importers match on path endings rather than assuming a root.

    def names(self):
        return list(self._members)

    def find(self, pattern: str):
        """Members whose path matches a regex (searched, not anchored at start)."""
        rx = re.compile(pattern)
        return sorted(n for n in self._members if rx.search(n))

    def find_suffix(self, suffix: str):
        suffix = suffix.lstrip("/")
        if suffix in self._members:
            return suffix
        for n in self._members:
            if n.endswith("/" + suffix):
                return n
        return None

    def read(self, name: str) -> bytes:
        entry = self._members[name]
        if entry[0] == "dir":
            return entry[1].read_bytes()
        return entry[1].read(entry[2])

    def read_text(self, name: str) -> str:
        return self.read(name).decode("utf-8", errors="replace")

    def read_json(self, name: str):
        return json.loads(self.read_text(name))


# --- text -----------------------------------------------------------------

def fix_mojibake(s: str) -> str:
    """Instagram exports UTF-8 text that was decoded as Latin-1. Undo that."""
    if not s or all(ord(ch) < 128 for ch in s):
        return s
    try:
        return s.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return s


def deep_fix_mojibake(obj):
    if isinstance(obj, str):
        return fix_mojibake(obj)
    if isinstance(obj, list):
        return [deep_fix_mojibake(v) for v in obj]
    if isinstance(obj, dict):
        return {fix_mojibake(k): deep_fix_mojibake(v) for k, v in obj.items()}
    return obj


# What X puts in an archive (or a fetched page) in place of a post that is gone:
# deleted, protected, suspended, withheld. Not anything you engaged with.
UNAVAILABLE = re.compile(
    r"\{learnmore\}"
    r"|^\s*(you[’']re unable to view this (post|tweet)"
    r"|this (post|tweet) (is from a suspended account|was deleted|is unavailable|has been deleted"
    r"|is from an account that no longer exists|violated|has been withheld|is no longer available))",
    re.IGNORECASE)


def is_unavailable(text: str | None) -> bool:
    return bool(text) and bool(UNAVAILABLE.search(text))


def has_words(text: str | None) -> bool:
    """Whether text says anything beyond links and @mentions."""
    if not text:
        return False
    rest = re.sub(r"https?://\S+|www\.\S+|(?<!\w)@\w+", " ", text)
    return len(re.sub(r"\W+", "", rest)) >= 3


def clean_text(s: str | None) -> str | None:
    if not s:
        return None
    s = s.strip()
    return s or None


# --- time -----------------------------------------------------------------

MIN_TS = 1104537600   # 2005-01-01
MAX_TS = 2208988800   # 2040-01-01


def plausible_ts(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and MIN_TS <= v <= MAX_TS


def parse_twitter_date(s: str) -> int | None:
    """'Wed Jul 03 14:23:01 +0000 2024' -> unix seconds."""
    try:
        return int(datetime.strptime(s, "%a %b %d %H:%M:%S %z %Y").timestamp())
    except (TypeError, ValueError):
        pass
    try:
        return int(parsedate_to_datetime(s).timestamp())
    except (TypeError, ValueError):
        pass
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except (TypeError, ValueError, AttributeError):
        return None


TWITTER_EPOCH_MS = 1288834974657


def snowflake_time(tweet_id) -> int | None:
    """X/Twitter ids since late 2010 encode their creation time."""
    try:
        n = int(tweet_id)
    except (TypeError, ValueError):
        return None
    ts = ((n >> 22) + TWITTER_EPOCH_MS) // 1000
    return ts if plausible_ts(ts) and n > 2**32 else None


_IG_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
INSTAGRAM_EPOCH_MS = 1314220021721


def instagram_shortcode_time(code: str) -> int | None:
    """Instagram media ids are time-ordered; decode a shortcode to a rough date."""
    code = code[:11]
    n = 0
    for ch in code:
        i = _IG_ALPHABET.find(ch)
        if i < 0:
            return None
        n = n * 64 + i
    ts = ((n >> 23) + INSTAGRAM_EPOCH_MS) // 1000
    return ts if plausible_ts(ts) else None


IG_URL_RX = re.compile(r"instagram\.com/(?:[A-Za-z0-9_.]+/)?(p|reel|reels|tv)/([A-Za-z0-9_-]+)")


def instagram_shortcode(url: str) -> str | None:
    m = IG_URL_RX.search(url or "")
    return m.group(2) if m else None


def iso(ts: int | None) -> str | None:
    if not ts:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d")


def ext_of(name: str) -> str:
    return PurePosixPath(name).suffix.lower()


VIDEO_EXT = {".mp4", ".mov", ".m4v", ".webm"}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
