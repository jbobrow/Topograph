"""Maps: the same items arranged different ways, side by side in one library.

  pictures  The CLIP vectors alone: mostly how things look, captions counted a little.
  words     CLIP plus a text model. CLIP puts text and pictures in different parts of its
            space, so each kind's own average is taken away first, letting what things are
            about count for more than what kind of thing they are.
  blended   Words, then your files are moved toward posts about the same thing. The suggested
            one. Without this, files gather in their own regions, because a screenshot or a
            CAD render looks unlike anything posted.

Tuned on the owner's real library, not fixtures. Each map's positions and regions are stored
under their own name in `layout` and `cluster`. The CLIP vectors don't change, so search by
meaning, region names and everything else that reads them work the same on every map.
"""

from __future__ import annotations

import re

import numpy as np

MAPS = ("blended", "words", "pictures")
DEFAULT_MAP = "blended"

# Filename parts that say nothing about what a file is.
GENERIC = frozenset("img image images dsc dscn photo photos pic screenshot simulator screen shot untitled "
                    "copy final crop draft render export pxl mov video assets asset".split())


def layout_model(base: str, name: str) -> str:
    """The name a map is stored under. Pictures keeps the plain name it has always had."""
    return base if name == "pictures" else f"{base}+{name}"


def _file_words(part: str) -> list[str]:
    part = re.sub(r"([a-z])([A-Z])", r"\1 \2", part)
    return [w for w in re.split(r"[\s_\-.,()\[\]]+", part)
            if w and w.lower() not in GENERIC and not any(ch.isdigit() for ch in w)]


def clean_file_text(text: str) -> str:
    """A file's text is "<name>, in <folder>". Keep the words in it that mean something."""
    name, _, folder = text.partition(", in ")
    return " ".join(_file_words(name) + _file_words(folder))


def clean_post_text(text: str) -> str:
    """A post's words, without the links and handles that don't say what it's about."""
    text = text.replace("&amp;", "&").replace("&gt;", ">").replace("&lt;", "<")
    text = re.sub(r"https?://\S+", " ", text)
    text = re.sub(r"^RT @\w+:?", " ", text)
    text = re.sub(r"[.]?@\w+", " ", text)
    text = text.replace("#", " ")
    return re.sub(r"\s+", " ", text).strip()


def clean_text(platform: str, text: str | None) -> str:
    if not text:
        return ""
    return clean_file_text(text) if platform == "files" else clean_post_text(text)


def words_weight(word_count: int, is_file: bool) -> float:
    """A sentence says more than a filename, and a word or two says too little to count."""
    if word_count < 2:
        return 0.0
    weight = min(1.0, 0.3 + (word_count - 2) / 18 * 0.7)
    return min(weight, 0.6) if is_file else weight


def embed_words(lib, backend, base: str) -> int:
    """A text-model vector for every mapped item with words, kept in `embedding` under the
    text model's own name. Resumable, and hydrate clears them when an item's text arrives."""
    c = lib.conn
    rows = c.execute(
        "select i.id, i.platform, i.text from item i where exists "
        "(select 1 from embedding e where e.item_id=i.id and e.model=?) and not exists "
        "(select 1 from embedding e where e.item_id=i.id and e.model=?)", (base, backend.name)).fetchall()
    todo = [(r["id"], t) for r in rows if (t := clean_text(r["platform"], r["text"]))]
    if not todo:
        return 0
    from .progress import Progress
    with Progress("Reading the words", total=len(todo), unit="items") as prog:
        for start in range(0, len(todo), 256):
            part = todo[start:start + 256]
            vecs = backend.texts([t for _, t in part])
            c.executemany("insert or replace into embedding(item_id, model, vector) values (?,?,?)",
                          [(iid, backend.name, v.astype(np.float32).tobytes()) for (iid, _), v in zip(part, vecs)])
            c.commit()
            prog.advance(len(part))
        prog.close(f"{len(todo):,} items")
    return len(todo)


