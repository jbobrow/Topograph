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
