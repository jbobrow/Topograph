"""Regions: nested areas of the map, and names for them.

The map is divided at several scales. The finest regions come from HDBSCAN on
the 2D layout; they are merged step by step (Ward linkage on their centers) into
larger ones, so every region sits inside one parent. The viewer shows the large
regions when you are zoomed out and swaps in their children as you zoom in.

Naming. Each region is named by the phrase that best tells it apart from its
siblings (the other regions under the same parent), using two kinds of evidence:

  pictures  how much more a phrase fits the region's items than its siblings'
            items in CLIP space, measured in standard deviations so common
            phrases don't win everywhere
  words     how much more often the phrase appears in the region's captions,
            file and folder names than in its siblings'

Candidate phrases are the vocabulary in concepts.txt plus words, phrases and
hashtags that recur in your own text, so a region can be called "glyphlet" or
"teenage engineering" when that is what it is. A name is used once on the map,
and a region is never named the same as the region around it. Words for how
things look ("purple", "pastel colors") qualify the region around them, so a
part of "orchids" can be "purple orchids".
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field

import numpy as np

# Words that make poor names on their own or at the ends of a phrase.
STOP = set("""
a about above after again against all almost also am among an and any are aren't around as at be because
been before being below between both but by can can't cannot could couldn't did didn't do does doesn't
doing don't down during each either else even ever every few for from further had hadn't has hasn't have
haven't having he he'd he'll he's her here here's hers herself him himself his how how's however i i'd
i'll i'm i've if in into is isn't it it's its itself just let's like made make makes many may me might more
most much must mustn't my myself never new no nor not now of off often on once one only or other ought our
ours ourselves out over own per quite rather really same say says she she'd she'll she's should shouldn't
since so some still such than that that's the their theirs them themselves then there there's these they
they'd they'll they're they've thing things this those though through thus to too under until up upon us
very via was wasn't we we'd we'll we're we've well were weren't what what's when when's where where's
whether which while who who's whom whose why why's will with within without won't would wouldn't yet you
you'd you'll you're you've your yours yourself yourselves
amp rt http https www com org net html htm jpg jpeg png gif heic pdf mov mp4 psd ai svg tif tiff webp
img image images photo photos pic pics picture screenshot screen shot copy final draft untitled new old
file files folder version v1 v2 v3 edit edited export exported
im ive dont didnt cant wont thats youre theyre lol lmao omg wow yes yeah ok okay oh hey hi hello thanks
thank please today tonight tomorrow yesterday day days week weeks year years time times ago soon back
got get gets getting go goes going gone went come comes coming came see seen saw look looks looking
want wants need needs know think thought feel love loved loves good great nice best better cool awesome
amazing beautiful pretty fun happy little big lot lots way ways something anything everything nothing
someone anyone everyone people person guy guys thing stuff kind sort first last next right left
wearing wears wear worn sitting sits sit standing stands stand holding holds hold shown showing shows
front background foreground side top bottom near behind together large small two three four five
several various another others different part full whole half update updates added adding arrived
""".split())

TEMPLATES = ("a photo of {}.", "an image of {}.", "{}")
MAX_PHRASES = 6000
# Words vs pictures, by depth: broad regions lean on what things look like and
# are about, small ones on the specific words (names, projects) found in them.
TEXT_WEIGHT = {0: 0.6, 1: 1.0}
WEAK = 0.5          # a larger region's name must fit it this much better (std devs)
SHRINK = 25.0
# Parents that are a way of making things rather than things: "purple" isn't
# turned into "purple macro photography".
MEDIUMS = {"photography", "art", "design", "painting", "drawings", "drawing", "illustration",
           "prints", "printing", "sketches", "graphics", "renders", "styles"}       # picture evidence from a region of n items is scaled by n / (n + SHRINK)


@dataclass
class Region:
    id: int
    members: np.ndarray
    children: list[int] = field(default_factory=list)
    parent: int | None = None
    depth: int = 0
    label: str = ""
    terms: list[str] = field(default_factory=list)
    score: float = 0.0


# --- the tree ------------------------------------------------------------------

def build_tree(xy: np.ndarray, leaf: np.ndarray, top: int = 7, branching: float = 3.0):
    """Nest the finest regions (`leaf` labels per item, -1 for none) into larger ones.

    Returns ({id: Region}, [root ids]). Leaf ids are the leaf labels; merged
    regions get new ids above them.
    """
    leaves = sorted(int(v) for v in set(leaf.tolist()) - {-1})
    regions = {l: Region(l, np.flatnonzero(leaf == l)) for l in leaves}
    roots = list(leaves)
    if len(leaves) > top + 2:
        from scipy.cluster.hierarchy import fcluster, linkage
        centers = np.array([xy[regions[l].members].mean(0) for l in leaves])
        tree = linkage(centers, "ward")
        targets, t = [], float(top)
        while t * 1.8 < len(leaves):
            targets.append(int(round(t)))
            t *= branching
        current = {l: l for l in leaves}       # leaf -> region standing for it at this scale
        next_id = max(leaves) + 1
        for target in reversed(targets):       # finest merge first
            groups = fcluster(tree, target, "maxclust")
            merged = {}
            for g in np.unique(groups):
                ls = [leaves[i] for i in np.flatnonzero(groups == g)]
                kids = sorted({current[l] for l in ls})
                if len(kids) == 1:
                    rid = kids[0]
                else:
                    rid = next_id
                    next_id += 1
                    regions[rid] = Region(rid, np.concatenate([regions[k].members for k in kids]), kids)
                    for k in kids:
                        regions[k].parent = rid
                for l in ls:
                    merged[l] = rid
            current = merged
        roots = sorted(set(current.values()))

    def set_depth(rid, d):
        regions[rid].depth = d
        for k in regions[rid].children:
            set_depth(k, d + 1)
    for r in roots:
        set_depth(r, 0)
    return regions, roots


def anchor(xy: np.ndarray, members: np.ndarray) -> tuple[float, float, float]:
    """Where to put a region's label (the member nearest its median) and its size."""
    pts = xy[members]
    med = np.median(pts, 0)
    i = int(((pts - med) ** 2).sum(1).argmin())
    ax, ay = pts[i]
    r = float(np.sqrt(((pts - pts.mean(0)) ** 2).sum(1).mean())) if len(pts) > 1 else 4.0
    return float(ax), float(ay), max(r, 4.0)


