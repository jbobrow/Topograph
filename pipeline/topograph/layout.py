"""Layout: project embeddings to 2D, find regions, and name them."""

from __future__ import annotations

import json
import warnings
from importlib import resources

import numpy as np

def load_vectors(lib, model: str):
    rows = lib.conn.execute("select item_id, vector from embedding where model=?", (model,)).fetchall()
    ids = [r["item_id"] for r in rows]
    vecs = np.frombuffer(b"".join(r["vector"] for r in rows), dtype=np.float32)
    return ids, vecs.reshape(len(ids), -1) if ids else np.zeros((0, 0), np.float32)


def project(vecs: np.ndarray, seed: int = 42) -> np.ndarray:
    n = len(vecs)
    if n < 4:
        return np.column_stack([np.arange(n, dtype=float), np.zeros(n)])
    if n < 16:
        from sklearn.decomposition import PCA
        return PCA(n_components=2, random_state=seed).fit_transform(vecs)
    import umap
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        reducer = umap.UMAP(n_components=2, metric="cosine", n_neighbors=min(30, n - 1),
                            min_dist=0.05, spread=1.0, random_state=seed)
        return reducer.fit_transform(vecs)


def cluster(xy: np.ndarray, min_size: int | None = None) -> np.ndarray:
    n = len(xy)
    if n < 10:
        return np.zeros(n, dtype=int)
    from sklearn.cluster import HDBSCAN
    # Fine regions; build_tree nests them into larger ones for zoomed-out views.
    min_size = min_size or max(12, n // 350)
    labels = HDBSCAN(min_cluster_size=min_size, min_samples=max(3, min_size // 3),
                     cluster_selection_method="leaf", copy=True).fit_predict(xy)
    if (labels >= 0).sum() == 0:
        return np.zeros(n, dtype=int)
    # Attach noise points to their nearest cluster so the map has no orphans;
    # keep them at -1 only if they are far from everything.
    noise = labels < 0
    if noise.any():
        from sklearn.neighbors import NearestNeighbors
        nn = NearestNeighbors(n_neighbors=1).fit(xy[~noise])
        dist, idx = nn.kneighbors(xy[noise])
        assigned = labels[~noise][idx[:, 0]]
        cutoff = np.percentile(dist, 75) * 2 if len(dist) > 3 else np.inf
        labels[noise] = np.where(dist[:, 0] <= cutoff, assigned, -1)
    return labels


def neighbors(vecs: np.ndarray, k: int = 8) -> np.ndarray:
    from sklearn.neighbors import NearestNeighbors
    k = min(k + 1, len(vecs))
    nn = NearestNeighbors(n_neighbors=k, metric="cosine", algorithm="brute").fit(vecs)
    _, idx = nn.kneighbors(vecs)
    return idx[:, 1:]


def place_clouds(sky: np.ndarray, land: np.ndarray, has_picture: np.ndarray, xy: np.ndarray, k: int = 8):
    """Where each search floats: over the pictures nearest it in meaning, averaged with the
    closest counting most, so a search between two subjects hangs between them.

    Scored as search by meaning scores (`EmbeddingStore.nearest` in the Mac app), for the same
    reasons: by plain similarity every search sat over the land made of words, whatever it was
    about. So each search is taken minus the average search, the land under it is pictures
    alone (the blended map still keeps words and pictures apart), and scores are in standard
    deviations. CLIP vectors, unit length. Returns positions and the nearest land, closest first.
    """
    under = np.flatnonzero(has_picture) if has_picture.any() else np.arange(len(land))
    candidates, places = land[under], xy[under]
    k = min(k, len(under))
    targets = sky - sky.mean(0)
    out = np.zeros((len(sky), 2))
    near = np.zeros((len(sky), k), dtype=int)
    for start in range(0, len(sky), 512):
        scores = targets[start:start + 512] @ candidates.T
        scores = (scores - scores.mean(1, keepdims=True)) / np.maximum(scores.std(1, keepdims=True), 1e-9)
        top = np.argpartition(-scores, k - 1, axis=1)[:, :k]
        top_scores = np.take_along_axis(scores, top, 1)
        order = np.argsort(-top_scores, axis=1)
        top, top_scores = np.take_along_axis(top, order, 1), np.take_along_axis(top_scores, order, 1)
        weights = np.exp((top_scores - top_scores[:, :1]) / 0.3)
        out[start:start + 512] = (weights[..., None] * places[top]).sum(1) / weights.sum(1, keepdims=True)
        near[start:start + 512] = under[top]
    return out, near


def load_concepts() -> list[str]:
    text = resources.files("topograph").joinpath("concepts.txt").read_text()
    return [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]


def load_modifiers() -> frozenset[str]:
    """Phrases in concepts.txt's "look and feel" section, which qualify a region's parent."""
    text = resources.files("topograph").joinpath("concepts.txt").read_text()
    out, inside, prev = set(), False, ""
    for ln in text.splitlines():
        ln = ln.strip()
        if ln.startswith("#"):
            if not prev:                      # a section header follows a blank line
                inside = ln.lower().startswith("# look and feel")
        elif ln and inside:
            out.add(ln)
        prev = ln
    return frozenset(out)


def phrase_embedder(lib, backend, model: str):
    """CLIP vectors for candidate names, cached in the library (they never change)."""
    if backend is None or not hasattr(backend, "phrases"):
        return None

    def embed(names):
        c = lib.conn
        have = {}
        for i in range(0, len(names), 500):
            chunk = names[i:i + 500]
            q = "select phrase, vector from phrase_vec where model=? and phrase in (%s)" % ",".join("?" * len(chunk))
            for r in c.execute(q, [model, *chunk]):
                have[r["phrase"]] = np.frombuffer(r["vector"], dtype=np.float32)
        todo = [nm for nm in names if nm not in have]
        if todo:
            vecs = backend.phrases(todo)
            c.executemany("insert or replace into phrase_vec(model, phrase, vector) values (?,?,?)",
                          [(model, nm, v.astype(np.float32).tobytes()) for nm, v in zip(todo, vecs)])
            c.commit()
            have.update(zip(todo, vecs))
        return np.array([have[nm] for nm in names], dtype=np.float32)
    return embed


def compute_layout(lib, model: str, backend=None, log=print, map_name: str = "pictures",
                   words_model: str | None = None) -> int:
    """Lay out and name one map (see maps.py). Other maps in the library are left alone.
    Searches stay out of the land and float over it as clouds (`place_clouds`)."""
    ids, vecs = load_vectors(lib, model)
    if not ids:
        log("Nothing embedded yet; run `topograph embed` first.")
        return 0
    from .db import SEARCH_ONLY_SQL
    searches = {r[0] for r in lib.conn.execute(SEARCH_ONLY_SQL)}
    is_sky = np.array([i in searches for i in ids])
    sky_ids, sky_vecs = [i for i, s in zip(ids, is_sky) if s], vecs[is_sky]
    ids, vecs = [i for i, s in zip(ids, is_sky) if not s], vecs[~is_sky]
    if not ids:
        log("Nothing to map yet: only searches, which float over the map.")
        return 0
    from .maps import layout_model, map_vectors
    from .progress import step
    with step(f"Arranging the {map_name} map"):
        arranged = map_vectors(lib, map_name, ids, vecs, words_model)
    with step(f"Laying out {len(ids):,} items on the map"):
        xy = project(arranged)
    # Fit into a 1000x1000 square for the viewer, keeping the aspect ratio
    # (distances on the map mean something) with a margin for the terrain.
    lo, hi = xy.min(0), xy.max(0)
    span = max(float((hi - lo).max()), 1e-9)
    xy = (xy - (lo + hi) / 2) / span * 900 + 500
    with step("Finding regions"):
        labels = cluster(xy)
    with step("Finding nearest neighbors"):
        nbrs = neighbors(arranged) if len(ids) > 1 else np.zeros((len(ids), 0), int)

    texts = {r["id"]: r["text"] for r in lib.conn.execute("select id, text from item")}
    visual = {r[0] for r in lib.conn.execute("select distinct item_id from media where status='ok'")}
    from .regions import anchor, build_tree, name_tree
    with step("Nesting regions"):
        regions, roots = build_tree(xy, labels)
    with step(f"Naming {len(regions):,} regions"):
        name_tree(regions, roots, vecs, [texts.get(i) for i in ids],
                  np.array([i in visual for i in ids]), load_concepts(),
                  embed_phrases=phrase_embedder(lib, backend, model), modifiers=load_modifiers())

    c = lib.conn
    stored = layout_model(model, map_name)
    c.execute("delete from layout where model=?", (stored,))
    c.execute("delete from cluster where model=?", (stored,))
    c.executemany(
        "insert into layout(item_id, model, x, y, cluster, neighbors) values (?,?,?,?,?,?)",
        [(iid, stored, float(xy[k, 0]), float(xy[k, 1]), int(labels[k]),
          json.dumps([ids[j] for j in nbrs[k]])) for k, iid in enumerate(ids)])
    for rid, r in regions.items():
        x, y, rad = anchor(xy, r.members)
        c.execute("insert into cluster(model, id, label, terms, parent, depth, x, y, r) "
                  "values (?,?,?,?,?,?,?,?,?)",
                  (stored, int(rid), r.label, json.dumps(r.terms), r.parent, r.depth, x, y, rad))
    c.execute("delete from cloud where model=?", (stored,))
    if sky_ids:
        with step(f"Setting {len(sky_ids):,} searches over the land"):
            places, near = place_clouds(sky_vecs, vecs, np.array([i in visual for i in ids]), xy)
        c.executemany(
            "insert into cloud(item_id, model, x, y, region, near) values (?,?,?,?,?,?)",
            [(iid, stored, float(places[k, 0]), float(places[k, 1]), int(labels[near[k, 0]]),
              json.dumps([ids[j] for j in near[k]])) for k, iid in enumerate(sky_ids)])
    lib.set_meta("map", map_name)
    c.commit()
    top = sorted(roots, key=lambda k: -len(regions[k].members))
    log(f"  {len(regions)} regions in {max(r.depth for r in regions.values()) + 1 if regions else 0} "
        f"levels; largest: " + ", ".join(regions[k].label for k in top[:8]))
    if sky_ids:
        log(f"  {len(sky_ids):,} searches float over it as clouds.")
    log("  See them all with `topograph regions`.")
    return len(ids)
