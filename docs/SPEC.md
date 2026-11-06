# Topograph — Product Spec

> A private, on-device atlas of your online taste.

Topograph gathers everything you have posted, liked, saved and bookmarked across the
platforms you use, plus the screenshots, downloads and working files on your own
computer, keeps a local copy of the visual material, and lets you explore it as a
landscape. Things you keep coming back to rise into mountain ranges; passing
interests are foothills; the terrain shifts as the years go by.

---

## 1. Principles

1. **Yours, on your machine.** All data, media and models stay on the device. No
   account, no server, no telemetry. Network access is used only to fetch media for
   items you liked or saved and to sync platforms with open APIs.
2. **Links are forever, copies are a courtesy.** Every item keeps its original URL.
   Local media is an optimized copy so the archive survives deletions and stays fast.
3. **Signal over noise.** A bookmark says more than a like; a post you wrote says
   something different from a post you saved. Topograph weights and labels each
   kind of interaction instead of flattening them.
4. **Explore, don't rank.** No scores, no "you are 34% minimalist." The interface is
   a place to wander and notice, not a profile to be judged by.
5. **Import is the backbone, live sync is a bonus.** Official data exports are
   complete and durable; APIs are partial and change. Design for exports first.

---

## 2. Sources

### Phase 1 — Instagram and X (archive import)

| Platform | How to get it | What's inside | What's missing |
|---|---|---|---|
| **Instagram** | Accounts Center → Your information and permissions → Download your information. **JSON**, All time, High quality. | Your posts, stories, reels (with media files and captions); liked posts; saved posts and collections; comments you wrote. | Liked/saved items are **links only** (URL, author, timestamp): no image, no caption. |
| **X** | Settings → Your account → Download an archive of your data. | `tweets.js` (your posts and replies with full text and entities), `like.js` (liked post id, text, URL), `bookmark.js` (when present), `tweets_media/` (your attached media). | Likes and bookmarks carry no media; liked posts' authors and dates are not always present. |

Both exports are ZIPs. Topograph accepts the ZIP or the unzipped folder, and
re-importing a newer export only adds what's new (idempotent by stable item id).

Format notes the parsers handle:

- **X** files are JavaScript shims: `window.YTD.<feed>.part<N> = [ ... ]`. Strip the
  prefix, then parse JSON. Entries are wrapped (`{"tweet": {...}}`, `{"like": {...}}`).
  Dates look like `Wed Jul 03 14:23:01 +0000 2024`. Large feeds are split into
  `part0`, `part1`… files. The media folder is `tweets_media/` (older:
  `tweet_media/`), files named `<tweetId>-<mediaKey>.<ext>`.
- **Instagram** JSON has changed shape several times. Older exports use
  `string_list_data` / `string_map_data` records with `href` and `timestamp`;
  newer ones use `label_values`. Text is UTF-8 that was mis-encoded as Latin-1
  (emoji show as `Ã°Â\x9f…`) and must be repaired. Topograph parses by walking each
  file for records that carry a URL and a timestamp rather than trusting one schema.

### Phase 1b — Facebook (archive import)

Same Accounts Center as Instagram, same JSON quirks (mis-encoded text, shifting record
shapes), so the importer reuses Instagram's tolerant walker.

| In the export | Becomes |
|---|---|
| Your posts, photos and albums (with media files) | Items with images, often your oldest |
| Saved items | Links you saved |
| Pages you liked | Short text items (a page name says something) |
| Comments | Your words |
| Likes and reactions | Usually just "You liked Ann's photo": no link, no image. Kept as **traces** that count in Strata but are not placed on the map |

### Phase 1c — Your files (folders on this computer)

The other half of taste: what you **made** and grabbed, not just what you kept from
other people. Folders are read in place; Topograph stores only previews and thumbnails,
and each item links back to the file.

Most images on a disk were never made or seen by you (app assets, icon sets, code
dependencies, saved web pages). macOS records signals that separate yours from the
rest, as extended attributes on the file itself:

| Signal | Where macOS keeps it | Means |
|---|---|---|
| Screen capture | `kMDItemIsScreenCapture`, or the file name | You took this screenshot |
| Where from | `kMDItemWhereFroms` (the source URLs) | You downloaded it; links back to the original |
| Quarantine | `com.apple.quarantine` (time + app that saved it) | Downloaded or received; "Photos" means your own camera |
| Last used | `com.apple.lastuseddate#PS` | You opened it |
| Working file | PSD, AI, Sketch, Procreate, STL, 3MF, video… | Something you saved yourself |