# --- words ---------------------------------------------------------------------

URL = re.compile(r"https?://\S+|www\.\S+")
MENTION = re.compile(r"(?<!\w)@\w+")
CAMEL = re.compile(r"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")
TOKEN = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")


def tokens(text: str | None) -> list[str]:
    if not text:
        return []
    text = URL.sub(" ", text)
    text = MENTION.sub(" ", text)
    text = re.sub(r"#(\w+)", lambda m: " " + CAMEL.sub(" ", m.group(1)) + " ", text)
    text = CAMEL.sub(" ", text) if text.count(" ") < 2 else text   # file names like GlyphletSketch
    out = []
    for t in TOKEN.findall(text.lower().replace("_", " ")):
        if t.endswith("'s"):
            t = t[:-2]
        if len(t) >= 2:
            out.append(t)
    return out


def _ok_word(w: str) -> bool:
    return w not in STOP and not w.isdigit() and len(w) >= 2


def ngrams(toks: list[str], n_max: int = 3) -> set[str]:
    """Phrases of 1–3 words that don't start or end on a filler word."""
    out = set()
    for n in range(1, n_max + 1):
        for i in range(len(toks) - n + 1):
            g = toks[i:i + n]
            if not (_ok_word(g[0]) and _ok_word(g[-1])):
                continue
            if any(w.isdigit() and len(w) != 4 for w in g) or (n == 1 and len(g[0]) < 3):
                continue
            out.add(" ".join(g))
    return out


def key(phrase: str) -> str:
    """Compare names loosely: case, punctuation and plurals don't make a name new."""
    words = TOKEN.findall(phrase.lower().replace("-", " "))
    return " ".join(w[:-1] if len(w) > 3 and w.endswith("s") and not w.endswith("ss") else w for w in words)


