"""The same picture from several places is drawn once, led by the largest copy."""

import io
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from topograph import same  # noqa: E402
from topograph.db import Library  # noqa: E402
from topograph.export import export  # noqa: E402


def shapes(seed: int) -> bytes:
    rnd = np.random.default_rng(seed)
    im = Image.new("RGB", (480, 360), (230, 230, 230))
    d = ImageDraw.Draw(im)
    for _ in range(8):
        x, y = int(rnd.integers(0, 400)), int(rnd.integers(0, 300))
        d.rectangle([x, y, x + 80, y + 60], fill=(int(rnd.integers(0, 256)), int(rnd.integers(0, 256)), 50))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def small(seed, flat=False):
    rnd = np.random.default_rng(seed)
    return np.full(same.SIDE * same.SIDE * 3, 0.5, np.float32) if flat else rnd.random(same.SIDE * same.SIDE * 3).astype(np.float32)


def test_same_needs_detail_and_almost_every_pixel():
    p = small(1)
    assert same.same(p, np.minimum(p + 0.005, 1))
    assert not same.same(p, small(2))
    assert not same.same(small(0, True), small(0, True)), "flat frames say nothing"


def test_every_member_matches_the_lead_itself():
    pictures = [{"id": i, "pixels": 1000 - n, "time": 0} for n, i in enumerate("abc")]
    assert same.sets(pictures, {0: [1], 1: [0, 2], 2: [1]}) == [[0, 1]]


def test_candidates_are_close_hashes_only():
    assert same.candidates([0xFFFF0000FFFF0000, 0xFFFF0000FFFF0001, 0x0123456789ABCDEF]) == [(0, 1)]


def library_with_copies(tmp_path):
    lib = Library(tmp_path / "lib")
    photo, other = shapes(3), shapes(9)
    for iid, platform, data, width, text in [("file:1", "files", photo, 4000, "IMG_0042, in Photos"),
                                             ("ig:1", "instagram", photo, 1080, "Ferns after rain"),
                                             ("x:1", "x", other, 1200, "something else"),
                                             ("youtube:1", "youtube", photo, 1280, "a video")]:
        (lib.root / "media").mkdir(exist_ok=True)
        (lib.root / f"media/{iid}.jpg").write_bytes(data)
        lib.conn.execute("insert into item(id, platform, hydrated, text) values (?, ?, 1, ?)", (iid, platform, text))
        lib.conn.execute("insert into interaction(item_id, type, at) values (?, ?, 1)",
                         (iid, "made" if platform == "files" else "post"))
        lib.conn.execute("insert into media(item_id, ord, thumb_path, width, height, phash, status) "
                         "values (?, 0, ?, ?, ?, 'ffff0000ffff0000', 'ok')", (iid, f"media/{iid}.jpg", width, width * 3 // 4))
    lib.conn.commit()
    return lib


def test_finds_copies_across_places_and_leads_with_the_largest(tmp_path):
    lib = library_with_copies(tmp_path)
    assert same.find_same(lib, log=lambda *_: None) == 1
    rows = lib.conn.execute("select item_id, lead from same_picture order by item_id").fetchall()
    assert [tuple(r) for r in rows] == [("file:1", "file:1"), ("ig:1", "file:1")]
    assert same.followers(lib) == {"ig:1"}


def test_export_draws_a_set_once(tmp_path):
    lib = library_with_copies(tmp_path)
    same.find_same(lib, log=lambda *_: None)
    for iid in ("file:1", "ig:1", "x:1"):     # laid out before the sets were found
        lib.conn.execute("insert into layout(item_id, model, x, y, cluster) values (?, 'm', 1, 1, 0)", (iid,))
    lib.conn.commit()
    data = json.loads(export(lib, "m").read_text())
    ids = {it["id"]: it for it in data["items"]}
    assert set(ids) == {"file:1", "x:1"}
    assert ids["file:1"]["al"] == ["instagram"] and ids["file:1"]["t"] == "Ferns after rain"
    assert ids["file:1"]["r"] == 2.5 + 2.5   # made and posted
    assert sum(data["unmapped"].values()) == 1   # the video, which isn't matched; the post isn't waiting