Rules, in order: skip PDFs (opt-in), sensitive places (medical, ID, tax, banking,
passwords; by folder or file name), files that live only in the cloud (opt-in: reading
downloads them), images under 12 KB (icons, sprites), downloads from banks and
government sites, platform exports (suggested for `topograph import` instead), saved
web page folders (`*_files`), and assets inside code projects (a folder with `.git`,
`package.json`, `Package.swift`…) unless you opened them. Images with **no** signal are
kept only if they're reasonably large, and the importer lists them by folder so you can
exclude folders that aren't your work (`--exclude`, remembered, or a `.topographignore`
file beside them that works like .gitignore).

Previews: images directly; videos by a frame; everything else through macOS Quick Look
(PSD, AI, Sketch, PDF, STL, 3MF…).

A first read-only scan of four folders on the author's Mac (Desktop, Downloads,
Developer, Dropbox) found about 139,000 images, working files, videos and PDFs. The rules
kept about 23,700: 5,000 images saved from the Photos app, 4,100 downloads with their source address,
2,400 screenshots, 1,900 working files, the rest unsignaled images in creative folders.
They skipped 88,000 icons and sprites, 11,000 code-project assets, 650 files in
sensitive folders and 2,900 PDFs. They also found a 2025 X archive sitting in Downloads.
The largest unsignaled group was a mirror of a class website, other people's
documentation, which is exactly what the folder review is for.

### Phase 2 — YouTube and Google activity (Takeout)

- **YouTube** (Takeout → YouTube and YouTube Music): watch history, likes playlist,
  your own playlists and comments. Thumbnails are fetched from the public thumbnail
  CDN by video id.
- **Google My Activity** (Takeout → My Activity, **JSON** format): search history,
  Discover, Image Search, Chrome. Searches become *text-only* items. They describe
  curiosity rather than taste, so they get their own layer and are off by default
  in the Terrain view.

### Phase 3 — Live sync and more archives

Open APIs: **Bluesky** (AT Protocol: likes, posts, reposts), **Are.na** (channels and
blocks). Archive imports: **Pinterest**, **Tumblr**, **Reddit** (saved/upvoted),
**TikTok** (favorites, likes), **Letterboxd**, **Spotify** (saved tracks, for album art).

---

## 3. Data model

One table of **items** (things out in the world) and one of **interactions** (what you
did with them). The same tweet can be liked *and* bookmarked; that is one item with two
interactions.

```
item
  id              text  primary key   -- "<platform>:<native id>", e.g. "x:1764…", "ig:CxYz…"
  platform        text                -- instagram | x | facebook | files | youtube | google | bluesky | …
  kind            text                -- image | video | text | link | trace (no content to map)
  url             text                -- canonical link to the original
  author          text  nullable
  text            text  nullable      -- caption / tweet text / title
  created_at      int   nullable      -- when the item was published (unix seconds)
  hydrated        int                 -- 0 = only a link, 1 = media/text fetched, -1 = unreachable

interaction
  item_id         text  → item.id
  type            text                -- post | reply | repost | comment | like | react | save | bookmark
                                      -- made | capture | download | open | view | search
  at              int                 -- when YOU did it (unix seconds)
  collection      text  nullable      -- Instagram collection, X bookmark folder, …
  source_file     text                -- which export file it came from (provenance)
  primary key (item_id, type, at)

media
  id              text  primary key   -- sha256 of original bytes
  item_id         text  → item.id
  ord             int                 -- position in a carousel
  original_url    text  nullable
  local_path      text                -- display copy (long edge 1600px, WebP/HEIC)
  thumb_path      text                -- grid copy (long edge 320px)
  width, height   int
  phash           text                -- perceptual hash for near-duplicate detection
  palette         text                -- JSON: 5 dominant colors with weights

embedding
  item_id         text  → item.id
  model           text                -- e.g. "clip-vit-b-32"
  vector          blob                -- float32, L2-normalized

layout                                -- recomputed on demand; cheap to throw away
  item_id, x, y, cluster, model, computed_at
```

### Interaction weights (defaults, user-adjustable)

| Interaction | Weight | Rationale |
|---|---|---|
| bookmark / save | 3.0 | Deliberate act of keeping |
| post (your own) | 2.5 | What you chose to put out |
| repost | 2.0 | Amplified, in public |
| made (your files, your photos) | 2.5 | You made it |
| reply / comment | 1.5 | Engaged, but often conversational |
| capture (screenshot) | 1.5 | Worth keeping a copy of, right then |
| like | 1.0 | Cheap, frequent, still meaningful in aggregate |
| download | 1.0 | Kept, but often for a task |
| open (a file, again) | 0.5 | It mattered enough to return to |
| react (Facebook trace) | 0.5 | Presence without content |
| view / watch | 0.3 | Passive |
| search | 0.2 | Curiosity, not taste |

