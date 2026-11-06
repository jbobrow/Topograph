# Topograph

A private, on-device atlas of your online taste.

Topograph reads the data exports from the platforms you use, keeps a local copy
of what you posted, liked and saved, and maps it as terrain: things you keep coming
back to rise into mountain ranges, passing interests stay foothills, and a time
scrubber shows the landscape changing over the years.

This repository holds the **prototype**: a Python pipeline plus a web viewer that
runs on `localhost`. It proves the importers, the model and the views on real
archives before the native macOS app is built. See [docs/SPEC.md](docs/SPEC.md)
for the full product spec and roadmap.

## 1. Request your exports

They can take a day or two to arrive.

| Platform | Where | Choose |
|---|---|---|
| Instagram | Accounts Center → Your information and permissions → Download your information | **JSON**, All time, High media quality |
| X | Settings → Your account → Download an archive of your data | (one format) |
| Facebook | Accounts Center → Your information and permissions → Download your information | **JSON**, All time, High media quality |

YouTube and Google (Takeout) are next on the roadmap.

## 2. Install

Requires Python 3.10+. On a Mac with Apple silicon, CLIP runs on the GPU via Metal.

```sh
git clone https://github.com/jbobrow/Topograph.git
cd Topograph
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[clip,words,heif]"
```

`ffmpeg` (e.g. `brew install ffmpeg`) is optional; with it, videos get a poster frame.

## 3. Build your map

```sh
topograph import ~/Downloads/instagram-yourname-2026-11-06-*.zip   # all parts at once
topograph import ~/Downloads/twitter-2026-11-06-*.zip
topograph import ~/Downloads/facebook-yourname-*.zip
topograph files ~/Desktop ~/Downloads --dry-run   # see what it would take from your folders
topograph files ~/Desktop ~/Downloads             # then read them
topograph import ~/Downloads/takeout-*.zip        # YouTube and Google searches (choose JSON)
topograph sync bluesky your.handle                # or: sync arena your-username (public data, no login)
topograph hydrate          # fetch images for liked/saved posts (slow and polite; resumable)
topograph build            # embeddings + layout + region names (a new library gets the blended map)
topograph build --map words  # build another map: blended, words or pictures
topograph regions          # print the region tree and names
topograph serve            # opens http://127.0.0.1:8732
```

`topograph stats` summarizes the library at any time. Re-importing a newer export
only adds what's new.

Your own photos are dated by when they were taken, not when they reached your Mac. If you
imported files before this was so, `topograph files --fix-dates` corrects them and adds nothing.

A map is one way of arranging your items, and a library can keep several. **Blended**, the
suggested one, reads pictures and words and draws your files in beside posts about the same
thing. **Words** reads pictures and words without moving your files. **Pictures** is mostly how
things look. Blended and words download a text model once (about 90 MB, from Hugging Face), and
nothing of yours is sent. Your other commands act on the map built last.

The library lives in `~/Library/Application Support/Topograph/` on a Mac (override
with `--library PATH` or `TOPOGRAPH_LIBRARY`). It's one SQLite file plus a `media/`
folder of optimized copies. Nothing is uploaded anywhere.

## Your files

`topograph files` reads folders on your Mac in place (it stores previews, not copies)
and keeps only what macOS says is yours: screenshots, downloads (with the address they
came from), files you've opened, and working files like PSD, Sketch, Procreate, STL and
video. It skips icons, assets inside code projects, saved web pages, files that are only
in the cloud, PDFs, and anything in folders named like medical, ID, tax or banking.

Always start with `--dry-run`. It ends with a list of folders full of images that show
no sign of being yours; leave out the ones that aren't your work with
`--exclude ~/path/to/folder` (remembered for next time), or put a `.topographignore`
file in a folder above it. It works like .gitignore: one path or pattern per line,
relative to that folder, and `!` keeps one back:

```
# a mirrored class site: leave out everyone's page but mine
863.14/people/*/
!863.14/people/jonathan_bobrow/
```

Run `topograph files` again later with no folders to pick up what's new.

On a Mac, install with the `xattr` package (included in the install line above).

## The viewer

- **Terrain**: everything you've engaged with, placed by visual and semantic
  similarity. Elevation is how much it resonated (a save outweighs a like). Zoom in
  and peaks resolve into images. Regions nest: zoomed out you see the broad ones,
  and as you zoom in their names give way to the regions inside them (the bar at
  the top left shows where you are). Click a region name to see its contents and when
  it was on your mind; click an image for its details, your history with it and its
  nearest neighbors in taste.
