"""Items that show the same picture from different places.

A post shared to Instagram and Facebook, the file it came from, a copy in another folder:
they stay separate items, each with its own link and history, and are drawn as one point
on the map, led by the largest picture. Same as `SamePictures` in the Mac app.

Perceptual hashes find the candidates, and the pixels decide: a flat frame (black, white,
a blank page) hashes like every other flat frame, and a burst shot or an edit hashes like
its neighbor, so both pictures need detail and their small copies have to all but match.
"""

from __future__ import annotations

import math
from collections import defaultdict

import numpy as np
from PIL import Image

from .db import GONE_SQL, SEARCH_ONLY_SQL

NEAR_BITS = 8          # hashes this many bits apart or closer are worth a look
CROWDED = 300          # a hash band shared by more pictures than this is flat frames
SIDE = 32              # the small copies compared, a side
LEAST_DETAIL = 0.06    # gray spread, 0-1, a picture needs to be told apart from another
MOST_DIFFERENCE = 0.01  # the most the small copies can differ, per channel on average
ASPECT_SLACK = 0.15    # how far apart the shapes can be, as log of the aspect ratio
# A video's picture is its poster, and two videos can share one and still be two videos.
UNMATCHED = ("youtube",)


def candidates(hashes: list[int]) -> list[tuple[int, int]]:
    """Pairs whose hashes are close, found through four 16-bit bands."""
    bands = defaultdict(list)
    for i, h in enumerate(hashes):
        for b in range(4):
            bands[(b, (h >> (16 * b)) & 0xFFFF)].append(i)
    out = set()
    for members in bands.values():
        if len(members) < 2 or len(members) > CROWDED:
            continue
        for x in range(len(members)):
            for y in range(x + 1, len(members)):
                a, b = members[x], members[y]
                if bin(hashes[a] ^ hashes[b]).count("1") <= NEAR_BITS:
                    out.add((a, b))
    return sorted(out)


def small(path) -> np.ndarray | None:
    try:
        with Image.open(path) as im:
            return np.asarray(im.convert("RGB").resize((SIDE, SIDE), Image.BILINEAR), dtype=np.float32).reshape(-1) / 255
    except OSError:
        return None


def detail(rgb: np.ndarray) -> float:
    return float(rgb.reshape(-1, 3).mean(1).std())


def same(x: np.ndarray, y: np.ndarray) -> bool:
    """Two small copies show the same picture: both have detail, and they all but match."""
    if detail(x) < LEAST_DETAIL or detail(y) < LEAST_DETAIL:
        return False
    return float(np.abs(x - y).mean()) < MOST_DIFFERENCE


def lead_key(p: dict):
    """The largest picture leads, then the one you had first, then by id."""
    return (-p["pixels"], p["time"], p["id"])


def sets(pictures: list[dict], matches: dict[int, list[int]]) -> list[list[int]]:
    """Sets, each led by its first member, which every other member matches itself.
    Matching isn't passed along: frames of a video each like the next would otherwise chain."""
    taken, out = set(), []
    for i in sorted(range(len(pictures)), key=lambda i: lead_key(pictures[i])):
        if i in taken:
            continue
        mates = sorted(m for m in matches.get(i, []) if m not in taken)
        if not mates:
            continue
        out.append([i] + mates)
        taken.add(i)
        taken.update(mates)
    return out


def find_same(lib, log=print) -> int:
    """Find the sets afresh and store them. Returns how many sets."""
    c = lib.conn
    times = dict(c.execute("select item_id, min(at) from interaction where at != 0 group by item_id"))
    searches = {r[0] for r in c.execute(SEARCH_ONLY_SQL)}
    marks = ",".join("?" * len(UNMATCHED))
    pictures = []
    for r in c.execute(f"""
            select m.item_id, m.phash, m.thumb_path, m.width, m.height from media m join item on item.id = m.item_id
            where m.status = 'ok' and m.phash is not null and m.thumb_path is not null and not ({GONE_SQL})
              and item.platform not in ({marks})
              and m.ord = (select min(ord) from media f where f.item_id = m.item_id and f.status = 'ok')
            order by m.item_id""", UNMATCHED):
        if r[0] in searches:
            continue
        w, h = r[3] or 0, r[4] or 0
        pictures.append({"id": r[0], "hash": int(r[1], 16), "thumb": r[2], "pixels": w * h,
                         "aspect": w / h if w and h else 1.0, "time": times.get(r[0]) or 2**62})
    cache: dict[int, np.ndarray | None] = {}

    def pixels(i):
        if i not in cache:
            cache[i] = small(lib.root / pictures[i]["thumb"])
        return cache[i]

    matches = defaultdict(list)
    for a, b in candidates([p["hash"] for p in pictures]):
        if abs(math.log(pictures[a]["aspect"] / pictures[b]["aspect"])) > ASPECT_SLACK:
            continue
        x, y = pixels(a), pixels(b)
        if x is None or y is None or not same(x, y):
            continue
        matches[a].append(b)
        matches[b].append(a)
    found = sets(pictures, matches)
    c.execute("delete from same_picture")
    c.executemany("insert into same_picture(item_id, lead) values (?, ?)",
                  [(pictures[m]["id"], pictures[s[0]]["id"]) for s in found for m in s])
    c.commit()
    log(f"{len(found):,} pictures found in more than one place, {sum(map(len, found)):,} items")
    return len(found)


def followers(lib) -> set[str]:
    """Items drawn where the item leading their set is."""
    return {r[0] for r in lib.conn.execute("select item_id from same_picture where item_id != lead")}