An item's **resonance** is the sum of its interaction weights. Resonance raises
terrain, sizes thumbnails, and orders "most resonant" lists.

---

## 4. Pipeline

```
 export ZIPs ─► Import ─► Hydrate ─► Cache media ─► Embed ─► Layout ─► Views
              (parse)   (fetch     (thumbs,       (CLIP    (UMAP,
                         missing    palette,       image+   clusters,
                         media)     phash)         text)    terrain)
```

1. **Import.** Platform parsers emit normalized items and interactions into SQLite.
   Every record keeps `source_file` for provenance. Idempotent.
2. **Hydrate.** Liked and saved items arrive as bare links. A rate-limited background
   queue fetches their media and text:
   - *X:* the public embed (syndication) endpoint behind embedded tweets has
     returned text, author, date and media URLs for a tweet id without a login. It
     is unofficial and can change, so the signed-in web view is the fallback here too.
   - *Instagram:* public pages expose an `og:image` and description, but Instagram
     increasingly requires a login. The native app hydrates through an embedded
     web view signed in **as the user**, at human pace (a few requests per second at
     most, pausable). Items that cannot be reached stay as links and are marked
     `hydrated = -1`. They still appear in Strata as presence even without an image.
3. **Cache media.** Store a display copy and a thumbnail, never the full-size original
   by default (option: "keep originals"). Deduplicate by content hash; flag
   near-duplicates by perceptual hash. Extract a 5-color palette.
4. **Embed.** One vector per item in a shared image-text space (CLIP family):
   image items embed the image, blended with the caption when one exists; text-only
   items embed the text. On a Mac this runs on the Neural Engine via Core ML.
   A CLIP ViT-B/32-class model is small enough that an archive of tens of thousands
   of items should embed in minutes, not hours (to be benchmarked in M2).
5. **Layout.** UMAP reduces vectors to 2D (cosine metric, `n_neighbors≈30`,
   `min_dist≈0.05`). HDBSCAN finds fine regions; Ward linkage on their centers nests
   them into larger ones (about 7 at the top, roughly 3 children each, down to the
   fine regions), so every region sits inside one parent. A Gaussian kernel density
   estimate over the 2D points, weighted by resonance, becomes the terrain's elevation
   field; contour lines are drawn at fixed density quantiles.
6. **Label.** Each region is named by the phrase that best tells it apart from its
   siblings. Candidates are a curated vocabulary (`concepts.txt`) plus words, phrases
   and hashtags that recur in the person's own captions and file and folder names.
   Two kinds of evidence are added: how much more the phrase fits the region's items
   than its siblings' in CLIP space (in standard deviations, with picture and text
   items centered separately), and how much more often it appears in the region's
   text (difference of arcsine-root proportions). A larger region is judged across
   its sub-regions so one part can't name the whole; with nothing in common it is
   called after its two largest parts. Names are used once, and never repeat the
   region around them. Later: an on-device or user-keyed language model proposes
   2–4 word names from each region's central thumbnails and captions. Names are
   editable and are kept across re-layouts by matching regions on membership overlap.

---

## 5. Views

### Terrain (home)
The whole archive as a topographic map. Contour lines and soft hypsometric tinting show
density; region names sit on their peaks like place names on a map. Zoom is semantic:
far out you see the largest regions; as one fills the screen its name gives way to the
names of the regions inside it, and a bar at the top shows the regions you are inside.
Names are shown or hidden, never left half-faded. Closer in the peaks resolve into
thumbnails, at the closest level you see full images. A **time scrubber** along the bottom filters the map
to a window of years and can play, so you watch ranges rise and erode.
Filters: platform, interaction type, media kind, collection.

### Made and kept
Everything you made or posted is marked on the terrain (blue dots, blue frames), with a
filter for only your work, only what you collected, or both. The interesting question is
whether you make things where you look, or somewhere else entirely.

### Process
Near-duplicate images (`poster-v1`, `v2`, `final`, the twelve screenshots of the same
layout) are grouped by perceptual hash and time into a **sequence**, shown as one item
on the map. Opening it plays the piece's evolution in order.

### Tributaries
For anything you made: the things you saved in the months before it that sit nearest to
it in taste. A map of your influences.

