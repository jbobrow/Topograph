# How the map is made

This explains how Topograph turns about 58,000 posts, likes, saves and files into one
terrain: where each item sits, how regions are found and named, and where the hills come
from. It then covers what the map can and can't tell you, how it compares with t-SNE, and
other ways it could be done.

The code is in `pipeline/topograph/`: `embed.py`, `maps.py`, `layout.py`, `regions.py`, and
the terrain in `viewer/app.js`. The Swift port in `mac/TopographCore/Sources/TopographCore/Pipeline/Layout/`
follows the same steps. Where this file and the code disagree, the code is right.

## The short version

1. **Every item becomes a list of numbers** (a vector) that describes what it looks like and
   what it says. Similar items get similar vectors.
2. **A map recipe adjusts those vectors** so that subject counts for more than medium, and
   so your files sit beside posts about the same things.
3. **UMAP flattens them onto a page.** It keeps each item next to its closest neighbors and
   doesn't try to keep far-apart things at a true distance.
4. **HDBSCAN finds dense patches on the page** (the fine regions), and **Ward linkage nests
   them** into larger regions, about 7 at the top.
5. **Each region gets the name that best separates it from its siblings**, judged on both
   pictures and words.
6. **The terrain is a smoothed count of items, weighted by resonance.** Areas packed with
   things you saved and bookmarked rise into peaks.

```
items ─► vectors ─► map recipe ─► UMAP (2D) ─► fit to 1000×1000
          (CLIP,     (pictures /       │
           MiniLM)    words /          ├─► HDBSCAN ─► fine regions ─► Ward nesting ─► names
                      blended)         │
                         │             └─► resonance-weighted density ─► terrain contours
                         └─► 8 nearest neighbors (in the full vectors, not on the page)
```

## 1. Vectors

Each item gets one 512-number vector from CLIP (OpenCLIP ViT-B/32, LAION-2B weights). CLIP
was trained to put a picture and a caption that describes it close together, so one space
holds both kinds of thing.

- **An item with pictures:** up to 4 images are embedded and averaged, then blended 75 / 25
  with the first 300 characters of its caption.
- **An item with only text:** its text is embedded.
- All vectors are scaled to length 1, so the similarity of two items is just their dot
  product (cosine similarity).

The words and blended maps also use a small text model, MiniLM-L6 (384 numbers per item).
CLIP reads text, but it was built to match captions to pictures. MiniLM was built to tell
what a sentence is about.

## 2. Map recipes (`maps.py`)

The same items can be arranged three ways. Each is stored under its own name in the
`layout` and `cluster` tables, and the CLIP vectors themselves never change, so search,
region names and Tributaries work the same on all of them.

**Pictures** uses the CLIP vectors as they are. Things group mostly by how they look.

**Words** fixes two problems with pictures:

- *CLIP's modality gap.* In CLIP's space all images sit in one area and all text in
  another (Liang et al., 2022, "Mind the Gap"). Left alone, the map would split first into
  "has a picture" and "doesn't", whatever the subject. So the average picture vector is
  subtracted from every picture item, and the average text vector from every text item.
- *Subject.* The MiniLM vector is appended to the CLIP one, scaled by how much text the item
  has: nothing for one word, rising to full weight at 20 words, and at most 0.6 for a file
  name, since a file name says less than a sentence. Then the whole thing is scaled back to
  length 1. The similarity of two items is then, roughly, their CLIP similarity plus their
  text similarity times both items' text weights.

**Blended**, the suggested map, starts from words and then moves your files toward posts
about the same thing. Without this step your files form their own islands, because a CAD
render or a screenshot looks unlike anything anyone posts. It works like this:

1. Find file-post pairs that are *mutual* nearest neighbors: each is among the other's 20
   closest. These pairs are taken to be about the same thing.
2. For each file in such a pair, note the average offset from it to its partners.
3. Move every file by a weighted average of the offsets of the 50 paired files nearest to it,
   with closer ones counting much more.

