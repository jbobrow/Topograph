"""Maps: the same items arranged different ways, side by side in one library."""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fixtures import build_x_archive  # noqa: E402
from topograph import cli  # noqa: E402
from topograph.db import Library  # noqa: E402
from topograph.maps import (clean_file_text, clean_post_text, layout_model, map_vectors,  # noqa: E402
                            pull_files_to_posts, words_weight)


def test_file_names_keep_only_what_means_something():
    assert clean_file_text("IMG_2041, in Dropbox/Blinks") == "Dropbox/Blinks"
    assert clean_file_text("Screenshot 2024-01-02, in Desktop") == "Desktop"
    assert clean_file_text("laserCutParts_final, in CAD models") == "laser Cut Parts CAD models"


def test_post_words_lose_links_and_handles():
    assert clean_post_text("RT @maker: new dice &amp; tiles https://t.co/abc #boardgames @you") == "new dice & tiles boardgames"
    assert clean_post_text("https://t.co/abc") == ""


def test_a_sentence_counts_more_than_a_filename():
    assert words_weight(1, False) == 0
    assert words_weight(20, False) == 1
    assert words_weight(20, True) == 0.6
    assert 0.3 <= words_weight(2, False) < words_weight(10, False)


def _unit(rows):
    rows = np.array(rows, np.float32)
    return rows / np.linalg.norm(rows, axis=1, keepdims=True)


def test_files_move_toward_posts_and_posts_stay():
    rng = np.random.default_rng(0)
    centers = _unit(rng.normal(size=(3, 32)))
    offset = _unit(rng.normal(size=(1, 32)))[0] * 0.6
    posts = _unit(np.repeat(centers, 30, 0) + rng.normal(scale=0.05, size=(90, 32)))
    files = _unit(np.repeat(centers, 30, 0) + offset + rng.normal(scale=0.05, size=(90, 32)))
    vectors = np.vstack([posts, files]).astype(np.float32)
    is_file = np.array([False] * 90 + [True] * 90)
    moved = pull_files_to_posts(vectors, is_file, k=10, near=20)
    assert np.allclose(moved[:90], vectors[:90])
    closeness = lambda v: (v[90:] * posts).sum(1).mean()   # each file beside the post of the same subject
    assert closeness(moved) > closeness(vectors) + 0.05


def test_nothing_to_pull_together_leaves_vectors_alone():
    vectors = _unit(np.eye(4))
    assert pull_files_to_posts(vectors, np.zeros(4, bool)) is vectors
    assert pull_files_to_posts(vectors, np.ones(4, bool)) is vectors


def test_maps_sit_side_by_side(tmp_path):
    lib_dir = tmp_path / "lib"
    args = ["--library", str(lib_dir)]
    cli.main(args + ["import", str(build_x_archive(tmp_path / "twitter.zip")), "--platform", "x"])
    cli.main(args + ["build", "--backend", "lite"])

    def read():
        lib = Library(lib_dir)
        out = {m: dict((r[0], (r[1], r[2])) for r in lib.conn.execute("select item_id, x, y from layout where model=?", (m,)))
               for m in ("lite-v1", "lite-v1+words", "lite-v1+blended")}
        chosen = lib.get_meta("map")
        lib.close()
        return out, chosen

    pictures, chosen = read()
    assert chosen == "pictures" and pictures["lite-v1"] and not pictures["lite-v1+blended"]

    cli.main(args + ["build", "--backend", "lite", "--map", "blended"])
    both, chosen = read()
    assert chosen == "blended"
    assert both["lite-v1"] == pictures["lite-v1"], "building one map leaves the others alone"
    assert set(both["lite-v1+blended"]) == set(both["lite-v1"])

    lib = Library(lib_dir)
    assert lib.get_meta("embedding_model") == "lite-v1", "the picture vectors stay what the app reads"
    words = lib.conn.execute("select count(*) from embedding where model='lite-words-v1'").fetchone()[0]
    regions = lib.conn.execute("select count(*) from cluster where model='lite-v1+blended'").fetchone()[0]
    lib.close()
    assert words and regions

    # With no map named, it stays on the one built last.
    cli.main(args + ["layout", "--backend", "lite"])
    assert read()[1] == "blended"


