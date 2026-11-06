"""topograph — command line for the prototype pipeline.

    topograph import ~/Downloads/instagram-*.zip
    topograph import ~/Downloads/twitter-2026-11-05-*.zip
    topograph hydrate            # fetch media for likes/saves (slow, polite, resumable)
    topograph build              # embed + layout + export
    topograph build --map words  # build another way of arranging the same items
    topograph serve              # open the viewer
    topograph regions            # list the map's regions and their names
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

from . import media as media_mod
from .config import default_library
from .db import Library, upsert_record
from .importers import IMPORTERS, detect
from .maps import MAPS
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
    names = {"x": "X", "instagram": "Instagram", "facebook": "Facebook", "youtube": "YouTube", "google": "Google searches"}
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


def _chosen_map(args, lib, base: str) -> str:
    """The map to build: the one you asked for, then the one you built last. A library mapped
    before there was a choice keeps its map until you pick another. A new one gets the suggested
    one, if this machine can make it."""
    from .embed import words_is_installed
    from .maps import DEFAULT_MAP
    asked = getattr(args, "map", None) or lib.get_meta("map")
    if not asked:
        mapped = lib.conn.execute("select 1 from layout limit 1").fetchone()
        ready = base.startswith("clip") and words_is_installed()
        return DEFAULT_MAP if ready and not mapped else "pictures"
    if asked != "pictures" and base.startswith("clip") and not words_is_installed():
        sys.exit(f"The {asked} map reads words, which needs the text model. "
                 "Install it with pip install -e \".[words]\".")
    return asked


def _words_backend(base: str):
    from .embed import LiteWords, WordsBackend, words_is_cached
    if not base.startswith("clip"):
        return LiteWords()
    if words_is_cached():
        with step("Loading the text model"):
            return WordsBackend()
    print("Downloading the text model (about 90 MB from Hugging Face, first run only). Nothing of yours is sent.")
    return WordsBackend()


def _prepare_words(lib, base: str, map_name: str) -> str | None:
    """A vector for each item's words, for the maps that read them. Returns the text model's name."""
    if map_name == "pictures":
        return None
    from .maps import embed_words
    backend = _words_backend(base)
    embed_words(lib, backend, base)
    return backend.name


def _backend(args, map_name: str = "pictures"):
    from .embed import auto_backend, get_backend
    name = args.backend or auto_backend()
    if name == "lite":
        print("Using the lite embedder (install the 'clip' extra for much better maps).")
        return get_backend(name)
    import logging
    import os
    import warnings
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    logging.getLogger("huggingface_hub").setLevel(logging.ERROR)
    warnings.filterwarnings("ignore", module="huggingface_hub")
    from .embed import clip_is_cached, words_is_cached
    if clip_is_cached():
        # Offline is settled when the hub first loads, so it has to allow for the text model too.
        if map_name == "pictures" or words_is_cached():
            os.environ.setdefault("HF_HUB_OFFLINE", "1")   # no network, no warnings
        with step("Loading the image model (CLIP)"):
            return get_backend(name)
    print("Downloading the image model (CLIP, about 600 MB, first run only)")
    return get_backend(name)


def cmd_embed(args, lib):
    from .embed import embed_library
    embed_library(lib, _backend(args), force=args.force)


def cmd_layout(args, lib, backend=None):
    from .db import mark_unavailable
    from .layout import compute_layout
    mark_unavailable(lib)
    model = lib.get_meta("embedding_model")
    if not model:
        sys.exit("Nothing embedded yet; run `topograph embed` first.")
    map_name = _chosen_map(args, lib, model)
    if backend is None and model.startswith("clip"):
        backend = _backend(args, map_name)
    words = _prepare_words(lib, model, map_name)
    compute_layout(lib, model, backend=backend, map_name=map_name, words_model=words)


def _shown_model(args, lib) -> str:
    """Where the current map is stored."""
    from .maps import layout_model
    return layout_model(lib.get_meta("embedding_model"), getattr(args, "map", None) or lib.get_meta("map") or "pictures")


def cmd_export(args, lib):
    from .export import export
    with step("Writing the map for the viewer"):
        path = export(lib, _shown_model(args, lib))
    print(f"Wrote {path}")


def cmd_build(args, lib):
    from .embed import auto_backend, embed_library
    from .export import export
    from .layout import compute_layout
    from .maps import layout_model
    name = args.backend or auto_backend()
    map_name = _chosen_map(args, lib, "clip-vit-b-32" if name == "clip" else "lite-v1")
    backend = _backend(args, map_name)
    embed_library(lib, backend, force=args.force)
    words = _prepare_words(lib, backend.name, map_name)
    compute_layout(lib, backend.name, backend=backend, map_name=map_name, words_model=words)
    with step("Writing the map for the viewer"):
        path = export(lib, layout_model(backend.name, map_name))
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
    from .db import GONE_SQL
    for r in c.execute(f"select platform, count(*) n, sum(hydrated=1) h, sum({GONE_SQL}) g "
                       "from item group by platform"):
        print(f"  {r['platform']:10} {r['n']:6} items   {r['h'] or 0} with content, "
              f"{r['g'] or 0} no longer online (left off the map)")
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
    model = _shown_model(args, lib)
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


def cmd_sync(args, lib):
    from .sync import run
    with Progress(f"Syncing {args.source}", unit="records") as prog:
        seen, new = run(lib, args.source, args.account, limit=args.limit, progress=prog)
        prog.close(f"{seen:,} records, {new:,} new items")
    _stats(lib)


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
        p.add_argument("--map", choices=MAPS, help="which map to make (see maps.py; default: the last one built)")
        p.set_defaults(fn=fn)

    p = sub.add_parser("serve", help="open the viewer")
    p.add_argument("--port", type=int, default=8732)
    p.add_argument("--no-open", action="store_true")
    p.set_defaults(fn=cmd_serve)

    p = sub.add_parser("regions", help="list the map's regions and their names")
    p.add_argument("--depth", type=int, default=9, help="how many levels to show")
    p.set_defaults(fn=cmd_regions)

    p = sub.add_parser("sync", help="read your public activity from Bluesky or Are.na")
    p.add_argument("source", choices=["bluesky", "arena"])
    p.add_argument("account", help="your Bluesky handle or Are.na username")
    p.add_argument("--limit", type=int)
    p.set_defaults(fn=cmd_sync)

    sub.add_parser("stats", help="summarize the library").set_defaults(fn=cmd_stats)

    args = ap.parse_args(argv)
    lib = Library(args.library or default_library())
    try:
        args.fn(args, lib)
    except sqlite3.OperationalError as error:
        if "locked" not in str(error):
            raise
        sys.exit("Another Topograph task kept the library busy for too long. Try again in a moment.")
    finally:
        try:
            lib.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