Posts don't move. What your files share with posts lines up with them, and what only your
files have (a project nobody else posts about) keeps its shape instead of being pushed onto
something unrelated. This is the same idea as mutual-nearest-neighbor batch correction in
single-cell biology (Haghverdi et al., 2018), where two labs' measurements of the same cell
types are lined up.

## 3. Flattening: UMAP (`layout.py:project`)

UMAP (McInnes, Healy & Melville, 2018) takes the high-dimensional vectors and gives each
item an `x, y` position. It works in two stages.

**Build a neighbor graph.** For each item, find its 30 nearest neighbors by cosine distance.
Each item gets its own sense of scale: the nearest neighbor counts fully, and further ones
count less, at a rate chosen so the weights add up to log2(30). Items in a crowded part of
the space and items in a sparse part each end up with about the same amount of
"neighborliness". The links from both sides are combined into one symmetric graph.

**Lay the graph out in 2D.** Start from a spectral layout of the graph, then repeatedly
pull linked items together and push random pairs apart (negative sampling). How strongly two
points count as "close" at distance `d` on the page is `1 / (1 + a·d^(2b))`. `min_dist = 0.05`
sets `a ≈ 1.75, b ≈ 0.84`, which lets items in a group pack tightly.

Settings: `n_neighbors=30`, `min_dist=0.05`, `metric="cosine"`, `random_state=42`. With fewer
than 16 items, PCA is used instead.

The result is centered and scaled so its longer side spans 900 units of a 1000 × 1000
square. The aspect ratio is kept, because distances on the page mean something.

**Python and Swift.** The Swift port (`UMAP.swift`) finds neighbors exactly where
`umap-learn` approximates them, and uses different random numbers. A Swift map is a
different picture of the same structure: the same vectors always give the same Swift map,
and given the same positions both sides find the same regions and names.

## 4. Regions (`layout.py:cluster`, `regions.py:build_tree`)

**Fine regions.** HDBSCAN looks for patches of the page that are denser than their
surroundings, at whatever density each patch has. It runs on the 2D positions, not on the
original vectors, so regions match what you see. Settings: smallest region
`max(12, n / 350)` items (about 165 on the real library), `min_samples` a third of that,
and leaf selection, which favors many small regions over a few big ones. HDBSCAN leaves some
points as "noise". Each noise point joins its nearest region unless it is far from everything
(more than twice the 75th percentile of those distances).

**Nesting.** The fine regions' centers are merged step by step with Ward linkage, which
joins whichever two groups make the smallest increase in spread. The tree is cut at about
7, 21, 63 … regions (about three children each) down to the fine regions, so every region
sits inside one parent. The viewer shows the top regions when zoomed out and swaps in
their children as you zoom in.

## 5. Names (`regions.py:name_tree`)

A region is named by the phrase that best tells it apart from its *siblings*, the other
regions under the same parent. That is why one region can be "orchids" and a part of it
"purple orchids": each name only has to distinguish, not describe everything.

- **Candidates:** the vocabulary in `concepts.txt`, plus 1–3 word phrases and hashtags that
  recur in your own captions and file and folder names (not too rare, not in more than 12%
  of items).
- **Picture evidence:** how much better the phrase's CLIP vector matches the region's items
  than the siblings' items, in standard deviations, so phrases that match everything a bit
  don't win everywhere. Small regions' scores are shrunk, since a handful of near-duplicates
  can fit many phrases. Phrases taken from your own text are judged on pictures only.
- **Word evidence:** how much more often the phrase appears in the region's text than in its
  siblings' (a difference of arcsine-square-root proportions, which treats rare and common
  phrases fairly).
- **Balance by depth:** broad regions lean on pictures, small ones on specific words such as
  project names.
- **Rules:** a larger region's name must fit all its parts, not just the biggest. No name is
  used twice, and no region repeats the name around it. A region with nothing in common is
  called after its two largest parts ("type + posters").

## 6. Neighbors and terrain

**Neighbors** (the "nearby" list for an item) are the 8 closest items by cosine in the map's
full vectors, not on the page. They are more trustworthy than what happens to be beside an
item on screen.

