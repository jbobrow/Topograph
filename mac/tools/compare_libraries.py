#!/usr/bin/env python3
"""Compare two libraries row by row: one built by the Python tools, one by the Swift port.

    python mac/tools/compare_libraries.py PYTHON_LIBRARY SWIFT_LIBRARY [--like PLATFORM]

It prints counts, field names and item ids, never captions or file names, so its output
can be shared. Pictures can't match byte for byte (different encoders, video frames), so
those compare by what they should agree on: status, size, perceptual hash, leading color.
"""

import json
import sqlite3
import sys
from collections import Counter
from pathlib import Path

ITEM_FIELDS = ("platform", "kind", "url", "author", "text", "created_at", "created_estimated", "hydrated")


def connect(root):
    return sqlite3.connect(f"file:{Path(root) / 'topograph.sqlite'}?mode=ro", uri=True)


def distance(a, b):
    return bin(int(a, 16) ^ int(b, 16)).count("1")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    a, b = connect(args[0]), connect(args[1])
    sample = {}

    def note(kind, key):
        sample.setdefault(kind, []).append(key)

    items_a = {r[0]: r[1:] for r in a.execute(f"select id, {','.join(ITEM_FIELDS)} from item")}
    items_b = {r[0]: r[1:] for r in b.execute(f"select id, {','.join(ITEM_FIELDS)} from item")}
    print(f"items: {len(items_a):,} python, {len(items_b):,} swift")
    for iid in items_a.keys() - items_b.keys():
        note("only in python", iid)
    for iid in items_b.keys() - items_a.keys():
        note("only in swift", iid)
    for iid in items_a.keys() & items_b.keys():
        for field, x, y in zip(ITEM_FIELDS, items_a[iid], items_b[iid]):
            if x != y:
                note(f"item.{field}", iid)

    q = "select item_id, type, at, at_estimated, collection, source_file from interaction"
    ix_a, ix_b = set(a.execute(q)), set(b.execute(q))
    print(f"interactions: {len(ix_a):,} python, {len(ix_b):,} swift")
    for row in ix_a - ix_b:
        note("interaction only in python", f"{row[0]} {row[1]}")
    for row in ix_b - ix_a:
        note("interaction only in swift", f"{row[0]} {row[1]}")

    q = "select item_id, ord, kind, original_url, status, width, height, phash, palette from media"
    m_a = {(r[0], r[1]): r[2:] for r in a.execute(q)}
    m_b = {(r[0], r[1]): r[2:] for r in b.execute(q)}
    print(f"media: {len(m_a):,} python, {len(m_b):,} swift")
    for key in m_a.keys() - m_b.keys():
        note("media only in python", f"{key[0]} {key[1]}")
    for key in m_b.keys() - m_a.keys():
        note("media only in swift", f"{key[0]} {key[1]}")
    bits, colors = Counter(), []
    for key in m_a.keys() & m_b.keys():
        ra, rb = m_a[key], m_b[key]
        for field, x, y in zip(("kind", "original_url", "status", "width", "height"), ra, rb):
            if x != y:
                note(f"media.{field}", f"{key[0]} {key[1]} {x if field != 'original_url' else ''} {y if field != 'original_url' else ''}")
        if ra[5] and rb[5]:
            bits[min(distance(ra[5], rb[5]) // 4 * 4, 32)] += 1
        if ra[6] and rb[6]:
            pa, pb = json.loads(ra[6])[0][0], json.loads(rb[6])[0][0]
            colors.append(sum(abs(int(pa[i:i + 2], 16) - int(pb[i:i + 2], 16)) for i in (1, 3, 5)))
    if bits:
        print("perceptual hash, bits apart:", ", ".join(f"{k}-{k + 3}: {v:,}" for k, v in sorted(bits.items())))
    if colors:
        colors.sort()
        print(f"leading color, summed channel difference: median {colors[len(colors) // 2]}, 90th {colors[len(colors) * 9 // 10]}")

    if not sample:
        print("no differences")
    for kind, keys in sorted(sample.items()):
        print(f"{kind}: {len(keys):,}  e.g. {sorted(keys)[:4]}")


if __name__ == "__main__":
    main()
