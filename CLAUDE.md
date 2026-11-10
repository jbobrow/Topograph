# Topograph: notes for working on this repo

Topograph is a private, on-device atlas of one person's taste. It pulls together what
they posted, liked, saved and bookmarked (Instagram, X, Facebook, later YouTube and
Google), plus screenshots, downloads and working files on their Mac. It keeps local
copies of the pictures and shows everything as terrain (things that resonate rise
into peaks) and as strata (the same regions through time). The owner is Jonathan
Bobrow (`jbobrow` on GitHub), a designer and maker, and the library is his own.

`docs/SPEC.md` is the product spec (principles, sources, data model, views, privacy,
roadmap). `README.md` is how to run the prototype. `docs/MAPPING.md` explains how the map is
made (vectors, recipes, UMAP, regions, names, terrain) and the alternatives. Read both before larger changes.

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
  importers/      x.py, instagram.py, facebook.py, youtube.py, google.py (archive ZIPs),
                  files.py (folders on disk)
  sync.py         Bluesky and Are.na: public data, no login, at a human pace
  hydrate.py      fetch text and media for liked or saved links (polite, resumable)
  media.py        display copies, thumbnails, palettes, perceptual hashes, video posters
  embed.py        CLIP (OpenCLIP ViT-B-32, laion2b_s34b_b79k) or "lite" fallback; the text model
  maps.py         the recipes for each map (blended, words, pictures)
  layout.py       UMAP to 2D, HDBSCAN fine regions, neighbors
  regions.py      nest regions into a tree and name them (see the module docstring)
  concepts.txt    vocabulary for region names; "look and feel" section is qualifiers
  export.py       writes topograph.json for the viewer; local HTTP server
  progress.py     terminal progress lines