**Terrain** is d3's `contourDensity` over the 2D positions (cell 4, bandwidth 16, in map
units), with each item weighted by its resonance: the sum of `INTERACTION_WEIGHTS` over the
kinds of interaction it has (a bookmark 3, a like 1, a file you made 2.5). There are 13 contour
levels, spaced geometrically from 2.5% to 92% of the full map's highest point. A filtered map,
such as one moment on the Strata timeline, keeps the full map's levels, so heights can be
compared across time. `DensityField.swift` is a port of the same thing.

## What the map tells you, and what it doesn't

UMAP keeps neighborhoods and gives up on the rest. In practice:

- **Trust:** what is next to what at close range; that a tight patch is a real group; the
  region tree; the neighbor list.
- **Don't trust:** distances between far-apart regions (two islands at opposite corners
  aren't necessarily less related than two that are closer); the axes (there is no "up
  means more X"); how big a region looks. A diffuse interest and a tight one can come out
  the same size.
- **Density is partly made by UMAP.** Because every item gets the same amount of
  neighborliness, UMAP tends to even out density: a loose, varied interest gets packed about
  as tightly as a group of near-identical images. The terrain's height is therefore mostly
  *how many items there are × how much you engaged with them*. It isn't how varied they are.
- **It is one of many possible pictures.** A different seed, more items, or the Swift port
  gives a different arrangement of the same neighborhoods. Region numbers come from each
  layout, which is why region names are cleared by a re-layout today.

## Is this like t-SNE?

Yes, closely. t-SNE (van der Maaten & Hinton, 2008) and UMAP belong to the same family.
Both:

- start from each item's nearest neighbors in the high-dimensional space;
- give each item its own scale, so crowded and sparse areas are treated alike (t-SNE's
  *perplexity* plays the role of UMAP's `n_neighbors`; perplexity 30 is the usual default,
  roughly comparable to 30–90 neighbors);
- place points in 2D so that neighbors stay together, with a heavy-tailed similarity curve
  that lets separate groups drift well apart. t-SNE's curve is `1 / (1 + d²)`. UMAP's is
  `1 / (1 + a·d^(2b))`, which with `a = b = 1` is the same curve.

They differ in how they get there:

| | t-SNE | UMAP (what we use) |
|---|---|---|
| What it optimizes | Match two probability distributions (KL divergence), normalized over all pairs | Match two fuzzy graphs (cross-entropy), edge by edge, with sampled repulsion |
| Speed at 58k items | Practical with FIt-SNE / openTSNE; very slow with the classic version | Usually faster than either |
| Global arrangement | Historically poor; much better with PCA initialization and the newer tools | Somewhat better, mostly thanks to its spectral starting layout |
| Packing | Fills space evenly, groups often look like round blobs | `min_dist` lets groups pack tightly with gaps between, which suits terrain |
| Adding new items | openTSNE can place new points against a fixed map | Can place new points (`transform`); parametric UMAP learns a function |
| Distances between clusters | Not meaningful | Not meaningful either, though slightly less wrong |

Research since then (Kobak & Linderman, 2021; Böhm, Berens & Kobak, 2022) has shown the two
are closer than they first seemed: much of UMAP's better global layout comes from its
initialization, and UMAP behaves like t-SNE with stronger attraction. Either would draw a
believable Topograph. UMAP was picked for speed, tight packing and being easy to port.

## Alternative approaches

Grouped by step, roughly in order of how much each could change the map. None of these
has been tried on the real library. Synthetic tests have misled tuning before, so any
change should be judged by eye on the real map first.

### Flattening

- **t-SNE (openTSNE).** The closest swap. Groups often come out rounder and more evenly
  spread, and big continents break up more. Worth seeing side by side, not obviously better.
- **PaCMAP / TriMap.** Newer methods that also keep some mid-range and far-range pairs,
  aiming for a more truthful arrangement of regions relative to each other. A good candidate
  if "what's next to what" at the continent scale starts to matter.
- **densMAP** (`umap.UMAP(densmap=True)`). UMAP with an added term that keeps local spread:
  varied interests come out wide, tight ones small. The terrain would then show how varied
  an interest is as well as how big. This speaks directly to the density caveat above.
