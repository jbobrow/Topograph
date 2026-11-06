"""Searches from Google My Activity, from a Google Takeout export (choose JSON).

    Takeout/My Activity/Search/MyActivity.json, Image Search/, Discover/ ...

A search describes curiosity rather than taste, so each one becomes a text item on its
own platform, `google`, which the app keeps hidden on the terrain until you turn it on.

Only searches are read. Sites visited in Chrome are left out: they're far more private
and say little about taste. Searches that touch sensitive subjects (medical, identity,
tax, banking, passwords) are skipped by the same rules as your files.
"""

from __future__ import annotations

import hashlib
import json
import re

from ..db import Record
from ..util import Archive
from .files import SENSITIVE_PATH
from .youtube import _time

FILE_RX = r"(^|/)My Activity/([^/]+)/[^/]*\.json$"
READ = {"search", "image search", "discover"}
SEARCH_RX = re.compile(r"^Searched for\s+(.+)$", re.S)


def detect(archive: Archive) -> bool:
    return bool(archive.find(FILE_RX))


def parse(archive: Archive):
    for name in archive.find(FILE_RX):
        product = re.search(FILE_RX, name).group(2)
        if product.lower() not in READ:
            continue
        for entry in json.loads(archive.read_text(name)):
            match = SEARCH_RX.match(entry.get("title") or "")
            if not match:
                continue
            query = match.group(1).strip()
            if not query or SENSITIVE_PATH.search(query.lower()):
                continue
            # The same search again is one item you came back to.
            digest = hashlib.sha1(query.lower().encode()).hexdigest()[:16]
            yield Record(id=f"google:{digest}", platform="google", kind="text", text=query, hydrated=1,
                         url=entry.get("titleUrl"),
                         interactions=[{"type": "search", "at": _time(entry.get("time")),
                                        "collection": product, "source": name}])