def vocabulary(docs: list[set[str]], concepts: list[str]) -> tuple[list[str], list[str], int]:
    """Candidate names: the concept list plus phrases that recur in your own text.

    Returns (match keys, display names, how many came from the concept list):
    keys are what we look for in text, names what the map shows.
    """
    n_text = sum(1 for d in docs if d)
    df = Counter()
    for d in docs:
        df.update(d)
    min_df = max(3, int(n_text * 0.0004))
    max_df = max(min_df + 1, int(n_text * 0.12))
    found = {g: c for g, c in df.items() if min_df <= c <= max_df}
    # A word that almost only appears inside a longer phrase ("york" in "new york")
    # is better left to the phrase.
    drop = set()
    for g, c in found.items():
        parts = g.split()
        if len(parts) > 1:
            for n in range(1, len(parts)):
                for i in range(len(parts) - n + 1):
                    sub = " ".join(parts[i:i + n])
                    if sub in found and found[sub] <= c * 1.25:
                        drop.add(sub)
    found = {g: c for g, c in found.items() if g not in drop}
    data = [g for g, _ in sorted(found.items(), key=lambda kv: -kv[1])[:MAX_PHRASES]]

    keys, names, seen = [], [], set()
    for c in concepts:
        k = " ".join(tokens(c))
        if k and k not in seen:
            seen.add(k)
            keys.append(k)
            names.append(c)
    n_concepts = len(keys)
    for g in data:
        if g not in seen:
            seen.add(g)
            keys.append(g)
            names.append(g)
    return keys, names, n_concepts


# --- names ---------------------------------------------------------------------