def _unit(vectors: np.ndarray) -> np.ndarray:
    return vectors / np.maximum(np.linalg.norm(vectors, axis=1, keepdims=True), 1e-9)


def pull_files_to_posts(vectors: np.ndarray, is_file: np.ndarray, k: int = 20, near: int = 50) -> np.ndarray:
    """Move files toward posts about the same thing, leaving posts where they are.

    Where a file and a post each count the other among their closest, they're taken to be
    about the same thing (mutual nearest neighbors). Each file then moves by the average of
    the differences of the pairs near it, so what's shared lines up, and what only your
    files have keeps its shape instead of being forced onto something unrelated.
    """
    files, posts = np.where(is_file)[0], np.where(~is_file)[0]
    k = min(k, len(files), len(posts))
    if k < 1:
        return vectors

    def closest(a, b):
        out = np.empty((len(a), k), np.int32)
        for start in range(0, len(a), 2000):
            sim = vectors[a[start:start + 2000]] @ vectors[b].T
            out[start:start + 2000] = np.argpartition(-sim, k - 1, axis=1)[:, :k]
        return out

    from_files, from_posts = closest(files, posts), closest(posts, files)
    back = [set(row.tolist()) for row in from_posts]
    shift = np.zeros((len(files), vectors.shape[1]), np.float32)
    pairs = np.zeros(len(files), np.int32)
    for i, row in enumerate(from_files):
        for j in row:
            if i in back[j]:
                shift[i] += vectors[posts[j]] - vectors[files[i]]
                pairs[i] += 1
    anchors = np.where(pairs > 0)[0]
    if not len(anchors):
        return vectors
    shift = shift[anchors] / pairs[anchors, None]
    at = vectors[files[anchors]]
    near = min(near, len(anchors))
    moved = vectors.copy()
    for start in range(0, len(files), 2000):
        part = files[start:start + 2000]
        sim = vectors[part] @ at.T
        nearest = np.argpartition(-sim, near - 1, axis=1)[:, :near]
        closeness = np.take_along_axis(sim, nearest, 1)
        weight = np.exp((closeness - closeness.max(1, keepdims=True)) / 0.05)
        weight /= weight.sum(1, keepdims=True)
        moved[part] += (shift[nearest] * weight[..., None]).sum(1)
    return _unit(moved)


def map_vectors(lib, name: str, ids: list[str], clip: np.ndarray, words_model: str | None) -> np.ndarray:
    """What a map is laid out from, in the same order as `ids`."""
    if name == "pictures":
        return clip
    if not words_model:
        raise ValueError(f"The {name} map needs a text model")
    c = lib.conn
    info = {r["id"]: (r["platform"], r["text"]) for r in c.execute("select id, platform, text from item")}
    pictures = {r[0] for r in c.execute("select distinct item_id from media where status='ok'")}
    vectors = {r[0]: r[1] for r in c.execute("select item_id, vector from embedding where model=?", (words_model,))}
    dim = len(next(iter(vectors.values()))) // 4 if vectors else 1
    words = np.zeros((len(ids), dim), np.float32)
    weights = np.zeros(len(ids), np.float32)
    is_file = np.zeros(len(ids), bool)
    has_picture = np.zeros(len(ids), bool)
    for k, iid in enumerate(ids):
        platform, text = info[iid]
        is_file[k] = platform == "files"
        has_picture[k] = iid in pictures
        if iid in vectors:
            words[k] = np.frombuffer(vectors[iid], np.float32)
            weights[k] = words_weight(len(clean_text(platform, text).split()), is_file[k])
    aligned = clip.copy()
    for kind in (has_picture, ~has_picture):
        if kind.any():
            aligned[kind] -= aligned[kind].mean(0)
    mixed = _unit(np.hstack([_unit(aligned), words * weights[:, None]]))
    return pull_files_to_posts(mixed, is_file) if name == "blended" else mixed
