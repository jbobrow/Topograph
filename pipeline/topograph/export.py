"""Export the library to the JSON the viewer reads, and serve the viewer."""

from __future__ import annotations

import functools
import http.server
import json
import socketserver
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

from .config import INTERACTION_WEIGHTS

VIEWER_DIR = Path(__file__).resolve().parents[2] / "viewer"


def _month(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m")


def export(lib, model: str) -> Path:
    c = lib.conn
    items = {r["id"]: dict(r) for r in c.execute("select * from item")}
    ixs = defaultdict(list)
    for r in c.execute("select * from interaction order by at"):
        ixs[r["item_id"]].append(r)
    media = defaultdict(list)
    for r in c.execute("select * from media where status='ok' order by ord"):
        media[r["item_id"]].append(r)
    layout = c.execute("select * from layout where model=?", (model,)).fetchall()
    clusters = {r["id"]: r for r in c.execute("select * from cluster where model=?", (model,))}

    def taste_time(iid):
        real = [r["at"] for r in ixs[iid] if r["at"] and not r["at_estimated"]]
        if real:
            return min(real)
        est = [r["at"] for r in ixs[iid] if r["at"]]
        return min(est) if est else items[iid]["created_at"]

    def resonance(iid):
        return round(sum(INTERACTION_WEIGHTS.get(t, 1.0) for t in {r["type"] for r in ixs[iid]}), 2)

    index = {row["item_id"]: k for k, row in enumerate(layout)}
    out_items = []
    sizes = Counter()
    for row in layout:
        iid = row["item_id"]
        it = items[iid]
        ms = media[iid]
        pal = json.loads(ms[0]["palette"]) if ms and ms[0]["palette"] else []
        sizes[row["cluster"]] += 1
        out_items.append({
            "id": iid,
            "x": round(row["x"], 2), "y": round(row["y"], 2), "c": row["cluster"],
            "p": it["platform"], "k": it["kind"],
            "a": it["author"], "t": (it["text"] or "")[:600] or None, "u": it["url"],
            "th": ms[0]["thumb_path"] if ms else None,
            "im": [m["local_path"] for m in ms],
            "wh": [ms[0]["width"], ms[0]["height"]] if ms else None,
            "ts": it["created_at"], "at": taste_time(iid),
            "ix": [[r["type"], r["at"], r["at_estimated"], r["collection"]] for r in ixs[iid]],
            "r": resonance(iid),
            "col": pal[0][0] if pal else None,
            "pal": pal,
            "nb": [index[n] for n in json.loads(row["neighbors"] or "[]") if n in index],
        })

    # Items that could not be placed (bare links that never hydrated) still
    # count toward Strata, as an "unmapped" layer.
    placed = set(index)
    unmapped = Counter()
    for iid in items:
        if iid not in placed:
            t = taste_time(iid)
            if t:
                unmapped[_month(t)] += 1

    out = {
        "meta": {
            "generated": int(time.time()), "model": model,
            "items": len(items), "placed": len(out_items),
            "platforms": dict(Counter(i["platform"] for i in items.values())),
            "interactions": dict(Counter(r["type"] for v in ixs.values() for r in v)),
            "weights": INTERACTION_WEIGHTS,
        },
        "clusters": [{"id": cid, "label": r["label"], "terms": json.loads(r["terms"] or "[]"),
                      "n": sizes[cid]} for cid, r in sorted(clusters.items())],
        "items": out_items,
        "unmapped": dict(sorted(unmapped.items())),
    }
    path = lib.root / "topograph.json"
    path.write_text(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
    return path


class _Handler(http.server.SimpleHTTPRequestHandler):
    """Serves the viewer at / and the library's media + JSON under /library/."""

    def __init__(self, *args, library: Path, **kwargs):
        self.library = library
        super().__init__(*args, directory=str(VIEWER_DIR), **kwargs)

    def translate_path(self, path):
        clean = path.split("?", 1)[0].split("#", 1)[0]
        if clean.startswith("/library/"):
            rel = clean[len("/library/"):]
            target = (self.library / rel).resolve()
            allowed = (self.library / "media").resolve()
            if target == (self.library / "topograph.json").resolve() or allowed in target.parents:
                return str(target)
            return str(self.library / "__forbidden__")
        return super().translate_path(path)

    def end_headers(self):
        if self.path.startswith("/library/media/"):
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        super().end_headers()

    def log_message(self, *args):
        pass


def serve(library: Path, port: int = 8732, open_browser: bool = True):
    handler = functools.partial(_Handler, library=Path(library))
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", port), handler) as httpd:
        url = f"http://127.0.0.1:{port}/"
        print(f"Topograph is open at {url}  (Ctrl-C to stop)")
        if open_browser:
            import webbrowser
            webbrowser.open(url)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
