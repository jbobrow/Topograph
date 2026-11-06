"""topograph — command line for the prototype pipeline.

    topograph import ~/Downloads/instagram-*.zip
    topograph import ~/Downloads/twitter-2026-11-05-*.zip
    topograph hydrate            # fetch media for likes/saves (slow, polite, resumable)
    topograph build              # embed + layout + export
    topograph serve              # open the viewer
    topograph regions            # list the map's regions and their names
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import media as media_mod
from .config import default_library
from .db import Library, upsert_record
from .importers import IMPORTERS, detect
from .progress import Progress, step
from .util import Archive


def _short(path, root=None) -> str:
    """A folder name short enough for the progress line."""
    path = Path(path)
    try:
        if root:
            path = path.relative_to(root)
    except ValueError:
        pass
    parts = path.parts
    return "/".join(parts[-3:]) if len(parts) > 3 else str(path)


def cmd_import(args, lib):
    archive = Archive(args.paths)
    kinds = [args.platform] if args.platform else detect(archive)
    if not kinds:
        sys.exit("Couldn't recognize this export. Use --platform x|instagram to force it.")
    names = {"x": "X", "instagram": "Instagram", "facebook": "Facebook"}
    for kind in kinds:
        new = 0
        with Progress(f"Importing {names.get(kind, kind)}", unit="records") as prog:
            for rec in IMPORTERS[kind].parse(archive):
                new += upsert_record(lib, rec, media_mod.ingest)
                prog.advance(note=f"{new:,} new" + (", copying images" if rec.media else ""))
                if prog.done % 500 == 0:
                    lib.conn.commit()
            lib.conn.commit()
            prog.close(f"{prog.done:,} records, {new:,} new items")
    _stats(lib)


def cmd_files(args, lib):
    import json
    from .importers.files import Options, Report, collect, format_report, parse
    from .media import preview_from_path
    roots = [str(Path(r).expanduser()) for r in args.paths] or json.loads(lib.get_meta("files_roots", "[]"))
    if not roots:
        sys.exit("Name the folders to read, e.g. topograph files ~/Desktop ~/Downloads")
    excludes = sorted(set(json.loads(lib.get_meta("files_excludes", "[]")) +
                          [str(Path(e).expanduser()) for e in args.exclude]))
    opts = Options(include_code=args.include_code, include_pdf=args.include_pdf,
                   include_cloud_only=args.include_cloud_only, exclude=excludes)
    report = Report()
    label = "Looking through your folders" + (" (dry run)" if args.dry_run else "")
    with Progress(label, unit="files checked") as prog:
        def checked():
            return sum(report.kept.values()) + sum(report.skipped.values())

        def on_folder(path):
            prog.advance(checked() - prog.done, note=_short(path))
        candidates = collect(roots, opts, report, on_folder)
        prog.advance(checked() - prog.done, note="")
        prog.close(f"{prog.done:,} files checked, {len(candidates):,} to keep")
    if args.dry_run:
        print(format_report(report))
        return
    lib.set_meta("files_roots", json.dumps(roots))
    lib.set_meta("files_excludes", json.dumps(excludes))
    new = 0
    done_ids = {r[0] for r in lib.conn.execute(
        "select i.id from item i join media m on m.item_id = i.id "
        "where i.platform = 'files' and m.status = 'ok'")}
    with Progress("Making previews", total=len(candidates), unit="files") as prog:
        def skipped(path):
            prog.advance(note=_short(path.parent))
        for rec in parse(candidates, report, preview_from_path, done_ids, on_skip=skipped):
            new += upsert_record(lib, rec, media_mod.ingest)
            src = rec.interactions[0].get("source") or ""
            prog.advance(note=_short(Path(src).parent) if src else None)
            if prog.done % 250 == 0:
                lib.conn.commit()
        lib.conn.commit()
        prog.close(f"{prog.done:,} files, {new:,} new")
    print()
    print(format_report(report))
    _stats(lib)


def cmd_hydrate(args, lib):
    from .hydrate import download_pending_media, hydrate
    print("Fetching images for liked and saved posts. Ctrl-C pauses; run again to resume.")
    try:
        with Progress("Downloading waiting images", unit="images") as prog:
            pre = download_pending_media(lib, delay=args.delay / 3, progress=prog)
        with Progress("Fetching liked and saved posts", unit="posts") as prog:
            s = hydrate(lib, limit=args.limit, delay=args.delay,
                        platforms=[args.platform] if args.platform else None, progress=prog)
            prog.close(f"{s['hydrated']:,} fetched, {s['unreachable']:,} unreachable, "
                       f"{s['media'] + pre:,} images")
    except KeyboardInterrupt:
        lib.conn.commit()
        print("Paused. Run `topograph hydrate` again to pick up where you left off.")
    _stats(lib)


def _backend(args):
    from .embed import auto_backend, get_backend
    name = args.backend or auto_backend()
    if name == "lite":
        print("Using the lite embedder (install the 'clip' extra for much better maps).")
        return get_backend(name)
    import logging
    import os
    import warnings
    logging.getLogger("huggingface_hub").setLevel(logging.ERROR)
    warnings.filterwarnings("ignore", module="huggingface_hub")
    from .embed import clip_is_cached
    if clip_is_cached():
        os.environ.setdefault("HF_HUB_OFFLINE", "1")   # no network, no warnings
        with step("Loading the image model (CLIP)"):
            return get_backend(name)
    print("Downloading the image model (CLIP, about 600 MB, first run only)")
    return get_backend(name)


def cmd_embed(args, lib):
    from .embed import embed_library
    embed_library(lib, _backend(args), force=args.force)


def cmd_layout(args, lib, backend=None):
    from .layout import compute_layout
    model = lib.get_meta("embedding_model")
    if not model:
        sys.exit("Nothing embedded yet; run `topograph embed` first.")
    if backend is None and model.startswith("clip"):
        backend = _backend(args)
    compute_layout(lib, model, backend=backend)


def cmd_export(args, lib):
    from .export import export
    model = lib.get_meta("embedding_model")
    with step("Writing the map for the viewer"):
        path = export(lib, model)
    print(f"Wrote {path}")


def cmd_build(args, lib):
    from .embed import embed_library
    from .export import export
    from .layout import compute_layout
    backend = _backend(args)
    embed_library(lib, backend, force=args.force)
    compute_layout(lib, backend.name, backend=backend)
    with step("Writing the map for the viewer"):
        path = export(lib, backend.name)
    print(f"Done. Open it with `topograph serve`. ({path})")


def cmd_serve(args, lib):
    from .export import serve
    if not (lib.root / "topograph.json").exists():
        sys.exit("Run `topograph build` first.")
    lib.close()
    serve(lib.root, port=args.port, open_browser=not args.no_open)


def _stats(lib):
    c = lib.conn
    print("\nLibrary:", lib.root)
    for r in c.execute("select platform, count(*) n, sum(hydrated=1) h, sum(hydrated=-1) u "
                       "from item group by platform"):
        print(f"  {r['platform']:10} {r['n']:6} items   {r['h'] or 0} with content, "
              f"{r['u'] or 0} unreachable")
    ix = ", ".join(f"{r['type']} {r['n']}" for r in
                   c.execute("select type, count(*) n from interaction group by type order by n desc"))
    print(f"  interactions: {ix}")
    m = c.execute("select count(*) from media where status='ok'").fetchone()[0]
    p = c.execute("select count(*) from media where status='pending'").fetchone()[0]
    print(f"  media: {m} cached, {p} waiting to download")


def cmd_regions(args, lib):
    import json as _json

    import numpy as np

    from .regions import Region, outline
    model = lib.get_meta("embedding_model")
    rows = lib.conn.execute("select * from cluster where model=?", (model,)).fetchall()
    if not rows:
        sys.exit("No regions yet; run `topograph build` first.")
    counts = dict(lib.conn.execute("select cluster, count(*) from layout where model=? group by cluster", (model,)).fetchall())
    regions = {r["id"]: Region(r["id"], np.zeros(0, int), parent=r["parent"], depth=r["depth"] or 0,
                               label=r["label"], terms=_json.loads(r["terms"] or "[]")) for r in rows}
    sizes = {rid: counts.get(rid, 0) for rid in regions}
    for rid, r in regions.items():
        if r.parent in regions:
            regions[r.parent].children.append(rid)
    def total(rid):
        return sizes[rid] + sum(total(k) for k in regions[rid].children)
    for rid, r in regions.items():
        r.members = np.zeros(total(rid), int)      # outline only needs the counts
    roots = [rid for rid, r in regions.items() if r.parent is None]
    print(outline(regions, roots, max_depth=args.depth))


def cmd_stats(args, lib):
    _stats(lib)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="topograph", description="A private atlas of your online taste.")
    ap.add_argument("--library", type=Path, default=None,
                    help=f"library folder (default: {default_library()})")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("import", help="import export ZIPs or folders")
    p.add_argument("paths", nargs="+")
    p.add_argument("--platform", choices=sorted(IMPORTERS))
    p.set_defaults(fn=cmd_import)

    p = sub.add_parser("files", help="read screenshots, downloads and working files from folders")
    p.add_argument("paths", nargs="*", help="folders (default: the ones used last time)")
    p.add_argument("--dry-run", action="store_true", help="report what would be imported")
    p.add_argument("--exclude", action="append", default=[], metavar="FOLDER",
                   help="leave a folder out (remembered for next time)")
    p.add_argument("--include-code", action="store_true", help="include images inside code projects")
    p.add_argument("--include-pdf", action="store_true")
    p.add_argument("--include-cloud-only", action="store_true",
                   help="also read files that are only in the cloud (downloads them)")
    p.set_defaults(fn=cmd_files)

    p = sub.add_parser("hydrate", help="fetch media and text for liked/saved links")
    p.add_argument("--limit", type=int)
    p.add_argument("--delay", type=float, default=1.5, help="seconds between requests")
    p.add_argument("--platform", choices=sorted(IMPORTERS))
    p.set_defaults(fn=cmd_hydrate)

    for name, fn, help_ in (("embed", cmd_embed, "compute embeddings"),
                            ("layout", cmd_layout, "map and cluster"),
                            ("export", cmd_export, "write viewer data"),
                            ("build", cmd_build, "embed + layout + export")):
        p = sub.add_parser(name, help=help_)
        p.add_argument("--backend", choices=["clip", "lite"])
        p.add_argument("--force", action="store_true", help="recompute embeddings")
        p.set_defaults(fn=fn)

    p = sub.add_parser("serve", help="open the viewer")
    p.add_argument("--port", type=int, default=8732)
    p.add_argument("--no-open", action="store_true")
    p.set_defaults(fn=cmd_serve)

    p = sub.add_parser("regions", help="list the map's regions and their names")
    p.add_argument("--depth", type=int, default=9, help="how many levels to show")
    p.set_defaults(fn=cmd_regions)

    sub.add_parser("stats", help="summarize the library").set_defaults(fn=cmd_stats)

    args = ap.parse_args(argv)
    lib = Library(args.library or default_library())
    try:
        args.fn(args, lib)
    finally:
        try:
            lib.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