- **Strata**: each region as a layer through time (one level of the region tree,
  about a dozen layers).
- Things you made or posted are squares on the map (and solid frames on thumbnails);
  things you kept are circles. Your own files have a **show in finder** key.
- **color / gray / 1-bit** switches how images are drawn. 1-bit dithers them to
  match the terrain.
- **Time scrubber**: drag across the bar to watch the terrain for a period, or press
  play to slide through the years.

## The Mac app

The native app opens the library you built above and has every view: Terrain, Strata,
Echoes, Palette, Drift, Process and Sources, with item and region panels, filters and
the time scrubber. It needs macOS 14 or later and Xcode. The timeline's bars follow
your filters, and with an item open, Strata marks where and when it sits.

```bash
xcodebuild -downloadComponent MetalToolchain   # once, if Xcode doesn't have it yet
open mac/Topograph.xcodeproj                   # then press Run
```

It reads `~/Library/Application Support/Topograph/`, or the folder in
`TOPOGRAPH_LIBRARY`, and only ever reads it: pipeline commands can keep running while
it's open, and **Map → Reload Library** (⌘R) shows a new layout. Drag to draw a rectangle
to zoom into, or hold space and drag to move the map (esc cancels a rectangle). Two
fingers also move it, pinching zooms, and with a mouse the wheel zooms. While you're
zoomed in, a minimap at the bottom left shows where you are: press or drag on it to go
somewhere else. Hold ⌘, or rest on a key for a second, to see its shortcut. Space also pauses the timeline while it's playing.

Palette has three views. **Wheel** moves like the terrain. **Cylinder** stands the same
pictures up, with hue around it, colorfulness out from its axis and light to dark from top
to bottom: drag to turn it. **Through time** is Strata's chart with bands of color for layers.

**Sources** adds your history by running the `topograph` commands below for you, only
when you ask. It finds them in this repo's `.venv`, or at `TOPOGRAPH_CLI`. Folders get a
dry run first, so you see what would be read. It's also where you build maps and switch
between them.

In **Strata**, scrolling zooms in and out around the pointer and sideways scrolling moves along
time. Both change the time selected, the same one the timeline shows, so it also applies to the
other views. **Selection** fits the canvas to it, with a small Strata of all of time as a minimap,
and **all time** shows the whole timeline with that part shaded.

Find matches words in captions and names. The **by meaning** key next to it finds what
things are about, using CLIP on your Mac. It needs a model of about 600 MB, which is too
large for the repository, so make it once from the weights the pipeline already uses:

```bash
python3.13 -m venv /tmp/convert
/tmp/convert/bin/pip install coremltools open_clip_torch torch
/tmp/convert/bin/python mac/tools/convert_clip.py
```

It goes in `~/Library/Application Support/Topograph/models/`. Your search stays on this
Mac. Items only turn up once they have a vector, so anything hydrate has just changed
waits until the map is next updated.

Naming regions with Claude is off until you turn it on
with your own API key, and it says what it sends first.

## What to expect from each export

- **Your own posts** come with their images and captions, so they map immediately.
- **Liked and saved posts** arrive as links only. `topograph hydrate` fetches their
  images: for X it uses the public endpoint behind embedded tweets; for Instagram
  it tries each post's public embed page. Instagram increasingly requires a login,
  so expect some to stay unreachable. They still count in Strata as "not yet
  mapped". The native app will fetch these through a browser view signed in as you.
- **X likes** carry no date in the archive. Topograph uses the post's own date as
  an estimate and marks it as approximate.

## Development

```sh
pip install -e ".[dev]"
pytest
```

Tests build small exports in both Instagram record formats (including its
mis-encoded emoji) and an X archive with split files, then run the whole pipeline
with the `lite` embedder (no model download).

```
pipeline/topograph/
  importers/   x.py, instagram.py, facebook.py: export parsers
               files.py: your own folders, read in place
  db.py        library schema (shared with the future native app)
  media.py     display copies, thumbnails, palettes, perceptual hashes
  hydrate.py   fetch media for links
  embed.py     CLIP (or lite) embeddings
  layout.py    UMAP map, HDBSCAN regions
  regions.py   nesting regions and naming them
  concepts.txt vocabulary for region names (edit freely)
  export.py    viewer data + local server
viewer/        static web viewer (d3 and IBM Plex fonts, bundled; Plex is under the SIL OFL)
docs/SPEC.md   product spec
```
