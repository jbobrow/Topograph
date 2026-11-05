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
pip install -e ".[clip,heif]"
```

`ffmpeg` (e.g. `brew install ffmpeg`) is optional; with it, videos get a poster frame.

## 3. Build your map

```sh
topograph import ~/Downloads/instagram-yourname-2026-11-06-*.zip   # all parts at once
topograph import ~/Downloads/twitter-2026-11-06-*.zip
topograph import ~/Downloads/facebook-yourname-*.zip
topograph files ~/Desktop ~/Downloads --dry-run   # see what it would take from your folders
topograph files ~/Desktop ~/Downloads             # then read them
topograph hydrate          # fetch images for liked/saved posts (slow and polite; resumable)
topograph build            # embeddings + layout + region names
topograph serve            # opens http://127.0.0.1:8732
```

`topograph stats` summarizes the library at any time. Re-importing a newer export
only adds what's new.

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
  and peaks resolve into images. Click a region name to see its contents and when
  it was on your mind; click an image for its details, your history with it and its
  nearest neighbors in taste.
- **Strata**: each region as a layer through time.
- Things you made or posted are marked in blue, on the map and in thumbnail frames.
  Your own files have a **Show in Finder** button.
- **Time scrubber**: drag across the bar to watch the terrain for a period, or press
  play to slide through the years.

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
  layout.py    UMAP map, HDBSCAN regions, region names
  export.py    viewer data + local server
viewer/        static web viewer (d3, vendored)
docs/SPEC.md   product spec
```