viewer/           index.html, style.css, app.js (d3 v7 vendored), IBM Plex fonts
tests/            pytest; fixtures build fake X and Instagram archives
mac/              the native app (M1), see "Native app" below
```

Run tests with `python -m pytest -q tests` (they use the lite backend and need no
network). Install with `pip install -e ".[clip,dev]"`. Test the Mac app's core with
`swift test --package-path mac/TopographCore`.

## The library (what a native app opens)

It lives in `~/Library/Application Support/Topograph/` (override with `TOPOGRAPH_LIBRARY`):

- `topograph.sqlite`: WAL mode. Tables: `item`, `interaction`, `media`, `embedding`,
  `layout`, `cluster` (regions, with `parent`, `depth`, label anchor `x`, `y` and
  size `r`), `cloud` (searches over a map), `phrase_vec` (cached CLIP vectors of candidate
  names), `meta`. Use `db.py`
  as the reference: SPEC §3 is close but older (for example, `media` is keyed by
  `(item_id, ord)` and paths are relative to the library root).
- `media/<2 hex>/<sha256>-d.webp` is the display copy (long edge 1600) and
  `-t.webp` is the thumbnail (long edge 320).
- `topograph.json`: what the web viewer reads (items with x, y, region, resonance,
  thumbnail, history, neighbors; the region tree; strata counts).

Details that matter for compatibility:

- Item ids are `<platform>:<native id>`. One item can have many interactions. One thing is one
  item: an X repost is a `repost` on the post it reposts (found by its pictures' source id, or by
  its text matching a post you liked), and your own Instagram post takes its shortcode when you
  liked or saved it. A record's `replaces` names ids an older import used, and `absorb` folds
  them in, so re-importing mends a library.
- Resonance is the sum of `INTERACTION_WEIGHTS` over the item's distinct interaction
  types. It raises terrain and sizes thumbnails.
- Embedding vectors are float32 and L2-normalized, with model name `clip-vit-b-32`.
  For an image item, up to 4 images are averaged, then blended 0.75 / 0.25 with the
  caption (first 300 characters). Text-only items embed their text. A Core ML port
  has to use the same weights and recipe, or the vectors won't be comparable.
- Layout coordinates are in a 1000 × 1000 square, aspect preserved.
- A library can hold several maps (`maps.py`): `layout` and `cluster` rows are stored under
  `clip-vit-b-32` for pictures and `clip-vit-b-32+<map>` for the others, and `meta.map` says
  which was built last. `embedding_model` stays `clip-vit-b-32`, because search by meaning,
  region names and Tributaries all read those vectors on every map. The text model's vectors
  (`minilm-l6-v2`, 384 dimensions) are in `embedding` too, so filter by model. Region numbers
  are per map, so `Library.detail`, `sources` and your region names all take the map.
- Searches (items whose only interaction is `search`, `SEARCH_ONLY_SQL`) aren't land. Each
  map is laid out without them, then each is set over the pictures nearest it in meaning,
  scored as search by meaning scores (`place_clouds` / `MapBuilder.placeClouds`, which match),
  into `cloud`. They aren't "waiting to be mapped". The app shows them as weather
  (`Clouds.weather`): where the 90 days before the time shown searched more than usual. In 3D
  they float as stacked slices above the peaks and cast shadows. Clicking one opens its searches,
  grouped into themes (`CloudThemes`: by the text model's vectors, named by their own words);
  `topograph-native check-clouds [yyyy-mm-dd]` prints a season's themes for judging them.
- An item is "gone" when it's unreachable (`hydrated = -1`) with no text and no
  `ok` media. It stays in the database so it isn't re-imported or re-fetched, and
  it's left off the map and out of counts (`GONE_SQL` in `db.py`). X's
  "this post is unavailable" notices are not content (`util.is_unavailable`).
- Timestamps are unix seconds. X likes carry no "liked at" time, so they use the
  post's own time and are flagged `at_estimated`.
- A file's date depends on what it is (`_dates` in `importers/files.py`). A download's arrival
  is when you kept it. Your own photo is dated by its camera date, then its creation date, never
  its arrival: exporting from Photos stamps every file with that day, and marks each as used.
  `topograph files --fix-dates` corrects files already imported and adds none.

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
  square LED that fills when the key is on. The exception is the view tabs (terrain,
  strata, and so on): the selected one inverts and they carry no LED.
- **Shading:** elevation and strata layers use 1-bit dither and pattern fills (Bayer
  dot screens, hatches, rules, checks) instead of color.
- **Images:** gray by default (color and 1-bit modes exist), shown in full color on
  hover. Palette keeps its own setting, which starts on color, since color is its subject.
  The side panel is always in color: that's where you go to look at something properly. On the
  map and the wheel, the open item's picture floats in color above its place (`FloatingPicture`).
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
- **Status of `mac/`:**
  - M1 is done, including search by meaning. `mac/tools/convert_clip.py` makes the Core ML
    models (float32, so they run on the CPU or GPU, not the Neural Engine), which live in
    `~/Library/Application Support/Topograph/models/`, not the repo. `CLIPEncoder`,
    `CLIPTokenizer` and `CLIPImage` match Python: identical tokens on every real caption,
    and cosine at least 0.9996 on sampled items. The one known gap is ftfy's mojibake repair.
  - `EmbeddingStore.nearest` doesn't rank by plain cosine, which fails on real data: see
    its comment before changing it. Judge changes on real searches, not on tests.
  - M2 is done, apart from a way to get the models onto another Mac (see below). `TopographCore/Sources/TopographCore/Pipeline/`
    holds the importers, media ingest, hydration, sync, embedding, the text model, UMAP, HDBSCAN, nesting and naming, and
    `PipelineRunner` runs them. The Python pipeline stays as the reference and for the web viewer (the app doesn't write
    `topograph.json`). Keep the two in step until it retires: `mac/tools/compare_libraries.py` compares a library from each,
    row by row, and `swift run topograph-native` runs the Swift side from a terminal, with `check-regions`, `check-words` and
    `check-palette` for what Python stored.
  - A Swift map isn't the same picture as a Python one (different random numbers), but given the same positions, regions and
    names match. Neighbors for UMAP are exact, not approximate, and the same vectors always draw the same map.
  - Instagram hydration through a signed-in `WKWebView` (`InstagramSession`) is written but hasn't been tried signed in.
  - Models: `convert_clip.py` and `convert_minilm.py` still need Python. Nothing yet puts them on a Mac that doesn't have them.
  - M3: YouTube and Google Takeout importers and Bluesky and Are.na sync exist in both,
    tested on fixtures only. Photos library isn't started.
  - M4 is done except showing a Process sequence as one item on the map, and keeping
    region names across re-layouts (they're matched by region number, so a re-layout
    clears them).
- **Opening the library:** always through `Library`, whose reads go through a read-only
  connection, and write only through `LibraryWriter`. Strict read-only can't open a WAL file with no `-wal` or `-shm`, which is
  how the Python tools leave it on exit, so `Library` handles that. `query_only` isn't
  enough: GRDB resets it after each read.
- **Testing anything that writes:** set `TOPOGRAPH_LIBRARY` to a throwaway folder. The app's
  preferences are shared across libraries, so clear what a test sets (`mapRecipe`).
- **Maps:** the Sources page offers them, with blended suggested. The choice is an app preference, and
  building one runs `MapBuilder.build`. Judge a recipe by eye on the real library
  as well as by numbers: its subject-spread numbers got worse while its neighbors looked right.
- **Approach:**
  - Open the SQLite file read-only. It's in WAL mode and the Python tools may be
    writing at the same time.
  - Read regions from the `cluster` table rather than recomputing them.
  - Port behavior from `viewer/app.js`: dithered terrain via density contours, zoom
    tiers for thumbnails, the region-name rules above, and hover in color.
- **Performance target:** tens of thousands of thumbnails at display refresh rate.
  The web viewer is already fast enough at the current size, so the native app is
  about feel, integration and the native pipeline, not rescuing performance.
- **Strata's view of time:** there's one state, the time selected (`filter.range`), so the
  timeline, the minimap and the canvas can't disagree. Zooming and moving change it, and the
  close up / in context switch only decides whether the canvas fits it.
- **The timeline:** playing and scrubbing update the map up to 60 times a second, so
  a map update has about 2 ms to run. `TimeSlicer` works out everything but the time
  range once, `DensityField` blurs across all cores, and `TopographCore` is optimized even
  in Debug builds. `AppModel.applyFilter` runs one update at a time and never discards a
  finished one: dropping late results is how playback once showed 4 frames out of 58.

The Xcode project is `mac/Topograph.xcodeproj`, beside the Python pipeline:

```
mac/
  TopographCore/    Swift package with no UI: Library (read-only GRDB), DensityField
                    (d3.contourDensity port), Regions, Strata, Depth (Echoes, Palette,
                    Tributaries, Process), PaletteSpace (camera, places), MapFilter, MapRecipe, Minimap,
                    Moodboard, RegionNamer, CLIP (encoder,
                    tokenizer, image preparation), Pipeline/ (LibraryWriter, importers, MediaIngest,
                    Hydrator, LiveSync, WordsEncoder, MapBuilder, Layout/), and tests. CWebP is libwebp's
                    encoder, built in so it's optimized in Debug builds: as a dependency it made imports
                    eight times slower. topograph-native is the pipeline from a terminal.
  Topograph/        SwiftUI shell, TerrainView (MTKView), PaletteView (MTKView), TerrainRenderer, Terrain.metal,
                    ThumbnailStore, LabelStore, DetailPanel, StrataView, DepthViews,
                    SourcesView, PipelineRunner (runs the pipeline), InstagramSession
  tools/            make_icon.swift draws the app icon at every size; convert_clip.py and convert_minilm.py
                    make the Core ML models; compare_libraries.py checks the port against Python
```

The project uses a folder-synced group, so a new file in `mac/Topograph/` joins the
target by itself. The app isn't sandboxed, because the library lives outside any app
container. Building needs Xcode's Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

## Working agreements

- Commit messages explain why. End them with the attribution lines your environment
  asks for.
- Test on real data when you can (the owner can run commands and paste output, such
  as `topograph regions` or `topograph stats`). Synthetic tests catch regressions but
  have misled tuning before.
- Keep progress output calm and informative: one live line per long step.
