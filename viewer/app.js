/* Topograph viewer: Terrain (a density map of your taste) and Strata (its layers over time). */
(async function () {
  "use strict";

  // ---------------------------------------------------------------- data
  let DATA;
  try {
    const res = await fetch("/library/topograph.json", { cache: "no-store" });
    DATA = await res.json();
  } catch (e) {
    DATA = null;
  }
  if (!DATA || !DATA.items || !DATA.items.length) {
    document.getElementById("empty").hidden = false;
    return;
  }

  const MEDIA = (p) => "/library/" + p;
  const PLATFORM_NAMES = { instagram: "Instagram", x: "X", facebook: "Facebook", files: "Your files", youtube: "YouTube", google: "Google", bluesky: "Bluesky" };
  const GROUPS = [
    { key: "made", label: "Made or posted", types: ["post", "repost", "reply", "comment", "made", "capture"] },
    { key: "liked", label: "Liked", types: ["like", "react"] },
    { key: "kept", label: "Saved", types: ["save", "bookmark", "download"] },
  ];
  const VERBS = { post: "Posted", repost: "Reposted", reply: "Replied", comment: "Commented",
                  like: "Liked", save: "Saved", bookmark: "Bookmarked", view: "Watched", search: "Searched",
                  made: "Made", capture: "Took this screenshot", download: "Downloaded", open: "Opened",
                  react: "Reacted" };
  const MINE = new Set(["post", "repost", "reply", "comment", "made", "capture"]);

  const items = DATA.items;
  items.forEach((d, i) => {
    d.i = i;
    d.time = d.at || d.ts || null;
    d.types = new Set(d.ix.map((x) => x[0]));
    d.search = ((d.t || "") + " @" + (d.a || "")).toLowerCase();
    d.mine = d.ix.some((x) => MINE.has(x[0]));
  });
  // Regions nest: large ones when zoomed out, the ones inside them as you zoom in.
  // Each item belongs to its finest region (d.c); `members` includes everything inside.
  const clusters = new Map(DATA.clusters.map((c) => [c.id, c]));
  for (const c of clusters.values()) { c.children = []; c.own = []; }
  for (const c of clusters.values()) {
    const p = c.parent != null ? clusters.get(c.parent) : null;
    if (p) p.children.push(c); else c.parent = null;
  }
  for (const d of items) { const c = clusters.get(d.c); if (c) c.own.push(d); }
  const roots = [...clusters.values()].filter((c) => c.parent == null);
  (function settle(list, path) {
    for (const c of list) {
      c.path = [...path, c];
      c.depth = path.length;
      settle(c.children, c.path);
      c.members = c.own.concat(...c.children.map((k) => k.members));
      c.n = c.members.length;
      if (c.x == null || c.r == null) {   // maps built before regions nested
        const mx = d3.median(c.members, (d) => d.x), my = d3.median(c.members, (d) => d.y);
        const a = d3.least(c.members, (d) => (d.x - mx) ** 2 + (d.y - my) ** 2);
        c.x = a ? a.x : 500; c.y = a ? a.y : 500;
        const cx = d3.mean(c.members, (d) => d.x), cy = d3.mean(c.members, (d) => d.y);
        c.r = Math.max(4, Math.sqrt(d3.mean(c.members, (d) => (d.x - cx) ** 2 + (d.y - cy) ** 2) || 16));
      }
      c.cx = c.x; c.cy = c.y;
    }
  })(roots, []);
  for (const c of clusters.values()) c.children.sort((a, b) => b.n - a.n);
  roots.sort((a, b) => b.n - a.n);
  const regionOf = (d) => clusters.get(d.c) || null;

  const groupsPresent = GROUPS.filter((g) => items.some((d) => g.types.some((t) => d.types.has(t))));
  const platformsPresent = [...new Set(items.map((d) => d.p))];

  const state = {
    view: "terrain",
    platforms: new Set(platformsPresent),
    groups: new Set(groupsPresent.map((g) => g.key)),
    query: "",
    range: null, // [Date, Date] or null for all time
    selected: null,
  };

  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const fmtMonth = d3.timeFormat("%b %Y");
  const fmtStamp = d3.timeFormat("%Y.%m");
  const fmtDay = d3.timeFormat("%-d %b %Y");
  const toDate = (s) => new Date(s * 1000);

  function isVisible(d) {
    if (!state.platforms.has(d.p)) return false;
    let ok = false;
    for (const g of groupsPresent) {
      if (state.groups.has(g.key) && g.types.some((t) => d.types.has(t))) { ok = true; break; }
    }
    if (!ok) return false;
    if (state.query && !d.search.includes(state.query)) return false;
    if (state.range) {
      if (!d.time) return false;
      const t = d.time * 1000;
      if (t < +state.range[0] || t > +state.range[1]) return false;
    }
    return true;
  }
  let visible = items.filter(isVisible);

  // ---------------------------------------------------------------- filters UI
  function chip(container, label, pressed, onToggle) {
    const b = document.createElement("button");
    b.className = "key";
    const led = document.createElement("span");
    led.className = "led";
    led.setAttribute("aria-hidden", "true");
    b.append(led, label);
    b.setAttribute("aria-pressed", String(pressed));
    b.addEventListener("click", () => {
      const now = b.getAttribute("aria-pressed") !== "true";
      b.setAttribute("aria-pressed", String(now));
      onToggle(now);
    });
    container.appendChild(b);
  }
  const platEl = document.getElementById("platforms");
  if (platformsPresent.length > 1) {
    platformsPresent.forEach((p) => chip(platEl, PLATFORM_NAMES[p] || p, true, (on) => {
      on ? state.platforms.add(p) : state.platforms.delete(p);
      update();
    }));
  }
  const actEl = document.getElementById("actions");
  if (groupsPresent.length > 1) {
    groupsPresent.forEach((g) => chip(actEl, g.label, true, (on) => {
      on ? state.groups.add(g.key) : state.groups.delete(g.key);
      update();
    }));
  }
  // Images: color, gray, or 1-bit dither. The canvas copies are made on demand.
  let imageMode = "gray";
  try { imageMode = localStorage.getItem("topograph.images") || "gray"; } catch (e) { /* private window */ }
  function setImageMode(mode) {
    imageMode = mode;
    document.body.dataset.images = mode;
    document.querySelectorAll("#image-mode .key").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.mode === mode)));
    try { localStorage.setItem("topograph.images", mode); } catch (e) { /* ignore */ }
    if (state.selected) openItem(state.selected);
    requestDraw();
  }
  document.querySelectorAll("#image-mode .key").forEach((b) => b.addEventListener("click", () => setImageMode(b.dataset.mode)));

  let qTimer;
  document.getElementById("query").addEventListener("input", (e) => {
    clearTimeout(qTimer);
    qTimer = setTimeout(() => { state.query = e.target.value.trim().toLowerCase(); update(); }, 150);
  });

  document.querySelectorAll("[data-view]").forEach((b) => b.addEventListener("click", () => setView(b.dataset.view)));
  function setView(v) {
    state.view = v;
    document.querySelectorAll("[data-view]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.view === v)));
    document.getElementById("terrain").hidden = v !== "terrain";
    document.getElementById("strata").hidden = v !== "strata";
    if (v === "terrain") { resizeMap(); } else { drawStrata(); }
  }

  // ---------------------------------------------------------------- terrain
  const canvas = document.getElementById("map");
  const ctx = canvas.getContext("2d");
  let W = 0, H = 0, DPR = 1;
  let transform = d3.zoomIdentity;

  const density = d3.contourDensity()
    .x((d) => d.x).y((d) => d.y).weight((d) => d.r || 1)
    .size([1000, 1000]).cellSize(4).bandwidth(16);
  const fullDensity = density.contours(items);
  const LEVELS = 13;
  const THRESHOLDS = d3.range(LEVELS).map((i) => fullDensity.max * 0.025 * Math.pow(0.92 / 0.025, i / (LEVELS - 1)));
  let contours = [], contoursVersion = 0;
  function computeContours() {
    const fn = visible.length ? density.contours(visible) : null;
    contours = fn ? THRESHOLDS.map((t) => fn(t)) : [];
    contoursVersion++;
  }

  let quadtree;
  function buildQuadtree() {
    quadtree = d3.quadtree().x((d) => d.x).y((d) => d.y).addAll(visible);
  }

  const zoom = d3.zoom().scaleExtent([0.3, 80])
    .on("start", () => canvas.classList.add("dragging"))
    .on("end", () => canvas.classList.remove("dragging"))
    .on("zoom", (e) => { transform = e.transform; requestDraw(); hideTip(); });
  d3.select(canvas).call(zoom).on("dblclick.zoom", null);

  function fitTransform(pad = 40) {
    const k = Math.min((W - pad * 2) / 1000, (H - pad * 2) / 1000);
    return d3.zoomIdentity.translate((W - 1000 * k) / 2, (H - 1000 * k) / 2).scale(k);
  }
  function resizeMap() {
    const r = canvas.getBoundingClientRect();
    if (!r.width) return;
    const first = W === 0;
    W = r.width; H = r.height; DPR = window.devicePixelRatio || 1;
    canvas.width = Math.round(W * DPR); canvas.height = Math.round(H * DPR);
    if (first) d3.select(canvas).call(zoom.transform, fitTransform());
    requestDraw();
  }
  document.getElementById("zoom-in").onclick = () => d3.select(canvas).transition().duration(250).call(zoom.scaleBy, 1.8);
  document.getElementById("zoom-out").onclick = () => d3.select(canvas).transition().duration(250).call(zoom.scaleBy, 1 / 1.8);
  document.getElementById("zoom-fit").onclick = () => d3.select(canvas).transition().duration(400).call(zoom.transform, fitTransform());

  function flyTo(x, y, k) {
    const t = d3.zoomIdentity.translate(W / 2 - x * k, H / 2 - y * k).scale(k);
    d3.select(canvas).transition().duration(600).call(zoom.transform, t);
  }

  // Thumbnails load lazily and are kept in a bounded cache, with gray and
  // 1-bit copies made the first time each mode needs them.
  const images = new Map();

  const TIERS = [96, 192, 320];
  function thumb(d, screenPx = 320) {
    let e = images.get(d.id);
    if (!e) {
      const img = new Image();
      e = { img, ok: false };
      // decode() happens off the main thread; drawing an undecoded image would
      // decode it synchronously, ~25 ms each, and stall the map.
      img.src = MEDIA(d.th);
      img.decode().then(() => { e.ok = true; requestDraw(); }, () => { e.failed = true; });
      images.set(d.id, e);
      if (images.size > 2500) images.delete(images.keys().next().value);
    }
    if (!e.ok) return null;
    if (imageMode === "color") return e.img;
    // Convert at the size it is drawn (in three steps), for up to ~12 ms per
    // frame; until a sharper copy is ready, any smaller one stands in.
    const want = TIERS.find((t) => t >= screenPx * DPR) || TIERS[TIERS.length - 1];
    const key = imageMode + want;
    if (e[key]) return e[key];
    if (!convertQueue.has(key + d.id)) convertQueue.set(key + d.id, { e, mode: imageMode, tier: want, key });
    if (!pumping) { pumping = true; setTimeout(pump, 0); }
    for (const t of TIERS) if (e[imageMode + t]) return e[imageMode + t];
    return null;
  }

  // Conversions run in their own short bursts between frames, newest requests
  // first, so a slow map frame never holds them up.
  const convertQueue = new Map();
  let pumping = false;
  function pump() {
    const stop = performance.now() + 14;
    let done = 0;
    const jobs = [...convertQueue.entries()].reverse();
    for (const [id, job] of jobs) {
      if (performance.now() > stop) break;
      convertQueue.delete(id);
      if (job.mode !== imageMode || job.e[job.key]) continue;
      job.e[job.key] = processImage(job.e.img, job.mode, job.tier);
      done++;
    }
    if (done) requestDraw();
    if (convertQueue.size) setTimeout(pump, 0); else pumping = false;
  }

  const rgbCache = {};
  function themeRgb(name) {
    if (!rgbCache[name]) { const c = d3.color(css(name)) || d3.color("#000"); rgbCache[name] = [c.r, c.g, c.b]; }
    return rgbCache[name];
  }
  // Gray, or 1-bit with Atkinson dithering (in the current ink and ground).
  function processImage(img, mode, maxEdge) {
    const scale = Math.min(1, maxEdge / Math.max(img.naturalWidth, img.naturalHeight));
    const w = Math.max(1, Math.round(img.naturalWidth * scale)), h = Math.max(1, Math.round(img.naturalHeight * scale));
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    const x = c.getContext("2d", { willReadFrequently: true });
    x.drawImage(img, 0, 0, w, h);
    const im = x.getImageData(0, 0, w, h), px = im.data;
    const lum = new Float32Array(w * h);
    for (let i = 0; i < w * h; i++) lum[i] = 0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2];
    // Map luminance onto the theme's own dark→light ramp, so images stay positive in dark mode.
    const ink = themeRgb("--ink"), bg = themeRgb("--surface");
    const [lo, hi] = ink[0] + ink[1] + ink[2] < bg[0] + bg[1] + bg[2] ? [ink, bg] : [bg, ink];
    if (mode === "dither") {
      const spread = [[1, 0], [2, 0], [-1, 1], [0, 1], [1, 1], [0, 2]];
      for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++) {
        const i = yy * w + xx, old = lum[i], v = old < 128 ? 0 : 255, err = (old - v) / 8;
        lum[i] = v;
        for (const [dx, dy] of spread) {
          const nx = xx + dx, ny = yy + dy;
          if (nx >= 0 && nx < w && ny < h) lum[ny * w + nx] += err;
        }
      }
    }
    for (let i = 0; i < w * h; i++) {
      const t = Math.min(1, Math.max(0, lum[i] / 255));
      px[i * 4] = lo[0] + (hi[0] - lo[0]) * t;
      px[i * 4 + 1] = lo[1] + (hi[1] - lo[1]) * t;
      px[i * 4 + 2] = lo[2] + (hi[2] - lo[2]) * t;
    }
    x.putImageData(im, 0, 0);
    return c;
  }
  function clearProcessed() {
    for (const e of images.values()) for (const m of ["gray", "dither"]) for (const t of TIERS) delete e[m + t];
  }

  // Ordered (Bayer) dither patterns: one density per elevation band, drawn in
  // screen pixels so the dots stay crisp at any zoom.
  const BAYER = (() => {
    let m = [[0]];
    for (let n = 0; n < 3; n++) {
      const s = m.length, out = [];
      for (let y = 0; y < s * 2; y++) out.push(new Array(s * 2));
      for (let y = 0; y < s; y++) for (let x = 0; x < s; x++) {
        const v = m[y][x] * 4;
        out[y][x] = v; out[y][x + s] = v + 2; out[y + s][x] = v + 3; out[y + s][x + s] = v + 1;
      }
      m = out;
    }
    return m; // 8x8, values 0..63
  })();
  let ditherCache = null;
  function ditherPatterns() {
    const key = css("--ink") + DPR;
    if (ditherCache && ditherCache.key === key) return ditherCache.list;
    const ink = css("--ink");
    const list = d3.range(LEVELS).map((i) => {
      // Capped well below solid so thumbnails and labels stay readable on the peaks.
      const density = 0.03 + 0.31 * Math.pow(i / (LEVELS - 1), 1.3);
      const c = document.createElement("canvas");
      c.width = 8; c.height = 8;
      const x = c.getContext("2d");
      x.fillStyle = ink;
      for (let yy = 0; yy < 8; yy++) for (let xx = 0; xx < 8; xx++) {
        if (BAYER[yy][xx] < density * 64) x.fillRect(xx, yy, 1, 1);
      }
      return tctx.createPattern(c, "repeat");
    });
    ditherCache = { key, list };
    return list;
  }

  let drawPending = false;
  function requestDraw() {
    if (drawPending) return;
    drawPending = true;
    requestAnimationFrame(() => { drawPending = false; drawMap(); });
  }

  const terrainCanvas = document.createElement("canvas");
  const tctx = terrainCanvas.getContext("2d");
  let terrainKey = "";
  function renderTerrain(k, bg, ink, hair) {
    if (terrainCanvas.width !== canvas.width || terrainCanvas.height !== canvas.height) {
      terrainCanvas.width = canvas.width; terrainCanvas.height = canvas.height;
    }
    const t = tctx;
    t.setTransform(DPR, 0, 0, DPR, 0, 0);
    t.fillStyle = bg;
    t.fillRect(0, 0, W, H);
    // Instrument grid, fixed to the screen.
    t.fillStyle = hair;
    for (let gx = 12; gx < W; gx += 24) for (let gy = 12; gy < H; gy += 24) t.fillRect(gx, gy, 1, 1);
    t.save();
    t.translate(transform.x, transform.y);
    t.scale(k, k);
    const path = d3.geoPath(null, t);
    // Elevation as dither density, then contour lines; every fourth is an index contour.
    const pats = ditherPatterns();
    const toScreen = t.getTransform().inverse().multiply(new DOMMatrix().scale(DPR));
    contours.forEach((c, i) => {
      const pat = pats[i];
      pat.setTransform(toScreen);
      t.beginPath(); path(c);
      t.fillStyle = pat;
      t.fill();
    });
    t.strokeStyle = ink;
    contours.forEach((c, i) => {
      t.beginPath(); path(c);
      const index = i % 4 === 3;
      t.globalAlpha = index ? 0.9 : 0.45;
      t.lineWidth = (index ? 1.1 : 0.5) / k;
      t.stroke();
    });
    t.restore();
  }

  // ---------------------------------------------------------------- region names
  // Which regions are named depends on zoom: a region hands over to the regions
  // inside it once it is large on screen, and the finest regions step aside once
  // you are well inside them. A name is either shown or not; changes take a
  // short fade, never a half-visible resting state.
  let labelBoxes = [];
  const expanded = new Set();
  const labelAlpha = new Map();
  let lastLabelFrame = 0, labelsMoving = false;
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let regionCount = new Map(), regionCountFor = null;
  function countRegions() {
    if (regionCountFor === visible) return regionCount;
    regionCount = new Map();
    for (const d of visible) {
      const c = clusters.get(d.c);
      if (c) for (const a of c.path) regionCount.set(a.id, (regionCount.get(a.id) || 0) + 1);
    }
    regionCountFor = visible;
    return regionCount;
  }
  const expandAt = () => Math.min(W, H) * 0.3;     // a region this large (rms radius, px) opens up
  const pastAt = () => Math.max(W, H) * 0.75;      // a finest region this large: you're inside it

  function namedRegions(k) {
    const counts = countRegions();
    const T = expandAt(), PAST = pastAt();
    const out = [];
    const visit = (c) => {
      if (!counts.get(c.id)) return;
      const [sx, sy] = transform.apply([c.x, c.y]);
      const size = c.r * k, reach = size * 3 + 120;
      if (sx + reach < 0 || sx - reach > W || sy + reach < 0 || sy - reach > H) return;
      const limit = c.children.length ? T : PAST;
      // A little hysteresis so a name doesn't flicker at the threshold.
      const open = expanded.has(c.id) ? size > limit * 0.85 : size > limit;
      if (open) expanded.add(c.id); else expanded.delete(c.id);
      if (!open) out.push(c);
      else c.children.forEach(visit);
    };
    roots.forEach(visit);
    return out;
  }

  function drawLabels(k, surface, ink, ink2) {
    const counts = countRegions();
    const mono = css("--mono");
    const now = performance.now();
    // Fades run on the clock, not on frame count, so a slow frame never leaves a
    // name half-visible for long; the first step after a pause is one frame's worth.
    const dt = labelsMoving ? Math.min(now - lastLabelFrame, 140) : 16;
    lastLabelFrame = now;
    const step = reduceMotion.matches ? 1 : Math.min(1, dt / 140);

    const geometry = (c) => {
      const [sx, sy] = transform.apply([c.x, c.y]);
      const top = c.depth === 0;
      const fs = top ? 12 : 11;
      const count = (counts.get(c.id) || 0).toLocaleString();
      ctx.font = `${top ? 600 : 500} ${fs}px ${mono}`;
      const tw = ctx.measureText(c.label).width;
      ctx.font = `400 10px ${mono}`;
      const cw = ctx.measureText(count).width;
      const lx = sx + 8, total = tw + 6 + cw;
      return { c, sx, sy, fs, top, count, tw, lx, total,
        box: [sx - 5, sy - fs / 2 - 3, lx + total + 4, sy + fs / 2 + 3] };
    };

    // Bigger regions claim their spot first; a name that would overlap is hidden.
    labelBoxes = [];
    const shown = new Map();
    const wanted = namedRegions(k).sort((a, b) => a.depth - b.depth || b.n - a.n);
    for (const c of wanted) {
      const g = geometry(c);
      const [x0, y0, x1, y1] = g.box;
      if (x1 < 0 || x0 > W || y1 < 0 || y0 > H) continue;
      if (labelBoxes.some((b) => !(x1 < b[0] || x0 > b[2] || y1 < b[1] || y0 > b[3]))) continue;
      labelBoxes.push(Object.assign(g.box.slice(), { cluster: c }));
      shown.set(c.id, g);
    }
    for (const id of shown.keys()) if (!labelAlpha.has(id)) labelAlpha.set(id, 0);
    let moving = false;
    const draw = [];
    for (const [id, a0] of labelAlpha) {
      const target = shown.has(id) ? 1 : 0;
      const a = target === a0 ? a0 : target > a0 ? Math.min(1, a0 + step) : Math.max(0, a0 - step);
      if (a <= 0 && !target) { labelAlpha.delete(id); continue; }
      labelAlpha.set(id, a);
      if (a !== target) moving = true;
      draw.push([shown.get(id) || geometry(clusters.get(id)), a]);
    }
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";
    for (const [g, a] of draw) {
      const { c, sx, sy, fs, top, count, tw, lx, total } = g;
      ctx.globalAlpha = a;
      ctx.fillStyle = top ? ink : surface;
      ctx.fillRect(lx - 3, sy - fs / 2 - 3, total + 7, fs + 6);
      ctx.strokeStyle = ink; ctx.lineWidth = 1;
      ctx.strokeRect(Math.round(lx - 3) + 0.5, Math.round(sy - fs / 2 - 3) + 0.5, Math.round(total + 7), Math.round(fs + 6));
      ctx.beginPath();
      ctx.moveTo(sx - 4, sy); ctx.lineTo(sx + 4, sy); ctx.moveTo(sx, sy - 4); ctx.lineTo(sx, sy + 4);
      ctx.stroke();
      ctx.fillStyle = top ? surface : ink;
      ctx.font = `${top ? 600 : 500} ${fs}px ${mono}`;
      ctx.fillText(c.label, lx, sy + 0.5);
      ctx.fillStyle = top ? surface : ink2;
      ctx.font = `400 10px ${mono}`;
      ctx.fillText(count, lx + tw + 6, sy + 0.5);
    }
    ctx.globalAlpha = 1;
    labelsMoving = moving;
    if (moving) requestDraw();
  }

  // Where you are: the regions you've zoomed inside, as keys that take you back out.
  const whereEl = document.getElementById("where");
  let whereKey = "";
  function updateWhere() {
    if (!whereEl) return;
    const [cx, cy] = transform.invert([W / 2, H / 2]);
    const d = quadtree && quadtree.find(cx, cy, 80 / transform.k);
    const c = d ? clusters.get(d.c) : null;
    const path = c ? c.path.filter((a) => expanded.has(a.id)) : [];
    const keyNow = path.map((a) => a.id).join(">");
    if (keyNow === whereKey) return;
    whereKey = keyNow;
    whereEl.replaceChildren();
    whereEl.hidden = !path.length;
    const all = el("button", { className: "key", textContent: "all" });
    all.onclick = () => d3.select(canvas).transition().duration(500).call(zoom.transform, fitTransform());
    whereEl.append(all);
    for (const a of path) {
      whereEl.append(el("span", { className: "sep", textContent: "›", ariaHidden: "true" }));
      const b = el("button", { className: "key", textContent: a.label });
      b.onclick = () => flyTo(a.x, a.y, (expandAt() * 0.7) / a.r);
      whereEl.append(b);
    }
  }

  function thumbSize(k) { return Math.min(150, 6.5 * Math.pow(k, 0.9)); }
  function drawMap() {
    if (state.view !== "terrain" || !W) return;
    const k = transform.k;
    const bg = css("--bg"), surface = css("--surface"), ink = css("--ink"), ink2 = css("--ink-2"), hair = css("--hair");
    convertQueue.clear();   // only what this frame still needs gets re-queued

    // The terrain (grid, dithered bands, contours) only changes when you pan,
    // zoom or filter, so it is drawn once into its own canvas and reused while
    // thumbnails and labels update on top.
    const tkey = [transform.x, transform.y, k, W, H, DPR, contoursVersion, bg].join("|");
    if (terrainKey !== tkey) {
      terrainKey = tkey;
      renderTerrain(k, bg, ink, hair);
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(terrainCanvas, 0, 0);
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.save();
    ctx.translate(transform.x, transform.y);
    ctx.scale(k, k);

    const [x0, y0] = transform.invert([0, 0]);
    const [x1, y1] = transform.invert([W, H]);
    const inView = (d) => d.x >= x0 - 20 && d.x <= x1 + 20 && d.y >= y0 - 20 && d.y <= y1 + 20;

    // Markers: squares for what you made or posted, circles for what you kept.
    const mark = (d, r) => {
      ctx.beginPath();
      if (d.mine) ctx.rect(d.x - r, d.y - r, 2 * r, 2 * r);
      else ctx.arc(d.x, d.y, r, 0, Math.PI * 2);
    };
    const showThumbs = k >= 2.4;
    if (!showThumbs) {
      ctx.fillStyle = ink;
      ctx.strokeStyle = bg;
      ctx.lineWidth = 0.8 / k;
      for (const d of visible) {
        const r = (1 + Math.sqrt(d.r) * 0.5) / Math.sqrt(k);
        mark(d, r); ctx.fill(); ctx.stroke();
      }
    } else {
      const shown = visible.filter(inView).sort((a, b) => a.r - b.r);
      const withThumb = shown.filter((d) => d.th).slice(-450);
      const drawSet = new Set(withThumb);
      ctx.fillStyle = ink;
      for (const d of shown) {
        if (drawSet.has(d)) continue;
        mark(d, 1.8 / k); ctx.fill();
      }
      const sizePx = thumbSize(k);
      for (const d of withThumb) {
        if (d === hovered) continue;   // drawn last, in color
        const s = (sizePx * (0.7 + 0.15 * Math.min(d.r, 4))) / k;
        const img = thumb(d, s * k);
        const ar = d.wh ? d.wh[0] / d.wh[1] : 1;
        const w = ar >= 1 ? s : s * ar, h = ar >= 1 ? s / ar : s;
        const fr = (d.mine ? 2 : 1) / k;
        ctx.fillStyle = d.mine ? ink : surface;
        ctx.fillRect(d.x - w / 2 - fr, d.y - h / 2 - fr, w + 2 * fr, h + 2 * fr);
        if (img) {
          ctx.imageSmoothingEnabled = imageMode !== "dither" || s * k < img.width;
          ctx.drawImage(img, d.x - w / 2, d.y - h / 2, w, h);
          ctx.imageSmoothingEnabled = true;
        } else {
          // Not ready yet: a hatched card rather than a blank one.
          ctx.fillStyle = surface;
          ctx.fillRect(d.x - w / 2, d.y - h / 2, w, h);
          ctx.save();
          ctx.beginPath(); ctx.rect(d.x - w / 2, d.y - h / 2, w, h); ctx.clip();
          ctx.strokeStyle = hair; ctx.lineWidth = 1 / k;
          ctx.beginPath();
          for (let o = -h; o < w; o += 6 / k) { ctx.moveTo(d.x - w / 2 + o, d.y + h / 2); ctx.lineTo(d.x - w / 2 + o + h, d.y - h / 2); }
          ctx.stroke();
          ctx.restore();
        }
        if (!d.mine) { ctx.strokeStyle = ink; ctx.lineWidth = 0.75 / k; ctx.strokeRect(d.x - w / 2 - fr, d.y - h / 2 - fr, w + 2 * fr, h + 2 * fr); }
      }
      // The thumbnail under the cursor: lifted a little and shown in full color.
      if (hovered && drawSet.has(hovered)) {
        const d = hovered, e = images.get(d.id);
        const s = (sizePx * (0.7 + 0.15 * Math.min(d.r, 4)) * 1.18) / k;
        const ar = d.wh ? d.wh[0] / d.wh[1] : 1;
        const w = ar >= 1 ? s : s * ar, h = ar >= 1 ? s / ar : s;
        const fr = 2 / k;
        ctx.fillStyle = ink;
        ctx.fillRect(d.x - w / 2 - fr, d.y - h / 2 - fr, w + 2 * fr, h + 2 * fr);
        const img = e && e.ok ? e.img : thumb(d, s * k);
        if (img) ctx.drawImage(img, d.x - w / 2, d.y - h / 2, w, h);
      }
    }
    ctx.restore();

    // Selection: viewfinder corners, in screen pixels.
    if (state.selected && isVisible(state.selected)) {
      const d = state.selected;
      const [sx, sy] = transform.apply([d.x, d.y]);
      const half = showThumbs ? thumbSize(k) * 0.5 + 8 : 10, arm = Math.max(5, half * 0.35);
      ctx.strokeStyle = ink; ctx.lineWidth = 2;
      ctx.beginPath();
      for (const [cx, cy] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
        const px = sx + cx * half, py = sy + cy * half;
        ctx.moveTo(px - cx * arm, py); ctx.lineTo(px, py); ctx.lineTo(px, py - cy * arm);
      }
      ctx.stroke();
    }

    drawLabels(k, surface, ink, ink2);
    updateWhere();

    const legend = document.getElementById("legend");
    legend.replaceChildren();
    const b = document.createElement("b");
    b.textContent = visible.length.toLocaleString();
    legend.append(b, ` / ${items.length.toLocaleString()} mapped`);
    if (items.some((d) => d.mine)) {
      const sq = document.createElement("span"); sq.className = "sym sq";
      const ci = document.createElement("span"); ci.className = "sym ci";
      legend.append(sq, "made", ci, "kept");
    }
    if (DATA.meta.items > items.length) legend.append(`   ${(DATA.meta.items - items.length).toLocaleString()} waiting`);
  }

  // Hover and click.
  const tip = document.getElementById("tip");
  let hovered = null;
  function setHovered(d) {
    if (d === hovered) return;
    hovered = d;
    requestDraw();
  }
  function hideTip() { tip.hidden = true; setHovered(null); }
  function itemAt(mx, my) {
    const [wx, wy] = transform.invert([mx, my]);
    const radius = (transform.k >= 2.4 ? thumbSize(transform.k) * 0.5 : 8) / transform.k;
    return quadtree.find(wx, wy, radius);
  }
  function labelAt(mx, my) {
    return labelBoxes.find((b) => mx >= b[0] && mx <= b[2] && my >= b[1] && my <= b[3]);
  }
  canvas.addEventListener("mousemove", (e) => {
    const r = canvas.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    const lab = labelAt(mx, my);
    const d = lab ? null : itemAt(mx, my);
    canvas.style.cursor = d || lab ? "pointer" : "";
    if (!d) { hideTip(); return; }
    setHovered(d);
    tip.replaceChildren();
    if (d.th) {   // always in full color
      const img = document.createElement("img"); img.src = MEDIA(d.th); img.alt = ""; tip.appendChild(img);
    }
    if (d.t) { const p = document.createElement("div"); p.className = "text"; p.textContent = d.t.length > 140 ? d.t.slice(0, 140) + "…" : d.t; tip.appendChild(p); }
    const m = document.createElement("div"); m.className = "meta";
    m.textContent = [d.a ? "@" + d.a : null, (PLATFORM_NAMES[d.p] || d.p).toLowerCase(), d.time ? fmtStamp(toDate(d.time)) : null].filter(Boolean).join("  ");
    tip.appendChild(m);
    tip.hidden = false;
    const tx = Math.min(mx + 14, W - 270), ty = Math.min(my + 14, H - tip.offsetHeight - 8);
    tip.style.left = tx + "px"; tip.style.top = ty + "px";
  });
  canvas.addEventListener("mouseleave", hideTip);
  canvas.addEventListener("click", (e) => {
    const r = canvas.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    const lab = labelAt(mx, my);
    if (lab) { openRegion(lab.cluster); return; }
    const d = itemAt(mx, my);
    if (d) openItem(d);
  });

  // ---------------------------------------------------------------- panel
  const panel = document.getElementById("panel");
  const body = document.getElementById("panel-body");
  document.getElementById("panel-close").onclick = closePanel;
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closePanel(); });
  function closePanel() { panel.hidden = true; state.selected = null; requestDraw(); }

  function el(tag, props = {}, ...children) {
    const n = document.createElement(tag);
    Object.assign(n, props);
    for (const c of children) if (c != null) n.append(c);
    return n;
  }

  function gridOf(list, onPick) {
    const g = el("div", { className: "grid" });
    for (const d of list) {
      const b = el("button", { title: d.t || "" });
      if (d.th) b.append(el("img", { src: MEDIA(d.th), alt: d.t ? d.t.slice(0, 80) : "", loading: "lazy" }));
      else b.append(el("span", { className: "text", textContent: (d.t || "").slice(0, 90) }));
      b.onclick = () => onPick(d);
      g.append(b);
    }
    return g;
  }

  function historyLine(ix) {
    const [type, at, est, collection] = ix;
    const what = (VERBS[type] || type) + (collection ? ` to “${collection}”` : "");
    const when = at ? (est ? "~" + fmtStamp(toDate(at)) : d3.timeFormat("%Y.%m.%d")(toDate(at))) : "";
    const li = el("li");
    li.append(el("span", { textContent: what }), el("span", { textContent: when }));
    return li;
  }

  function setHero(img, src) {
    img.classList.remove("bit");
    img.dataset.color = src;
    delete img.dataset.mono;
    if (!img.dataset.hover) {
      // Hovering any image shows it in full color; the 1-bit copy swaps back on leave.
      img.dataset.hover = "1";
      img.addEventListener("mouseenter", () => { if (img.dataset.mono) img.src = img.dataset.color; });
      img.addEventListener("mouseleave", () => { if (img.dataset.mono) img.src = img.dataset.mono; });
    }
    if (imageMode !== "dither") { img.src = src; return; }
    const raw = new Image();
    raw.onload = () => {
      img.dataset.mono = processImage(raw, "dither", 760).toDataURL();
      if (!img.matches(":hover")) img.src = img.dataset.mono;
      img.classList.add("bit");
    };
    raw.src = src;
  }

  function openItem(d, pan = false) {
    state.selected = d;
    body.replaceChildren();
    if (d.im && d.im.length) {
      const hero = el("img", { className: "hero", alt: d.t ? d.t.slice(0, 120) : "" });
      setHero(hero, MEDIA(d.im[0]));
      body.append(hero);
      if (d.im.length > 1) {
        const gal = el("div", { className: "gallery" });
        d.im.forEach((p) => { const t = el("img", { src: MEDIA(p), alt: "" }); t.onclick = () => setHero(hero, MEDIA(p)); gal.append(t); });
        body.append(gal);
      }
    }
    if (d.pal && d.pal.length && imageMode === "color") {
      const sw = el("div", { className: "swatches", title: "Dominant colors" });
      d.pal.forEach(([hex, w]) => sw.append(el("span", { style: `background:${hex};flex:${w}` })));
      body.append(sw);
    }
    if (d.t) body.append(el("p", { className: "caption", textContent: d.t }));
    body.append(el("p", { className: "meta",
      textContent: [d.a ? "@" + d.a : null, (PLATFORM_NAMES[d.p] || d.p).toLowerCase(),
                    d.ts ? "published " + d3.timeFormat("%Y.%m.%d")(toDate(d.ts)) : null].filter(Boolean).join("  ") }));
    const actions = el("div", { className: "actions" });
    if (d.p === "files") {
      const b = el("button", { className: "key", textContent: "show in finder" });
      b.onclick = () => fetch("/api/reveal?id=" + encodeURIComponent(d.id)).then((r) => {
        if (!r.ok) b.textContent = "file not found: it may have moved";
      });
      actions.append(b);
      if (d.src) actions.append(el("a", { className: "key", href: d.src, target: "_blank", rel: "noopener",
        textContent: `source: ${new URL(d.src).hostname}` }));
    } else if (d.u) actions.append(el("a", { className: "key", href: d.u, target: "_blank", rel: "noopener",
      textContent: `open on ${(PLATFORM_NAMES[d.p] || "the web").toLowerCase()}` }));
    if (actions.children.length) body.append(actions);

    body.append(el("h3", { textContent: "history" }));
    const ul = el("ul", { className: "history" });
    d.ix.forEach((ix) => ul.append(historyLine(ix)));
    body.append(ul);

    const c = clusters.get(d.c);
    if (c) {
      body.append(el("h3", { textContent: "region" }));
      body.append(regionPath(c.path));
    }
    const nb = (d.nb || []).map((j) => items[j]).filter(Boolean);
    if (nb.length) {
      body.append(el("h3", { textContent: "nearest in taste" }));
      body.append(gridOf(nb, (n) => openItem(n, true)));
    }
    panel.hidden = false;
    panel.scrollTop = 0;
    if (pan && state.view === "terrain") flyTo(d.x, d.y, Math.max(transform.k, 4));
    requestDraw();
  }

  function openRegion(c) {
    state.selected = null;
    body.replaceChildren();
    if (c.path.length > 1) body.append(regionPath(c.path.slice(0, -1)));
    body.append(el("h2", { textContent: c.label }));
    const words = c.terms && c.terms.length ? `   words: ${c.terms.slice(0, 5).join(", ")}` : "";
    body.append(el("p", { className: "meta", textContent: `${c.n.toLocaleString()} items${words}` }));
    if (c.children.length) {
      body.append(el("h3", { textContent: "inside" }));
      const keys = el("div", { className: "keys" });
      for (const k of c.children) {
        const b = el("button", { className: "key", textContent: `${k.label} ` }, el("small", { textContent: k.n.toLocaleString() }));
        b.onclick = () => openRegion(k);
        keys.append(b);
      }
      body.append(keys);
    }

    // When this region was active.
    const times = c.members.filter((d) => d.time).map((d) => toDate(d.time));
    if (times.length > 1) {
      const w = 340, h = 56;
      const x = d3.scaleTime().domain(d3.extent(allTimes)).range([0, w]);
      const bins = d3.bin().domain(x.domain()).thresholds(x.ticks(d3.timeMonth.every(3)))(times);
      const y = d3.scaleLinear().domain([0, d3.max(bins, (b) => b.length) || 1]).range([h - 14, 2]);
      const svg = d3.create("svg").attr("viewBox", `0 0 ${w} ${h}`).attr("width", "100%").attr("role", "img")
        .attr("aria-label", "When you engaged with this region");
      svg.append("g").selectAll("rect").data(bins).join("rect")
        .attr("x", (b) => x(b.x0)).attr("width", (b) => Math.max(1, x(b.x1) - x(b.x0) - 1))
        .attr("y", (b) => y(b.length)).attr("height", (b) => h - 14 - y(b.length)).attr("fill", css("--ink"));
      svg.append("g").attr("transform", `translate(0,${h - 13})`).attr("class", "timeline-axis")
        .call(d3.axisBottom(x).ticks(5).tickSize(0)).select(".domain").remove();
      body.append(el("h3", { textContent: "when it was on your mind" }), svg.node());
    }
    body.append(el("h3", { textContent: "most resonant" }));
    const list = [...c.members].sort((a, b) => b.r - a.r || (b.time || 0) - (a.time || 0)).slice(0, 150);
    body.append(gridOf(list, (d) => openItem(d, true)));
    panel.hidden = false;
    panel.scrollTop = 0;
    // Close enough that the regions inside it are named.
    if (state.view === "terrain") flyTo(c.x, c.y, (expandAt() * (c.children.length ? 1.15 : 0.7)) / c.r);
  }

  function regionPath(path) {
    const keys = el("div", { className: "keys crumbs" });
    path.forEach((a, i) => {
      if (i) keys.append(el("span", { className: "sep", textContent: "›", ariaHidden: "true" }));
      const b = el("button", { className: "key", textContent: a.label });
      b.onclick = () => openRegion(a);
      keys.append(b);
    });
    return keys;
  }

  // ---------------------------------------------------------------- timeline
  const allTimes = items.filter((d) => d.time).map((d) => toDate(d.time));
  const unmappedMonths = Object.entries(DATA.unmapped || {}).map(([m, n]) => [d3.timeParse("%Y-%m")(m), n]);
  const tExtent = d3.extent([...allTimes, ...unmappedMonths.map((u) => u[0])]);
  tExtent[0] = d3.timeMonth.floor(tExtent[0]);
  tExtent[1] = d3.timeMonth.offset(d3.timeMonth.floor(tExtent[1]), 1);
  const tlSvg = d3.select("#timeline");
  const rangeLabel = document.getElementById("range-label");
  let tlX, brush, brushG, settingBrush = false;

  function drawTimeline() {
    const node = tlSvg.node();
    const w = node.getBoundingClientRect().width, h = 48;
    tlSvg.selectAll("*").remove();
    tlX = d3.scaleTime().domain(tExtent).range([16, w - 16]);
    const months = d3.timeMonth.range(tExtent[0], tExtent[1]);
    const counts = d3.rollup(items.filter((d) => d.time), (v) => v.length, (d) => +d3.timeMonth.floor(toDate(d.time)));
    const y = d3.scaleLinear().domain([0, d3.max(months, (m) => counts.get(+m) || 0) || 1]).range([h - 16, 2]);
    const bw = Math.max(1, Math.floor((w - 8) / months.length) - 1);
    tlSvg.append("g").selectAll("rect").data(months).join("rect").attr("class", "timeline-bar")
      .attr("shape-rendering", "crispEdges")
      .attr("x", (m) => Math.round(tlX(m))).attr("width", bw)
      .attr("y", (m) => y(counts.get(+m) || 0)).attr("height", (m) => h - 16 - y(counts.get(+m) || 0));
    // A ruler: a tick per month, a long tick and a label per year.
    const ruler = tlSvg.append("g").attr("class", "timeline-axis").attr("transform", `translate(0,${h - 15})`);
    ruler.append("g").attr("class", "minor").selectAll("line").data(months).join("line")
      .attr("x1", (m) => Math.round(tlX(m)) + 0.5).attr("x2", (m) => Math.round(tlX(m)) + 0.5).attr("y1", 0).attr("y2", 2);
    ruler.call(d3.axisBottom(tlX).ticks(d3.timeYear.every(w < 500 ? 4 : w < 900 ? 2 : 1)).tickSize(5).tickFormat(d3.timeFormat("%Y")));
    brush = d3.brushX().extent([[16, 0], [w - 16, h - 16]]).on("brush end", onBrush);
    brushG = tlSvg.append("g").attr("class", "brush").call(brush);
    if (state.range) { settingBrush = true; brushG.call(brush.move, state.range.map(tlX)); settingBrush = false; }
    updateRangeLabel();
  }
  function onBrush(e) {
    if (settingBrush) return;
    if (!e.selection) { state.range = null; }
    else { state.range = e.selection.map(tlX.invert); stopPlay(); }
    if (e.type === "brush" || e.type === "end") scheduleUpdate();
  }
  function updateRangeLabel() {
    const [a, b] = state.range || tExtent;
    rangeLabel.replaceChildren(
      state.range ? `${fmtStamp(a)} — ${fmtStamp(d3.timeDay.offset(b, -1))}` : `${a.getFullYear()} — ${d3.timeDay.offset(b, -1).getFullYear()}`,
      Object.assign(document.createElement("small"), { textContent: state.range ? `${visible.length.toLocaleString()} items in range` : "all time" }));
  }

  // Play: slide a window (the current selection, or two years) through time.
  const playBtn = document.getElementById("play");
  let playTimer = null;
  function stopPlay() { if (playTimer) { clearInterval(playTimer); playTimer = null; playBtn.textContent = "▶"; playBtn.setAttribute("aria-label", "Play through time"); } }
  playBtn.onclick = () => {
    if (playTimer) { stopPlay(); return; }
    let [a, b] = state.range || [tExtent[0], d3.timeMonth.offset(tExtent[0], 24)];
    const span = b - a;
    if (+b >= +tExtent[1]) { a = tExtent[0]; b = new Date(+a + span); }
    playBtn.textContent = "■";
    playBtn.setAttribute("aria-label", "Pause");
    playTimer = setInterval(() => {
      a = d3.timeMonth.offset(a, 1); b = new Date(+a + span);
      if (+b > +tExtent[1]) { stopPlay(); return; }
      state.range = [a, b];
      settingBrush = true; brushG.call(brush.move, state.range.map(tlX)); settingBrush = false;
      update();
    }, 140);
  };

  // ---------------------------------------------------------------- strata
  // One 1-bit pattern per layer: screens, hatches, rules and checks, from light to dark.
  const PATTERNS = [
    { w: 4, h: 4, d: "M0 0h1v1h-1z" },                                   // fine dot screen
    { w: 6, h: 6, d: "M0 6L6 0", stroke: 1 },                            // diagonal hatch
    { w: 4, h: 3, d: "M0 0.5H4", stroke: 1 },                            // horizontal rule
    { w: 3, h: 3, d: "M0 0h1v1h-1z" },                                   // dense dot screen
    { w: 6, h: 6, d: "M0 6L6 0M0 0L6 6", stroke: 0.8 },                  // crosshatch
    { w: 3, h: 4, d: "M0.5 0V4", stroke: 1 },                            // vertical rule
    { w: 4, h: 4, d: "M0 0h2v2h-2zM2 2h2v2h-2z" },                       // checker
    { w: 5, h: 5, d: "M0 0L5 5", stroke: 1 },                            // back hatch
    { w: 6, h: 6, d: "M1 1h2v2h-2z" },                                   // square dots
    { w: 8, h: 4, d: "M0 0.5H4", stroke: 1 },                            // dashes
    { w: 2, h: 2, d: "M0 0h1v1h-1zM1 1h1v1h-1z" },                       // 50% screen
    { w: 4, h: 4, d: "M0 0h3v1h-3zM0 2h1v1h-1z" },                       // brick
  ];
  // Strata shows a cut through the region tree with few enough layers to read:
  // the largest regions are split into the regions inside them while that fits.
  function strataRegions(maxLayers = 16) {
    const cut = roots.slice();
    for (;;) {
      const open = cut.filter((c) => c.children.length && cut.length - 1 + c.children.length <= maxLayers)
        .sort((a, b) => b.n - a.n)[0];
      if (!open) break;
      cut.splice(cut.indexOf(open), 1, ...open.children);
    }
    return cut.sort((a, b) => b.n - a.n);
  }

  const strataTip = document.getElementById("strata-tip");
  function drawStrata() {
    if (state.view !== "strata") return;
    const svg = d3.select("#strata-svg");
    const node = svg.node();
    const { width: w, height: h } = node.getBoundingClientRect();
    if (!w) return;
    svg.selectAll("*").remove();
    const months = d3.timeMonth.range(tExtent[0], tExtent[1]);
    const idx = new Map(months.map((m, i) => [+m, i]));
    const layers = strataRegions();
    const layerOf = new Map();
    for (const c of layers) (function mark(r) { layerOf.set(r.id, c.id); r.children.forEach(mark); })(c);
    const keys = layers.map((c) => String(c.id));
    const hasUnmapped = unmappedMonths.length > 0;
    if (hasUnmapped) keys.push("unmapped");
    const table = months.map((m) => { const r = { date: m }; keys.forEach((k) => (r[k] = 0)); return r; });
    for (const d of visible) {
      const layer = d.time ? layerOf.get(d.c) : undefined;
      if (layer == null) continue;
      const i = idx.get(+d3.timeMonth.floor(toDate(d.time)));
      if (i != null) table[i][String(layer)] += d.r;
    }
    if (hasUnmapped) for (const [m, n] of unmappedMonths) { const i = idx.get(+m); if (i != null) table[i].unmapped += n; }
    // Light smoothing so layers read as strata rather than noise.
    const kernel = [1, 2, 3, 2, 1];
    const smooth = table.map((r, i) => {
      const o = { date: r.date };
      keys.forEach((k) => {
        let s = 0, wsum = 0;
        kernel.forEach((wt, j) => { const row = table[i + j - 2]; if (row) { s += wt * row[k]; wsum += wt; } });
        o[k] = s / wsum;
      });
      return o;
    });
    const series = d3.stack().keys(keys).offset(d3.stackOffsetWiggle).order(d3.stackOrderInsideOut)(smooth);
    const margin = { top: 24, right: 24, bottom: 28, left: 24 };
    const x = d3.scaleTime().domain(tExtent).range([margin.left, w - margin.right]);
    const y = d3.scaleLinear()
      .domain([d3.min(series, (s) => d3.min(s, (p) => p[0])), d3.max(series, (s) => d3.max(s, (p) => p[1]))])
      .range([h - margin.bottom, margin.top]);
    const area = d3.area().curve(d3.curveBasis).x((p) => x(p.data.date)).y0((p) => y(p[0])).y1((p) => y(p[1]));

    const defs = svg.append("defs");
    const ink = css("--ink"), bgc = css("--bg");
    PATTERNS.forEach((p, i) => {
      const pat = defs.append("pattern").attr("id", "strat" + i).attr("patternUnits", "userSpaceOnUse")
        .attr("width", p.w).attr("height", p.h);
      pat.append("rect").attr("width", p.w).attr("height", p.h).attr("fill", bgc);
      pat.append("path").attr("d", p.d).attr("shape-rendering", "crispEdges")
        .attr("fill", p.stroke ? "none" : ink).attr("stroke", p.stroke ? ink : "none").attr("stroke-width", p.stroke || 0);
    });
    const unm = defs.append("pattern").attr("id", "unmapped").attr("patternUnits", "userSpaceOnUse").attr("width", 8).attr("height", 8);
    unm.append("rect").attr("width", 8).attr("height", 8).attr("fill", bgc);
    unm.append("path").attr("d", "M0 0h1v1h-1z").attr("fill", css("--ink-2"));
    const color = (k) => k === "unmapped" ? "url(#unmapped)" : `url(#strat${keys.indexOf(k) % PATTERNS.length})`;

    if (state.range) {
      svg.append("rect").attr("x", x(state.range[0])).attr("width", Math.max(1, x(state.range[1]) - x(state.range[0])))
        .attr("y", margin.top - 8).attr("height", h - margin.top - margin.bottom + 8)
        .attr("fill", css("--ink")).attr("opacity", 0.07);
    }
    const label = (k) => k === "unmapped" ? "not yet mapped (links waiting for images)" : clusters.get(+k).label;
    svg.append("g").selectAll("path").data(series).join("path")
      .attr("class", "stratum").attr("fill", (s) => color(s.key)).attr("d", area)
      .on("mousemove", (e, s) => {
        const date = d3.timeMonth.floor(x.invert(d3.pointer(e, node)[0]));
        const i = idx.get(+date);
        const raw = i != null ? table[i][s.key] : 0;
        strataTip.textContent = `${label(s.key)}  ${fmtStamp(date)}  ${s.key === "unmapped" ? raw + " links" : "resonance " + raw.toFixed(1)}`;
        strataTip.hidden = false;
        const [px, py] = d3.pointer(e, node);
        strataTip.style.left = Math.min(px + 12, w - 270) + "px";
        strataTip.style.top = py + 12 + "px";
        svg.selectAll(".stratum").classed("dim", (o) => o !== s);
      })
      .on("mouseleave", () => { strataTip.hidden = true; svg.selectAll(".stratum").classed("dim", false); })
      .on("click", (e, s) => { if (s.key !== "unmapped") openRegion(clusters.get(+s.key)); });

    // Name each layer where the whole name fits inside it: the stretch of months
    // under the label must all be at least a line tall.
    const g = svg.append("g");
    const placed = [];
    const step = (w - margin.left - margin.right) / Math.max(1, months.length - 1);
    const candidates = [];
    for (const s of series) {
      if (s.key === "unmapped") continue;
      const name = clusters.get(+s.key).label;
      const half = Math.ceil((name.length * 6.8 + 10) / 2 / step);   // months under half the label
      let best = -1, bi = -1;
      for (let i = half; i < s.length - half; i++) {
        let lo = Infinity;
        for (let j = i - half; j <= i + half; j++) lo = Math.min(lo, y(s[j][0]) - y(s[j][1]));
        if (lo > best) { best = lo; bi = i; }
      }
      if (bi >= 0 && best >= 14) candidates.push({ s, best, p: s[bi], name });
    }
    candidates.sort((a, b) => b.best - a.best);
    for (const { s, p, name } of candidates) {
      const lx = x(p.data.date);
      const ly = (y(p[0]) + y(p[1])) / 2;
      const t = g.append("text").attr("class", "stratum-label").attr("text-anchor", "middle")
        .attr("x", lx).attr("y", ly).attr("dy", "0.35em").text(name);
      const b = t.node().getBBox();
      if (placed.some((o) => !(b.x + b.width < o.x || b.x > o.x + o.width || b.y + b.height < o.y || b.y > o.y + o.height))) {
        t.remove();
        continue;
      }
      placed.push(b);
    }
    svg.append("g").attr("class", "strata-axis").attr("transform", `translate(0,${h - margin.bottom})`)
      .call(d3.axisBottom(x).ticks(d3.timeYear.every(1)).tickSize(5).tickFormat(d3.timeFormat("%Y")));
  }

  // ---------------------------------------------------------------- update loop
  let updPending = false;
  function scheduleUpdate() {
    if (updPending) return;
    updPending = true;
    requestAnimationFrame(() => { updPending = false; update(); });
  }
  function update() {
    visible = items.filter(isVisible);
    computeContours();
    buildQuadtree();
    updateRangeLabel();
    if (state.view === "terrain") requestDraw(); else drawStrata();
  }

  window.addEventListener("resize", () => { resizeMap(); drawTimeline(); drawStrata(); });
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    clearProcessed(); ditherCache = null; for (const k in rgbCache) delete rgbCache[k];
    requestDraw(); drawTimeline(); drawStrata();
  });

  setImageMode(imageMode);
  computeContours();
  buildQuadtree();
  resizeMap();
  drawTimeline();
  document.fonts && document.fonts.ready.then(() => { requestDraw(); drawTimeline(); });

  // Handle for automated tests and the console.
  window.topograph = { data: DATA, clusters, openItem, openRegion, flyTo, setView, labelAlpha };
})();
