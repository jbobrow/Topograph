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
            "src": ms[0]["original_url"] if ms and it["platform"] == "files" else None,
            "col": pal[0][0] if pal else None,
            "pal": pal,
            "nb": [index[n] for n in json.loads(row["neighbors"] or "[]") if n in index],
        })

    # Items that could not be placed yet (links still waiting for their images)
    # count toward Strata, as an "unmapped" layer. Posts that are gone don't.
    from .db import GONE_SQL
    gone = {r[0] for r in c.execute(f"select id from item where {GONE_SQL}")}
    # Searches float over the map as clouds: where, when, and what you asked.
    clouds = [{"x": round(r["x"], 2), "y": round(r["y"], 2), "c": r["region"], "at": taste_time(r["item_id"]),
               "t": (items[r["item_id"]]["text"] or "")[:200] or None}
              for r in c.execute("select * from cloud where model=?", (model,)) if r["item_id"] not in gone]
    placed = set(index) | {r[0] for r in c.execute("select item_id from cloud where model=?", (model,))}
    unmapped = Counter()
    for iid in items:
        if iid not in placed and iid not in gone:
            t = taste_time(iid)
            if t:
                unmapped[_month(t)] += 1

    out = {
        "meta": {
            "generated": int(time.time()), "model": model,
            "items": len(items) - len(gone), "placed": len(out_items), "gone": len(gone),
            "platforms": dict(Counter(i["platform"] for k, i in items.items() if k not in gone)),
            "interactions": dict(Counter(r["type"] for v in ixs.values() for r in v)),
            "weights": INTERACTION_WEIGHTS,
        },
        "clusters": region_list(clusters, sizes),
        "items": out_items,
        "clouds": clouds,
        "unmapped": dict(sorted(unmapped.items())),
    }
    path = lib.root / "topograph.json"
    path.write_text(json.dumps(out, separators=(",", ":"), ensure_ascii=False))
    return path


def region_list(clusters, sizes) -> list[dict]:
    """Regions with their place in the tree; `n` counts everything inside."""
    total = Counter()
    for cid, n in sizes.items():
        p = cid
        while p is not None and p in clusters:
            total[p] += n
            p = clusters[p]["parent"]
    out = []
    for cid, r in sorted(clusters.items()):
        out.append({"id": cid, "label": r["label"], "terms": json.loads(r["terms"] or "[]"),
                    "n": total[cid], "parent": r["parent"], "depth": r["depth"] or 0,
                    "x": round(r["x"], 1) if r["x"] is not None else None,
                    "y": round(r["y"], 1) if r["y"] is not None else None,
                    "r": round(r["r"], 1) if r["r"] is not None else None})
    return out


class _Handler(http.server.SimpleHTTPRequestHandler):
    """Serves the viewer at / and the library's media + JSON under /library/."""

    def __init__(self, *args, library: Path, **kwargs):
        self.library = library
        super().__init__(*args, directory=str(VIEWER_DIR), **kwargs)

    def do_GET(self):
        if self.path.startswith("/api/reveal"):
            return self._reveal()
        return super().do_GET()

    def _reveal(self):
        """Show a local file in Finder. Only for files that are items in the library."""
        import sqlite3
        import subprocess
        import sys
        from urllib.parse import parse_qs, unquote, urlparse
        item_id = (parse_qs(urlparse(self.path).query).get("id") or [""])[0]
        conn = sqlite3.connect(self.library / "topograph.sqlite")
        row = conn.execute("select url from item where id=? and platform='files'", (item_id,)).fetchone()
        conn.close()
        path = unquote(row[0][len("file://"):]) if row and row[0] and row[0].startswith("file://") else None
        if not path or not Path(path).exists():
            self.send_error(404, "File not found")
            return
        if sys.platform == "darwin":
            subprocess.run(["open", "-R", path], check=False)
        self.send_response(204)
        self.end_headers()

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
