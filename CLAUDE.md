# Topograph: notes for working on this repo

Topograph is a private, on-device atlas of one person's taste. It pulls together what
they posted, liked, saved and bookmarked (Instagram, X, Facebook, later YouTube and
Google), plus screenshots, downloads and working files on their Mac. It keeps local
copies of the pictures and shows everything as terrain (things that resonate rise
into peaks) and as strata (the same regions through time). The owner is Jonathan
Bobrow (`jbobrow` on GitHub), a designer and maker, and the library is his own.

`docs/SPEC.md` is the product spec (principles, sources, data model, views, privacy,
roadmap). `README.md` is how to run the prototype. Read both before larger changes.

## What exists

The prototype (milestone M0) is a Python pipeline plus a static web viewer. It works
on the owner's real library: about 58,000 items from X, Instagram and 16,000 of his
own files.

```
pipeline/topograph/
  cli.py          `topograph` command: import, files, hydrate, embed, layout, export,
                  build, serve, regions, stats
  db.py           SQLite schema, Library, upsert_record, gone-item rules  <- source of truth for the schema
  config.py       interaction weights, image sizes, default library path
  importers/      x.py, instagram.py, facebook.py (archive ZIPs), files.py (folders on disk)
  hydrate.py      fetch text and media for liked or saved links (polite, resumable)
  media.py        display copies, thumbnails, palettes, perceptual hashes, video posters
  embed.py        CLIP (OpenCLIP ViT-B-32, laion2b_s34b_b79k) or "lite" fallback
  layout.py       UMAP to 2D, HDBSCAN fine regions, neighbors
  regions.py      nest regions into a tree and name them (see the module docstring)
  concepts.txt    vocabulary for region names; "look and feel" section is qualifiers
  export.py       writes topograph.json for the viewer; local HTTP server
  progress.py     terminal progress lines
viewer/           index.html, style.css, app.js (d3 v7 vendored), IBM Plex fonts
tests/            pytest; fixtures build fake X and Instagram archives
```

Run tests with `python -m pytest -q tests` (they use the lite backend and need no
network). Install with `pip install -e ".[clip,dev]"`.

## The library (what a native app opens)

It lives in `~/Library/Application Support/Topograph/` (override with `TOPOGRAPH_LIBRARY`):

- `topograph.sqlite`: WAL mode. Tables: `item`, `interaction`, `media`, `embedding`,
  `layout`, `cluster` (regions, with `parent`, `depth`, label anchor `x`, `y` and
  size `r`), `phrase_vec` (cached CLIP vectors of candidate names), `meta`. Use `db.py`
  as the reference: SPEC §3 is close but older (for example, `media` is keyed by
  `(item_id, ord)` and paths are relative to the library root).
- `media/<2 hex>/<sha256>-d.webp` is the display copy (long edge 1600) and
  `-t.webp` is the thumbnail (long edge 320).
- `topograph.json`: what the web viewer reads (items with x, y, region, resonance,
  thumbnail, history, neighbors; the region tree; strata counts).

Details that matter for compatibility:

- Item ids are `<platform>:<native id>`. One item can have many interactions.
- Resonance is the sum of `INTERACTION_WEIGHTS` over the item's distinct interaction
  types. It raises terrain and sizes thumbnails.
- Embedding vectors are float32 and L2-normalized, with model name `clip-vit-b-32`.
  For an image item, up to 4 images are averaged, then blended 0.75 / 0.25 with the
  caption (first 300 characters). Text-only items embed their text. A Core ML port
  has to use the same weights and recipe, or the vectors won't be comparable.
- Layout coordinates are in a 1000 × 1000 square, aspect preserved.
- An item is "gone" when it's unreachable (`hydrated = -1`) with no text and no
  `ok` media. It stays in the database so it isn't re-imported or re-fetched, and
  it's left off the map and out of counts (`GONE_SQL` in `db.py`). X's
  "this post is unavailable" notices are not content (`util.is_unavailable`).
- Timestamps are unix seconds. X likes carry no "liked at" time, so they use the
  post's own time and are flagged `at_estimated`.