def test_words_are_only_read_once(tmp_path):
    lib_dir = tmp_path / "lib"
    args = ["--library", str(lib_dir)]
    cli.main(args + ["import", str(build_x_archive(tmp_path / "twitter.zip")), "--platform", "x"])
    cli.main(args + ["build", "--backend", "lite", "--map", "words"])

    from topograph.embed import LiteWords
    from topograph.maps import embed_words
    lib = Library(lib_dir)
    assert embed_words(lib, LiteWords(), "lite-v1") == 0
    lib.close()


def test_map_vectors_line_up_with_ids(tmp_path):
    lib_dir = tmp_path / "lib"
    args = ["--library", str(lib_dir)]
    cli.main(args + ["import", str(build_x_archive(tmp_path / "twitter.zip")), "--platform", "x"])
    cli.main(args + ["build", "--backend", "lite", "--map", "words"])
    from topograph.layout import load_vectors
    lib = Library(lib_dir)
    ids, clip = load_vectors(lib, "lite-v1")
    assert map_vectors(lib, "pictures", ids, clip, None) is clip
    mixed = map_vectors(lib, "words", ids, clip, "lite-words-v1")
    lib.close()
    assert len(mixed) == len(ids) and mixed.shape[1] == clip.shape[1] * 2
    assert np.allclose(np.linalg.norm(mixed, axis=1), 1)


def test_layout_model_names():
    assert layout_model("clip-vit-b-32", "pictures") == "clip-vit-b-32"
    assert layout_model("clip-vit-b-32", "blended") == "clip-vit-b-32+blended"


def test_hydrate_never_holds_the_library_while_fetching(tmp_path, monkeypatch):
    """It runs for days, and a write it leaves open stops every other tool from writing."""
    from topograph import hydrate as hydrate_mod
    lib = Library(tmp_path / "lib")
    lib.conn.executemany("insert into item(id, platform) values (?, 'x')", [("x:1",), ("x:2",)])
    lib.conn.commit()
    open_during_fetch = []

    def found(item):
        open_during_fetch.append(lib.conn.in_transaction)
        return {"text": "words", "author": None, "created_at": None,
                "media": [{"url": "https://example.test/a.jpg", "video": False}]}

    def fetch(url, accept=None):
        open_during_fetch.append(lib.conn.in_transaction)
        raise hydrate_mod.FetchError("no network in tests")

    monkeypatch.setitem(hydrate_mod.HYDRATORS, "x", found)
    monkeypatch.setattr(hydrate_mod, "fetch", fetch)
    hydrate_mod.hydrate(lib, delay=0, log=lambda _: None)
    assert open_during_fetch == [False, False, False, False]
    assert not lib.conn.in_transaction
    lib.close()


def test_hydrate_tries_posts_it_has_not_tried_before_ones_that_failed(tmp_path, monkeypatch):
    from topograph import hydrate as hydrate_mod
    lib = Library(tmp_path / "lib")
    lib.conn.executemany("insert into item(id, platform, hydrate_attempts) values (?, 'x', ?)",
                         [("x:failed-newest", 1), ("x:new", 0), ("x:last-chance", 2), ("x:older", 0)])
    lib.conn.executemany("insert into interaction(item_id, type, at) values (?, 'like', ?)",
                         [("x:failed-newest", 400), ("x:new", 300), ("x:last-chance", 200), ("x:older", 100)])
    lib.conn.commit()
    asked = []

    def gone(item):
        asked.append(item["id"])
        return None

    monkeypatch.setitem(hydrate_mod.HYDRATORS, "x", gone)
    stats = hydrate_mod.hydrate(lib, delay=0, log=lambda _: None)
    assert asked == ["x:new", "x:older", "x:failed-newest", "x:last-chance"]
    assert (stats["to_retry"], stats["unreachable"]) == (3, 1)
    lib.close()