### Strata
Time on the horizontal axis, clusters stacked as geological layers (a streamgraph).
Layer thickness is resonance per month. Click a layer to see its items in that period;
hover a month to see a strip of what you saved then. Answers "what was I into in 2019?"

### Echoes
Themes that recur after a gap: clusters with activity in two or more periods separated
by at least 9 months of near-silence. Shown as pairs of then/now strips with the gap
between them. This is often the most revealing view.

### Palette
Items arranged by dominant color (hue around a circle, lightness inward). Your visual
taste with subject matter stripped away.

### Drift
Start anywhere; Topograph shows the item and its nearest neighbors. Pick one, keep
walking. A trail of where you've been runs along the side. For rediscovery.

### Item detail (everywhere)
Large media, caption, author, date published, *every* interaction you had with it
(liked 2018-03-02, saved to "Spaces" 2021-07-11), **Open original**, and a row of
nearest neighbors.

### Search
Type words ("foggy coastline", "hand-drawn type") and get items ranked by similarity in
the shared image-text space, even when no caption contains those words. Also search by
image: drop in a picture to find its neighbors.

---

## 6. Platform & architecture

**Target:** native macOS app (macOS 14+, Apple silicon first).

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI shell; Metal-rendered canvas for Terrain and large grids | Tens of thousands of thumbnails at 120 fps |
| Storage | SQLite via GRDB; vectors in `sqlite-vec` | One file, transactional, fast nearest-neighbor search |
| Media | `~/Library/Application Support/Topograph/Media/` sharded by hash; HEIC display copies, WebP thumbs | Compact, native decode |
| Embeddings | CLIP image and text encoders converted to Core ML | Neural Engine, no network |
| Vision | Apple Vision: OCR for screenshots and text-heavy images, feature prints for dedupe | Built in |
| Layout | UMAP port (Swift/Accelerate) or bundled Python helper in the first native builds | Proven algorithm |
| Hydration | Background `URLSession` queue + `WKWebView` signed in as the user for Instagram | Uses the user's own session, at human pace |
| Live sync | Bluesky (AT Protocol), Are.na API | Open APIs |

**Prototype (this repo, now):** a Python pipeline (`pipeline/`) plus a static web viewer
(`viewer/`) served on localhost. It proves the data handling, the model and the views on
real archives before investing in the native UI. The Python stages map one-to-one onto the
native app's stages, and the SQLite schema is shared, so the app can open a library the
prototype built.

---

## 7. Privacy & ethics

- Nothing leaves the device except requests to fetch content you already interacted with.
- Hydration uses your own session, at human pace; no scraping of anyone else's data.
- Local copies are for personal use. The app does not publish, share or upload media.
- Optional AI labeling via an external model is off by default; when enabled, only
  thumbnails and captions of the cluster being named are sent, and the app says so.
- "Forget" removes an item, its media, embedding and interactions everywhere.
- Your files are read where they are; only previews are stored. Sensitive folders and
  downloads from financial and government sites are skipped by default, and the native
  app will run on-device text recognition on screenshots to flag likely-private ones
  (messages, account pages) for review before they appear on the map.

---

## 8. Roadmap

| Milestone | Scope |
|---|---|
| **M0 — Prototype** (now) | Instagram + X import, hydration, media cache, CLIP embeddings, UMAP + clusters, web viewer with Terrain and Strata |
| **M1 — Native shell** (done, but search is by words for now) | SwiftUI app opening the prototype's library: Terrain (Metal), Strata, item detail, search |
| **M2 — Native pipeline** (partly: the app runs the Python tools) | Import, hydration (incl. signed-in web view), Core ML embeddings, in-app layout |
| **M0.5 — Facebook, your files** (now) | Facebook importer, files importer with folder review, made/kept on the map |
| **M3 — More sources** (partly: no Photos library; tested on fixtures only) | YouTube + Google Takeout, Photos library, Bluesky + Are.na live sync |
| **M4 — Depth** (done, in the Mac app) | Process sequences, Tributaries, Echoes, Palette, Drift, AI cluster names, export a region as a moodboard |
| **M5 — Watching** | The native app watches your folders (FSEvents) and adds new screenshots and downloads as they appear |

## 9. Open questions

- Should your own posts and your likes share one landscape, or be two overlaid maps
  (what you put out vs. what you take in)? Proposal: one map, with a toggle to tint by
  "made / kept."
- How should videos embed: one keyframe, or the average of several?
- What does deletion upstream mean? Proposal: keep the local copy, badge it "gone."
