# Topograph — Product Spec

> A private, on-device atlas of your online taste.

Topograph gathers everything you have posted, liked, saved and bookmarked across the
platforms you use, keeps a local copy of the visual material, and lets you explore it
as a landscape. Things you keep coming back to rise into mountain ranges; passing
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
  platform        text                -- instagram | x | youtube | google | bluesky | …
  kind            text                -- image | video | text | link | carousel
  url             text                -- canonical link to the original
  author          text  nullable
  text            text  nullable      -- caption / tweet text / title
  created_at      int   nullable      -- when the item was published (unix seconds)
  hydrated        int                 -- 0 = only a link, 1 = media/text fetched, -1 = unreachable

interaction
  item_id         text  → item.id
  type            text                -- post | reply | like | save | bookmark | comment | view | search
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
| reply / comment | 1.5 | Engaged, but often conversational |
| like | 1.0 | Cheap, frequent, still meaningful in aggregate |
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
   `min_dist≈0.05`). HDBSCAN finds clusters. A Gaussian kernel density estimate over
   the 2D points, weighted by resonance, becomes the terrain's elevation field;
   contour lines are drawn at fixed density quantiles.
6. **Label.** Each cluster gets a short name. Default: distinctive caption terms
   (TF-IDF against the whole archive). Better: an on-device or user-keyed language
   model looks at the cluster's 12 most central thumbnails and captions and proposes
   a 2–4 word name. Names are editable and are kept across re-layouts by matching
   clusters on membership overlap.

---

## 5. Views

### Terrain (home)
The whole archive as a topographic map. Contour lines and soft hypsometric tinting show
density; cluster names sit on their peaks like place names on a map. Zoom is semantic:
far out you see regions and names, closer in the peaks resolve into thumbnails, at the
closest level you see full images. A **time scrubber** along the bottom filters the map
to a window of years and can play, so you watch ranges rise and erode.
Filters: platform, interaction type, media kind, collection.

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

---

## 8. Roadmap

| Milestone | Scope |
|---|---|
| **M0 — Prototype** (now) | Instagram + X import, hydration, media cache, CLIP embeddings, UMAP + clusters, web viewer with Terrain and Strata |
| **M1 — Native shell** | SwiftUI app opening the prototype's library: Terrain (Metal), Strata, item detail, search |
| **M2 — Native pipeline** | Import, hydration (incl. signed-in web view), Core ML embeddings, in-app layout |
| **M3 — More sources** | YouTube + Google Takeout, Bluesky + Are.na live sync |
| **M4 — Depth** | Echoes, Palette, Drift, AI cluster names, collections, export a region as a moodboard |

## 9. Open questions

- Should your own posts and your likes share one landscape, or be two overlaid maps
  (what you put out vs. what you take in)? Proposal: one map, with a toggle to tint by
  "made / kept."
- How should videos embed: one keyframe, or the average of several?
- What does deletion upstream mean? Proposal: keep the local copy, badge it "gone."