def name_tree(regions: dict[int, Region], roots: list[int], vecs: np.ndarray,
              texts: list[str | None], has_image: np.ndarray, concepts: list[str],
              embed_phrases=None, explain: dict | None = None,
              modifiers: frozenset[str] = frozenset()) -> None:
    """Fill in `label` and `terms` on every region (see the module docstring)."""
    from scipy import sparse

    n = len(texts)
    docs = [ngrams(tokens(t)) for t in texts]
    keys, names, n_concepts = vocabulary(docs, concepts)
    if not keys:
        for r in regions.values():
            r.label = f"region {r.id + 1}"
        return
    col = {k: j for j, k in enumerate(keys)}
    rows, cols = [], []
    for i, d in enumerate(docs):
        for g in d:
            j = col.get(g)
            if j is not None:
                rows.append(i)
                cols.append(j)
    X = sparse.csr_matrix((np.ones(len(rows), np.float32), (rows, cols)), shape=(n, len(keys)))

    ids = list(regions)
    pos = {rid: i for i, rid in enumerate(ids)}
    mr, mc = [], []
    for rid in ids:
        m = regions[rid].members
        mr.extend([pos[rid]] * len(m))
        mc.extend(m.tolist())
    M = sparse.csr_matrix((np.ones(len(mr), np.float32), (mr, mc)), shape=(len(ids), n))
    size = np.asarray(M.sum(1)).ravel()
    df = np.asarray((M @ X).todense())                 # regions x phrases: items mentioning it

    # The whole map stands as the parent of the top-level regions.
    in_any = np.zeros(n, bool)
    for r in roots:
        in_any[regions[r].members] = True
    all_df = np.asarray(X[in_any].sum(0)).ravel()
    all_size = float(in_any.sum())

    # Pictures: standardized difference in CLIP similarity.
    vis_mean = None
    T = embed_phrases(names) if embed_phrases is not None else None
    if T is not None and len(vecs):
        V = vecs.astype(np.float32).copy()
        # Pictures and text sit in different parts of CLIP space; center each so a
        # region isn't "about" a phrase just because it holds more of one kind.
        for mask in (has_image, ~has_image):
            if mask.any():
                V[mask] -= V[mask].mean(0)
        cov = np.cov(V[in_any].T) if in_any.sum() > 2 else np.eye(V.shape[1])
        sigma = np.sqrt(np.maximum(np.einsum("vd,de,ve->v", T, cov, T), 1e-8))
        sums = np.asarray(M @ V)                           # regions x dim
        vis_sum = sums @ T.T / sigma                       # regions x phrases (sum over members)
        vis_all = V[in_any].sum(0) @ T.T / sigma
        vis_mean = vis_sum / np.maximum(size, 1)[:, None]
        # The same, counting only items with pictures. Phrases lifted from your own
        # text are judged on pictures alone: on text items CLIP would mostly be
        # finding the phrase in the text, which the word count already measures.
        Vi = np.where(has_image[:, None], V, 0)
        img_size = np.asarray(M @ has_image.astype(np.float32)).ravel()
        img_sum = np.asarray(M @ Vi) @ T.T / sigma
        img_all = Vi[in_any].sum(0) @ T.T / sigma
        img_all_size = float(has_image[in_any].sum())
        img_mean = img_sum / np.maximum(img_size, 1)[:, None]

    words = np.array([len(k.split()) for k in keys])
    from_concepts = np.zeros(len(keys), bool)
    from_concepts[:n_concepts] = True
    shape_bonus = 0.04 * (np.minimum(words, 3) - 1) + np.where(from_concepts, 0.2, 0.0)
    too_long = np.array([len(nm) > 30 for nm in names])

    def scores(rid):
        r = regions[rid]
        i = pos[rid]
        if r.parent is None:
            p_df, p_size = all_df, all_size
            if vis_mean is not None:
                p_vis, p_img, p_img_size = vis_all, img_all, img_all_size
        else:
            j = pos[r.parent]
            p_df, p_size = df[j], size[j]
            if vis_mean is not None:
                p_vis, p_img, p_img_size = vis_sum[j], img_sum[j], img_size[j]
        rest = max(p_size - size[i], 1.0)
        f_in = df[i] / max(size[i], 1.0)
        f_out = np.maximum(p_df - df[i], 0) / rest
        v_in = vis_mean[i] if vis_mean is not None else None
        g_in = img_mean[i] if vis_mean is not None else None
        if r.children:
            # A larger region's name should fit all of it, not just its biggest
            # part: judge it by its sub-regions, discounting uneven fit.
            kids = [pos[k] for k in r.children]
            w = size[kids] / size[kids].sum()
            fk = df[kids] / np.maximum(size[kids], 1.0)[:, None]
            f_in = np.minimum(f_in, _soft_min(fk, w))
            if v_in is not None:
                v_in = _soft_min(vis_mean[kids], w)
                gw = img_size[kids] / max(img_size[kids].sum(), 1.0)
                g_in = _soft_min(img_mean[kids], gw)
        raw_in = df[i] / max(size[i], 1.0)
        h = 2 * np.arcsin(np.sqrt(np.clip(f_in, 0, 1))) - 2 * np.arcsin(np.sqrt(np.clip(f_out, 0, 1)))
        enough = df[i] >= max(2.0, 0.02 * size[i])
        text = np.where(enough, np.maximum(h, 0), 0.0)
        vis = np.zeros(len(keys))
        if vis_mean is not None:
            out_mean = (p_vis - vis_sum[i]) / rest
            # Small regions' averages are noisy (a handful of near-duplicates fits
            # many phrases "well"), so their picture evidence is shrunk.
            shrink = size[i] / (size[i] + SHRINK)
            vis = (0.65 * (v_in - out_mean) + 0.35 * v_in) * shrink
            if img_size[i] >= 5:
                g_out = (p_img - img_sum[i]) / max(p_img_size - img_size[i], 1.0)
                pics = (0.65 * (g_in - g_out) + 0.35 * g_in) * (img_size[i] / (img_size[i] + SHRINK))
                pics = pics * min(1.0, img_size[i] / size[i] * 1.5)
            else:
                pics = np.zeros(len(keys))
            vis = np.where(from_concepts, vis, pics)
        raw = vis
        s = TEXT_WEIGHT.get(r.depth, 1.4) * text + vis + shape_bonus
        # Your own words only name a region they actually turn up in.
        s[~from_concepts & ~(enough & (raw_in > f_out))] = -np.inf
        s[too_long] = -np.inf
        if explain is not None:
            top = np.argsort(-s)[:8]
            explain[rid] = [(names[j], round(float(s[j]), 2), round(float(text[j]), 2), round(float(vis[j]), 2)) for j in top]
        return s, text, raw

    used: set[str] = set()
    by_depth: dict[int, list[int]] = {}
    for rid, r in regions.items():
        by_depth.setdefault(r.depth, []).append(rid)

    def ancestors(rid):
        out, p = [], regions[rid].parent
        while p is not None:
            out.append(regions[p].label)
            p = regions[p].parent
        return out

    def clashes(name, rid):
        k = key(name)
        if k in used:
            return True
        for a in ancestors(rid):
            ak = key(a)
            if not ak:
                continue
            if k == ak or f" {ak} " in f" {k} " or f" {k} " in f" {ak} ":
                return True
        return False

    def qualify(name, r):
        """A look ("purple", "pastel colors") under a thing ("orchids") reads "purple orchids"."""
        if name not in modifiers or r.parent is None:
            return name
        parent = regions[r.parent].label
        if (not parent or parent in modifiers or "+" in parent or len(parent.split()) > 2
                or set(parent.split()) & MEDIUMS):
            return name
        word = name[: -len(" colors")] if name.endswith(" colors") else name
        return f"{word} {parent}"

    for depth in sorted(by_depth):
        level = sorted(by_depth[depth], key=lambda rid: -len(regions[rid].members))
        options, text_scores, fit = [], {}, {}
        for rid in level:
            s, t, raw = scores(rid)
            text_scores[rid] = t
            fit[rid] = (raw, t)
            top = np.argsort(-s)[:80]
            options.extend((float(s[j]), rid, int(j)) for j in top if np.isfinite(s[j]))
        options.sort(key=lambda o: -o[0])
        done = set()
        for sc, rid, j in options:
            if rid in done:
                continue
            name = qualify(names[j], regions[rid])
            if key(name) in used or (name == names[j] and clashes(name, rid)):
                continue
            if regions[rid].children and fit[rid][0][j] < WEAK and fit[rid][1][j] < 0.8:
                continue        # nothing in common enough: named after its parts below
            regions[rid].label, regions[rid].score = name, sc
            used.add(key(name))
            done.add(rid)
        for rid in level:
            r = regions[rid]
            if rid not in done:
                r.label, r.score = ("" if r.children else f"region {rid + 1}"), -1.0
            t = text_scores[rid]
            order = np.argsort(-t)[:12]
            lk = key(r.label)
            r.terms = [names[j] for j in order if t[j] > 0 and key(names[j]) != lk][:6]

    # A large region with nothing in common to name it by is called after its
    # two largest parts.
    for rid in sorted(regions, key=lambda rid: -regions[rid].depth):
        r = regions[rid]
        if r.children and not r.label:
            kids = sorted(r.children, key=lambda k: -len(regions[k].members))[:2]
            r.label = " + ".join(regions[k].label for k in kids)


def _soft_min(values: np.ndarray, w: np.ndarray) -> np.ndarray:
    """Weighted mean minus the spread, per column."""
    mean = (w[:, None] * values).sum(0)
    spread = np.sqrt((w[:, None] * (values - mean) ** 2).sum(0))
    return mean - spread


def outline(regions: dict[int, Region], roots: list[int], max_depth: int = 9) -> str:
    """The region tree as indented text (for `topograph regions`)."""
    lines = []

    def walk(rid, d):
        r = regions[rid]
        extra = f"   ({', '.join(r.terms[:3])})" if r.terms else ""
        lines.append(f"{'  ' * d}{r.label}  {len(r.members):,}{extra}")
        if d < max_depth:
            for k in sorted(r.children, key=lambda k: -len(regions[k].members)):
                walk(k, d + 1)
    for r in sorted(roots, key=lambda k: -len(regions[k].members)):
        walk(r, 0)
    return "\n".join(lines)
