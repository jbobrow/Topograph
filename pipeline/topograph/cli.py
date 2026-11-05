"""topograph — command line for the prototype pipeline.

    topograph import ~/Downloads/instagram-*.zip
    topograph import ~/Downloads/twitter-2026-11-05-*.zip
    topograph hydrate            # fetch media for likes/saves (slow, polite, resumable)
    topograph build              # embed + layout + export
    topograph serve              # open the viewer
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from . import media as media_mod
from .config import default_library
from .db import Library, upsert_record
from .importers import IMPORTERS, detect
from .util import Archive


def cmd_import(args, lib):
    archive = Archive(args.paths)
    kinds = [args.platform] if args.platform else detect(archive)
    if not kinds:
        sys.exit("Couldn't recognize this export. Use --platform x|instagram to force it.")
    for kind in kinds:
        print(f"Importing {kind} from {', '.join(map(str, archive.sources))}")
        new = total = 0
        t0 = time.time()
        for rec in IMPORTERS[kind].parse(archive):
            new += upsert_record(lib, rec, media_mod.ingest)
            total += 1
            if total % 500 == 0:
                lib.conn.commit()
                print(f"  {total} records…")
        lib.conn.commit()
        print(f"  {total} records, {new} new items ({time.time() - t0:.1f}s)")
    _stats(lib)


def cmd_hydrate(args, lib):
    from .hydrate import download_pending_media, hydrate
    print("Fetching media for links (Ctrl-C to pause; run again to resume)")
    try:
        pre = download_pending_media(lib, delay=args.delay / 3)
        s = hydrate(lib, limit=args.limit, delay=args.delay,
                    platforms=[args.platform] if args.platform else None)
        print(f"  hydrated {s['hydrated']}, unreachable {s['unreachable']}, "
              f"media files {s['media'] + pre}")
    except KeyboardInterrupt:
        lib.conn.commit()
        print("\nPaused.")
    _stats(lib)


def _backend(args):
    from .embed import auto_backend, get_backend
    name = args.backend or auto_backend()
    if name == "lite":
        print("Using the lite embedder (install the 'clip' extra for much better maps).")
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
    path = export(lib, model)
    print(f"Wrote {path}")


def cmd_build(args, lib):
    from .embed import embed_library
    from .export import export
    from .layout import compute_layout
    backend = _backend(args)
    embed_library(lib, backend, force=args.force)
    compute_layout(lib, backend.name, backend=backend)
    print(f"Wrote {export(lib, backend.name)}")


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
