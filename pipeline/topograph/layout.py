"""Layout: project embeddings to 2D, find regions, and name them."""

from __future__ import annotations

import json
import re
import warnings
from importlib import resources

import numpy as np

STOP_EXTRA = {"https", "http", "amp", "rt", "t", "co", "www", "com", "just", "like", "im",
              "don", "it's", "i'm", "via", "new", "one", "get", "got", "really", "know"}


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
    min_size = min_size or max(5, n // 60)
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


def load_concepts() -> list[str]:
    text = resources.files("topograph").joinpath("concepts.txt").read_text()
    return [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]


def concept_labels(backend, vecs, labels, concepts) -> dict[int, str]:
    if backend is None:
        return {}
    scores = backend.concept_scores(vecs, concepts)
    if scores is None:
        return {}
    baseline = scores.mean(0)
    clusters = sorted(set(labels) - {-1})
    # Score each concept by how much more it fits this region than the archive
    # as a whole, so generic concepts don't win everywhere.
    table = np.array([scores[labels == c].mean(0) - baseline for c in clusters])
    return {c: concepts[int(table[i].argmax())] for i, c in enumerate(clusters)}


def term_labels(texts: list[str | None], labels: np.ndarray, top: int = 5) -> dict[int, list[str]]:
    from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS, TfidfVectorizer
    clusters = sorted(set(labels) - {-1})
    docs = []
    for c in clusters:
        joined = " ".join(t for t, l in zip(texts, labels) if l == c and t)
        docs.append(re.sub(r"https?://\S+", " ", joined))
    if not any(d.strip() for d in docs):
        return {c: [] for c in clusters}
    vec = TfidfVectorizer(stop_words=list(ENGLISH_STOP_WORDS | STOP_EXTRA), max_df=0.6,
                          token_pattern=r"(?u)#?\b[a-zA-Z][a-zA-Z]{2,}\b", sublinear_tf=True)
    try:
        m = vec.fit_transform(docs)
    except ValueError:
        return {c: [] for c in clusters}
    vocab = np.array(vec.get_feature_names_out())
    out = {}
    for row, c in enumerate(clusters):
        r = m[row].toarray()[0]
        best = r.argsort()[::-1][:top]
        out[c] = [vocab[i] for i in best if r[i] > 0]
    return out


def compute_layout(lib, model: str, backend=None, log=print) -> int:
    ids, vecs = load_vectors(lib, model)
    if not ids:
        log("Nothing embedded yet; run `topograph embed` first.")
        return 0
    from .progress import step
    with step(f"Laying out {len(ids):,} items on the map"):
        xy = project(vecs)
    # Fit into a 1000x1000 square for the viewer, keeping the aspect ratio
    # (distances on the map mean something) with a margin for the terrain.
    lo, hi = xy.min(0), xy.max(0)
    span = max(float((hi - lo).max()), 1e-9)
    xy = (xy - (lo + hi) / 2) / span * 900 + 500
    with step("Finding regions"):
        labels = cluster(xy)
    with step("Finding nearest neighbors"):
        nbrs = neighbors(vecs) if len(ids) > 1 else np.zeros((len(ids), 0), int)

    texts = {r["id"]: r["text"] for r in lib.conn.execute("select id, text from item")}
    visual = {r[0] for r in lib.conn.execute("select distinct item_id from media where status='ok'")}
    with step("Naming regions"):
        terms = term_labels([texts.get(i) for i in ids], labels)
        names = concept_labels(backend, vecs, labels, load_concepts())

    clusters = sorted(set(labels) - {-1})
    final = {}
    for cl in clusters:
        members = [ids[k] for k in np.flatnonzero(labels == cl)]
        t = terms.get(cl, [])
        mostly_text = sum(m in visual for m in members) < len(members) / 2
        # Image concepts describe pictures; regions of words are named by their words.
        if names.get(cl) and not mostly_text:
            final[cl] = names[cl]
        else:
            final[cl] = ", ".join(t[:2]) if t else f"Region {cl + 1}"
    # Disambiguate repeated names with each region's most distinctive word.
    counts = {}
    for name in final.values():
        counts[name] = counts.get(name, 0) + 1
    for cl, name in final.items():
        if counts[name] > 1:
            extra = next((w for w in terms.get(cl, []) if w.lower() not in name.lower()), None)
            final[cl] = f"{name} ({extra})" if extra else name

    c = lib.conn
    c.execute("delete from layout where model=?", (model,))
    c.execute("delete from cluster where model=?", (model,))
    c.executemany(
        "insert into layout(item_id, model, x, y, cluster, neighbors) values (?,?,?,?,?,?)",
        [(iid, model, float(xy[k, 0]), float(xy[k, 1]), int(labels[k]),
          json.dumps([ids[j] for j in nbrs[k]])) for k, iid in enumerate(ids)])
    for cl in clusters:
        c.execute("insert into cluster(model, id, label, terms) values (?,?,?,?)",
                  (model, int(cl), final[cl], json.dumps(terms.get(cl, []))))
    c.commit()
    log(f"  {len(clusters)} regions: " + ", ".join(final[cl] for cl in clusters[:8]) +
        (", …" if len(clusters) > 8 else ""))
    return len(ids)