- **Starting from the previous map** (`init=` the old positions, or `AlignedUMAP`). New
  items settle among old ones instead of the whole map being redrawn. That gives stable
  geography as the library grows, and region names could survive a re-layout.
- **Parametric UMAP.** A small network learns the mapping from vectors to positions, so new
  items can be placed without a re-layout, and the native app could run it as one Core ML
  model. The cost: training, and a more involved port.
- **Force-directed layout of the neighbor graph** (ForceAtlas2, as in Gephi). Simpler and
  easy to animate, but slower and messier at this size.
- **Grid layouts** (self-organizing maps, or snapping a UMAP layout to a grid with
  linear assignment). Each item gets a cell, so thumbnails never overlap. Good for a
  contact-sheet view, but density, and with it the terrain, disappears.
- **PCA.** Fast, stable and linear, so the axes mean something, but with 512 dimensions
  everything lands in one mushy cloud. Useful only for very small libraries, where we
  already use it.

### Regions

- **Cluster in more dimensions.** A common pattern (BERTopic, for example) is to run UMAP
  a second time to about 10 dimensions and run HDBSCAN on that. Regions follow the data more
  closely and depend less on 2D's packing. The cost: regions may no longer be patches on the
  page. One would need to check how often a region is split in two on screen.
- **Leiden communities on the neighbor graph**, the standard in single-cell biology. It has a
  resolution setting that gives nested levels directly, and it doesn't depend on the page at
  all. The same caution about split patches applies.
- **Matching regions across re-layouts** by membership overlap (planned in SPEC §5), so
  names and edits carry over whatever method is used.

### Terrain

- **Average engagement instead of total.** Today's height mixes how many items there are and
  how much you engaged with them. Dividing the weighted density by the plain density gives
  the average resonance per area: a small cluster of things you saved would rise as high as
  a large field of likes. The two could be offered as separate shadings.
- **A kernel that adapts to density**, so sparse outskirts don't break up into dots.

### Vectors and names

- **A newer image-text model** (SigLIP, larger CLIPs) would likely group things better. It
  must be ported to Core ML with matching output, and every vector re-embedded.
- **c-TF-IDF** (BERTopic's naming) is a simpler word-only alternative to the current naming.
  It would lose the picture evidence that names image-only regions.
- **A language model proposing names** from each region's central thumbnails and captions is
  already planned. It must be off by default and say what it sends, unless it runs on the
  device.

### What to try first

1. **Starting from the previous map.** It is cheap, keeps geography and names stable, and the
   app already suffers from the problem it fixes.
2. **densMAP on the blended map**, compared by eye with today's terrain.
3. **Clustering in ~10 dimensions**, only if regions on the real map look wrong. They mostly
   look right today, so this is the least urgent of the three.

## References

- McInnes, Healy & Melville (2018). *UMAP: Uniform Manifold Approximation and Projection.*
- van der Maaten & Hinton (2008). *Visualizing Data using t-SNE.*
- Kobak & Linderman (2021). *Initialization is critical for preserving global data structure in both t-SNE and UMAP.*
- Böhm, Berens & Kobak (2022). *Attraction-repulsion spectrum in neighbor embeddings.*
- Narayan, Berger & Cho (2021). *Assessing single-cell transcriptomic variability through density-preserving data visualization* (densMAP).
- Wang, Huang, Rudin & Shaposhnik (2021). *Understanding how dimension reduction tools work* (PaCMAP).
- Campello, Moulavi & Sander (2013). *Density-based clustering based on hierarchical density estimates* (HDBSCAN).
- Haghverdi, Lun, Morgan & Marioni (2018). *Batch effects in single-cell RNA-sequencing data are corrected by matching mutual nearest neighbors.*
- Liang et al. (2022). *Mind the Gap: Understanding the modality gap in multi-modal contrastive representation learning.*
- Grootendorst (2022). *BERTopic: Neural topic modeling with a class-based TF-IDF procedure.*