def test_hydrate_counts_only_posts_it_can_fetch(tmp_path, monkeypatch):
    from topograph import hydrate as hydrate_mod
    lib = Library(tmp_path / "lib")
    lib.conn.executemany("insert into item(id, platform) values (?, ?)",
                         [("x:1", "x"), ("fb:link:1", "facebook"), ("ig:abc", "instagram")])
    lib.conn.commit()
    monkeypatch.setitem(hydrate_mod.HYDRATORS, "x", lambda item: None)
    monkeypatch.setitem(hydrate_mod.HYDRATORS, "instagram", lambda item: None)

    class Progress:
        def set_total(self, n): self.total = n
        def advance(self, note=None): pass
        def write(self, text): pass
    progress = Progress()
    hydrate_mod.hydrate(lib, delay=0, platforms={"x"}, progress=progress)
    assert progress.total == 1, "the X post, not Facebook's link or the Instagram post"
    lib.close()


def test_posts_saved_with_instagrams_logo_go_back_to_waiting(tmp_path):
    from topograph import hydrate as hydrate_mod
    lib = Library(tmp_path / "lib")
    c = lib.conn
    # How a post the sign-in page stood in for was stored, and a post that was really fetched.
    for item_id, text, image in (
            ("ig:walled", "Instagram", "https://static.cdninstagram.com/rsrc.php/v4/yD/r/R0fBIMurK8v.png"),
            ("ig:real", "Concrete stairs", "https://scontent.cdninstagram.com/b.jpg")):
        c.execute("insert into item(id, platform, kind, text, hydrated) values (?, 'instagram', 'image', ?, 1)",
                  (item_id, text))
        c.execute("insert into media(item_id, ord, original_url, status) values (?, 0, ?, 'ok')", (item_id, image))
        c.execute("insert into embedding(item_id, model, vector) values (?, 'clip-vit-b-32', x'00')", (item_id,))
        c.execute("insert into layout(item_id, model, x, y, cluster) values (?, 'clip-vit-b-32', 1, 1, 0)", (item_id,))
    c.commit()
    assert hydrate_mod.forget_sign_in_pages(lib) == 1
    walled = c.execute("select hydrated, hydrate_attempts, kind, text from item where id='ig:walled'").fetchone()
    assert tuple(walled) == (0, 0, "link", None)
    for table in ("media", "embedding", "layout"):
        counts = dict(c.execute(f"select item_id, count(*) from {table} group by item_id").fetchall())
        assert counts == {"ig:real": 1}, table
    assert c.execute("select text from item where id='ig:real'").fetchone()[0] == "Concrete stairs"
    assert hydrate_mod.forget_sign_in_pages(lib) == 0
    lib.close()


def test_a_tool_waits_for_another_one_to_finish_writing(tmp_path):
    lib = Library(tmp_path / "lib")
    assert lib.conn.execute("pragma busy_timeout").fetchone()[0] == 120_000
    lib.close()


def test_searches_float_over_the_pictures_they_are_about():
    from topograph.layout import place_clouds
    rng = np.random.default_rng(1)
    subjects = _unit(rng.normal(size=(3, 32)))
    # Words sit apart on the map, and every search shares a lean toward words.
    wordy = _unit(rng.normal(size=(1, 32)))[0]
    pictures = _unit(np.repeat(subjects, 20, 0) + rng.normal(scale=0.05, size=(60, 32)))
    words = _unit(np.repeat(subjects, 20, 0) * 0.3 + wordy + rng.normal(scale=0.05, size=(60, 32)))
    land = np.vstack([pictures, words]).astype(np.float32)
    has_picture = np.array([True] * 60 + [False] * 60)
    xy = np.vstack([np.repeat([[100, 100], [500, 900], [900, 100]], 20, 0) + rng.normal(scale=5, size=(60, 2)),
                    np.full((60, 2), 500.0)])
    searches = _unit(np.repeat(subjects, 5, 0) * 0.5 + wordy + rng.normal(scale=0.05, size=(15, 32)))
    places, near = place_clouds(searches, land, has_picture, xy)
    for subject, center in enumerate([[100, 100], [500, 900], [900, 100]]):
        mine = slice(subject * 5, subject * 5 + 5)
        assert np.linalg.norm(places[mine] - center, axis=1).max() < 40, "over its own subject's pictures"
        assert (near[mine, 0] // 20 == subject).all() and (near[mine] < 60).all()