## Rules that must hold

These come from the owner. Keep them in any port.

- Nothing leaves the machine except requests to fetch content the owner already
  engaged with, at a human pace (hydration waits about 1.5 s per item, stops after
  10 network failures in a row, and gives up on an item after a few attempts).
- Never read Instagram DMs (`messages/`).
- Your-files import (`importers/files.py`):
  - Skip sensitive folders and files: medical (including CT/MRI/x-ray/scans,
    prescriptions, lab results), identification, tax forms (W-2/W-9/1099), banking,
    passwords. Keep the letter-boundary regexes; they were tuned on real names like
    `JAMIE_CT_Scan`.
  - Skip downloads from bank and .gov hosts.
  - Honor `.topographignore` files (`*` stays within one folder, `**` crosses
    folders, `!` re-includes). The owner excluded `Dropbox (Personal)/Personal/Family/`
    and other people's folders on a class site.
  - Read files in place; store only previews.
- Deleting files on the owner's computer needs explicit permission.
- No telemetry and no account. Optional AI naming through an outside model must be
  off by default and say what it sends.

## Design language (the viewer and the mockups)

- **Overall:** a monochrome instrument panel in the spirit of Teenage Engineering.
  One ink (`#111`), one ground (`#e9e9e6`), a raised surface (`#f4f4f1`), a mid-gray
  for secondary text (`#5a5a54`), and rules (`#b4b4ae`). Dark mode inverts. Selection
  inverts.
- **Type:** IBM Plex Mono for the interface and labels, Plex Sans for captions and
  prose.
- **Controls:** every control is a "key": 26px tall, 3px radius, 1px rule, with a 7px
  square LED that fills when the key is on.
- **Shading:** elevation and strata layers use 1-bit dither and pattern fills (Bayer
  dot screens, hatches, rules, checks) instead of color.
- **Images:** gray by default (color and 1-bit modes exist), shown in full color on
  hover.
- **Region names on the map:**
  - They are boxed mono labels with a crosshair at the anchor, and top-level names
    are inverted.
  - They follow zoom: a region's name gives way to the names of the regions inside
    it once it is large on screen, and a bar at the top left shows where you are.
  - A name is either shown or hidden, never left half-faded.
- **Mockups:** a Claude Design canvas, "Topograph for Mac", has five boards: Terrain,
  Item, Strata, Echoes, Sources.

## Native app: where it's headed

The plan is in SPEC §6 and §8:

- **Platform:** macOS 14+, Apple silicon first.
- **Stack:** a SwiftUI shell, a Metal canvas for Terrain and large grids, SQLite via
  GRDB (vectors later in `sqlite-vec`), Core ML CLIP, Apple Vision for OCR and
  dedupe, `URLSession` plus a signed-in `WKWebView` for Instagram hydration, and
  FSEvents later to watch folders.
- **M1, the next step:** a native shell that opens the prototype's library read-only,
  with Terrain (Metal), Strata, item detail and search. Python stays the reference
  for import, embedding, layout and naming until M2 ports them.
- **Approach:**
  - Open the SQLite file read-only. It's in WAL mode and the Python tools may be
    writing at the same time.
  - Read regions from the `cluster` table rather than recomputing them.
  - Port behavior from `viewer/app.js`: dithered terrain via density contours, zoom
    tiers for thumbnails, the region-name rules above, and hover in color.
- **Performance target:** tens of thousands of thumbnails at display refresh rate.
  The web viewer is already fast enough at the current size, so the native app is
  about feel, integration and the native pipeline, not rescuing performance.

Suggested home for the Xcode project: `mac/` at the repo root. Keep the Python
pipeline working alongside it.

## Working agreements

- Commit messages explain why. End them with the attribution lines your environment
  asks for.
- Test on real data when you can (the owner can run commands and paste output, such
  as `topograph regions` or `topograph stats`). Synthetic tests catch regressions but
  have misled tuning before.
- Keep progress output calm and informative: one live line per long step.
