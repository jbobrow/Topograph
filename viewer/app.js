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
  const PLATFORM_NAMES = { instagram: "Instagram", x: "X", youtube: "YouTube", google: "Google", bluesky: "Bluesky" };
  const GROUPS = [
    { key: "made", label: "Posted", types: ["post", "repost", "reply", "comment"] },
    { key: "liked", label: "Liked", types: ["like"] },
    { key: "kept", label: "Saved", types: ["save", "bookmark"] },
  ];
  const VERBS = { post: "Posted", repost: "Reposted", reply: "Replied", comment: "Commented",
                  like: "Liked", save: "Saved", bookmark: "Bookmarked", view: "Watched", search: "Searched" };

  const items = DATA.items;
  items.forEach((d, i) => {
    d.i = i;
    d.time = d.at || d.ts || null;
    d.types = new Set(d.ix.map((x) => x[0]));
    d.search = ((d.t || "") + " @" + (d.a || "")).toLowerCase();
  });
  const clusters = new Map(DATA.clusters.map((c) => [c.id, c]));
  for (const c of clusters.values()) {
    const m = items.filter((d) => d.c === c.id);
    c.members = m;
    c.cx = d3.median(m, (d) => d.x);
    c.cy = d3.median(m, (d) => d.y);
  }

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
    b.className = "chip";
    b.textContent = label;
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
  let qTimer;
  document.getElementById("query").addEventListener("input", (e) => {
    clearTimeout(qTimer);
    qTimer = setTimeout(() => { state.query = e.target.value.trim().toLowerCase(); update(); }, 150);
  });

  document.querySelectorAll(".views button").forEach((b) => b.addEventListener("click", () => setView(b.dataset.view)));
  function setView(v) {
    state.view = v;
    document.querySelectorAll(".views button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.view === v)));
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
  let contours = [];
  function computeContours() {
    const fn = visible.length ? density.contours(visible) : null;
    contours = fn ? THRESHOLDS.map((t) => fn(t)) : [];
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

  // Thumbnails load lazily and are kept in a bounded cache.
  const images = new Map();
  function thumb(d) {
    let e = images.get(d.id);
    if (!e) {
      const img = new Image();
      e = { img, ok: false };
      img.onload = () => { e.ok = true; requestDraw(); };
      img.src = MEDIA(d.th);
      images.set(d.id, e);
      if (images.size > 2500) images.delete(images.keys().next().value);
    }
    return e.ok ? e.img : null;
  }

  let drawPending = false;
  function requestDraw() {
    if (drawPending) return;
    drawPending = true;
    requestAnimationFrame(() => { drawPending = false; drawMap(); });
  }

  let labelBoxes = [];
  function drawMap() {
    if (state.view !== "terrain" || !W) return;
    const k = transform.k;
    const paper = css("--paper"), ink = css("--ink"), contourCol = css("--contour"), water = css("--water");
    const tint = d3.scaleLinear().domain([0, 0.35, 0.7, 1])
      .range([css("--tint-0"), css("--tint-1"), css("--tint-2"), css("--tint-3")]).interpolate(d3.interpolateRgb);

    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.fillStyle = paper;
    ctx.fillRect(0, 0, W, H);

    ctx.save();
    ctx.translate(transform.x, transform.y);
    ctx.scale(k, k);
    const path = d3.geoPath(null, ctx);

    // Hypsometric tint, then contour lines; every fourth line is an index contour.
    contours.forEach((c, i) => {
      ctx.beginPath(); path(c);
      ctx.fillStyle = tint(i / (LEVELS - 1));
      ctx.fill();
    });
    ctx.strokeStyle = contourCol;
    contours.forEach((c, i) => {
      ctx.beginPath(); path(c);
      const index = i % 4 === 3;
      ctx.globalAlpha = index ? 0.85 : 0.5;
      ctx.lineWidth = (index ? 1.3 : 0.6) / k;
      ctx.stroke();
    });
    ctx.globalAlpha = 1;

    // Viewport in world coordinates.
    const [x0, y0] = transform.invert([0, 0]);
    const [x1, y1] = transform.invert([W, H]);
    const inView = (d) => d.x >= x0 - 20 && d.x <= x1 + 20 && d.y >= y0 - 20 && d.y <= y1 + 20;

    const showThumbs = k >= 2.4;
    if (!showThumbs) {
      ctx.fillStyle = ink;
      ctx.globalAlpha = 0.55;
      for (const d of visible) {
        const r = (0.9 + Math.sqrt(d.r) * 0.55) / Math.sqrt(k);
        ctx.beginPath(); ctx.arc(d.x, d.y, r, 0, Math.PI * 2); ctx.fill();
      }
      ctx.globalAlpha = 1;
    } else {
      const shown = visible.filter(inView).sort((a, b) => a.r - b.r);
      const budget = 450;
      const withThumb = shown.filter((d) => d.th).slice(-budget);
      const drawSet = new Set(withThumb);
      ctx.fillStyle = ink;
      ctx.globalAlpha = 0.5;
      for (const d of shown) {
        if (drawSet.has(d)) continue;
        ctx.beginPath(); ctx.arc(d.x, d.y, 1.6 / k, 0, Math.PI * 2); ctx.fill();
      }
      ctx.globalAlpha = 1;
      const sizePx = Math.min(150, 6.5 * Math.pow(k, 0.9));
      for (const d of withThumb) {
        const s = (sizePx * (0.7 + 0.15 * Math.min(d.r, 4))) / k;
        const img = thumb(d);
        const ar = d.wh ? d.wh[0] / d.wh[1] : 1;
        const w = ar >= 1 ? s : s * ar, h = ar >= 1 ? s / ar : s;
        ctx.fillStyle = paper;
        ctx.fillRect(d.x - w / 2 - 1.5 / k, d.y - h / 2 - 1.5 / k, w + 3 / k, h + 3 / k);
        if (img) ctx.drawImage(img, d.x - w / 2, d.y - h / 2, w, h);
        else { ctx.fillStyle = d.col || css("--paper-2"); ctx.fillRect(d.x - w / 2, d.y - h / 2, w, h); }
      }
    }

    if (state.selected && isVisible(state.selected)) {
      const d = state.selected;
      ctx.strokeStyle = water;
      ctx.lineWidth = 2.5 / k;
      ctx.beginPath(); ctx.arc(d.x, d.y, (showThumbs ? Math.min(150, 6.5 * Math.pow(k, 0.9)) * 0.7 : 9) / k, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.restore();

    // Region names, like place names on a map: larger regions win collisions.
    labelBoxes = [];
    const fade = k > 5 ? Math.max(0, 1 - (k - 5) / 4) : 1;
    if (fade > 0) {
      const visCount = d3.rollup(visible, (v) => v.length, (d) => d.c);
      const order = [...clusters.values()].filter((c) => visCount.get(c.id)).sort((a, b) => b.n - a.n);
      const serif = css("--serif");
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      if ("letterSpacing" in ctx) ctx.letterSpacing = "0.06em";
      for (const c of order) {
        const [sx, sy] = transform.apply([c.cx, c.cy]);
        if (sx < -100 || sx > W + 100 || sy < -20 || sy > H + 20) continue;
        const fs = Math.max(12, Math.min(24, 10 + Math.sqrt(c.n) * 0.9));
        ctx.font = `italic ${fs}px ${serif}`;
        const tw = ctx.measureText(c.label).width;
        const box = [sx - tw / 2 - 4, sy - fs / 2 - 2, sx + tw / 2 + 4, sy + fs / 2 + 2];
        if (labelBoxes.some((b) => !(box[2] < b[0] || box[0] > b[2] || box[3] < b[1] || box[1] > b[3]))) continue;
        labelBoxes.push(Object.assign(box, { cluster: c }));
        ctx.globalAlpha = fade * (0.35 + 0.65 * (visCount.get(c.id) / c.n));
        ctx.lineWidth = 4;
        ctx.strokeStyle = css("--label-halo");
        ctx.strokeText(c.label, sx, sy);
        ctx.fillStyle = ink;
        ctx.fillText(c.label, sx, sy);
      }
      ctx.globalAlpha = 1;
      if ("letterSpacing" in ctx) ctx.letterSpacing = "0px";
    }

    document.getElementById("legend").textContent =
      `${visible.length.toLocaleString()} of ${items.length.toLocaleString()} mapped items` +
      (DATA.meta.items > items.length ? `, ${(DATA.meta.items - items.length).toLocaleString()} waiting for images` : "");
  }

  // Hover and click.
  const tip = document.getElementById("tip");
  function hideTip() { tip.hidden = true; }
  function itemAt(mx, my) {
    const [wx, wy] = transform.invert([mx, my]);
    const radius = (transform.k >= 2.4 ? Math.min(150, 6.5 * Math.pow(transform.k, 0.9)) * 0.5 : 8) / transform.k;
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
    tip.replaceChildren();
    if (d.th && transform.k < 2.4) {
      const img = document.createElement("img"); img.src = MEDIA(d.th); img.alt = ""; tip.appendChild(img);
    }
    if (d.t) { const p = document.createElement("div"); p.textContent = d.t.length > 140 ? d.t.slice(0, 140) + "…" : d.t; tip.appendChild(p); }
    const m = document.createElement("div"); m.className = "meta";
    m.textContent = [d.a ? "@" + d.a : null, PLATFORM_NAMES[d.p], d.time ? fmtMonth(toDate(d.time)) : null].filter(Boolean).join(", ");
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
    const verb = VERBS[type] || type;
    let when = "";
    if (at) when = est ? ` around ${fmtMonth(toDate(at))}` : ` on ${fmtDay(toDate(at))}`;
    return verb + (collection ? ` to “${collection}”` : "") + when;
  }

  function openItem(d, pan = false) {
    state.selected = d;
    body.replaceChildren();
    if (d.im && d.im.length) {
      const hero = el("img", { className: "hero", src: MEDIA(d.im[0]), alt: d.t ? d.t.slice(0, 120) : "" });
      body.append(hero);
      if (d.im.length > 1) {
        const gal = el("div", { className: "gallery" });
        d.im.forEach((p) => { const t = el("img", { src: MEDIA(p), alt: "" }); t.onclick = () => (hero.src = MEDIA(p)); gal.append(t); });
        body.append(gal);
      }
    }
    if (d.pal && d.pal.length) {
      const sw = el("div", { className: "swatches", title: "Dominant colors" });
      d.pal.forEach(([hex, w]) => sw.append(el("span", { style: `background:${hex};flex:${w}` })));
      body.append(sw);
    }
    if (d.t) body.append(el("p", { className: "caption", textContent: d.t }));
    body.append(el("p", { className: "meta",
      textContent: [d.a ? "@" + d.a : null, PLATFORM_NAMES[d.p] || d.p,
                    d.ts ? "published " + fmtDay(toDate(d.ts)) : null].filter(Boolean).join(", ") }));
    if (d.u) body.append(el("a", { className: "original", href: d.u, target: "_blank", rel: "noopener",
      textContent: `Open on ${PLATFORM_NAMES[d.p] || "the web"}` }));

    body.append(el("h3", { textContent: "What you did" }));
    const ul = el("ul", { className: "history" });
    d.ix.forEach((ix) => ul.append(el("li", { textContent: historyLine(ix) })));
    body.append(ul);

    const c = clusters.get(d.c);
    if (c) {
      body.append(el("h3", { textContent: "Region" }));
      const a = el("button", { className: "chip", textContent: c.label });
      a.onclick = () => openRegion(c);
      body.append(a);
    }
    const nb = (d.nb || []).map((j) => items[j]).filter(Boolean);
    if (nb.length) {
      body.append(el("h3", { textContent: "Nearest in taste" }));
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
    body.append(el("h2", { textContent: c.label }));
    const words = c.terms && c.terms.length ? ` Common words: ${c.terms.slice(0, 5).join(", ")}.` : "";
    body.append(el("p", { className: "meta", textContent: `${c.n.toLocaleString()} items.${words}` }));

    // When this region was active.
    const times = c.members.filter((d) => d.time).map((d) => toDate(d.time));
    if (times.length > 1) {
      const w = 340, h = 56;
      const x = d3.scaleTime().domain(d3.extent(allTimes)).range([0, w]);
      const bins = d3.bin().domain(x.domain()).thresholds(x.ticks(d3.timeMonth.every(3)))(times);
      const y = d3.scaleLinear().domain([0, d3.max(bins, (b) => b.length) || 1]).range([h - 14, 2]);
      const svg = d3.create("svg").attr("viewBox", `0 0 ${w} ${h}`).attr("width", "100%").attr("role", "img")
        .attr("aria-label", "When you engaged with this region");
      svg.append("path").attr("fill", css("--contour")).attr("opacity", 0.6)
        .attr("d", d3.area().curve(d3.curveBasis).x((b) => x(b.x0)).y0(h - 14).y1((b) => y(b.length))(bins));
      svg.append("g").attr("transform", `translate(0,${h - 13})`).attr("class", "timeline-axis")
        .call(d3.axisBottom(x).ticks(5).tickSize(0)).select(".domain").remove();
      body.append(el("h3", { textContent: "When it was on your mind" }), svg.node());
    }
    body.append(el("h3", { textContent: "Most resonant" }));
    const list = [...c.members].sort((a, b) => b.r - a.r || (b.time || 0) - (a.time || 0)).slice(0, 150);
    body.append(gridOf(list, (d) => openItem(d, true)));
    panel.hidden = false;
    panel.scrollTop = 0;
    if (state.view === "terrain") flyTo(c.cx, c.cy, Math.max(transform.k, 2.6));
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
    tlX = d3.scaleTime().domain(tExtent).range([4, w - 4]);
    const months = d3.timeMonth.range(tExtent[0], tExtent[1]);
    const counts = d3.rollup(items.filter((d) => d.time), (v) => v.length, (d) => +d3.timeMonth.floor(toDate(d.time)));
    const y = d3.scaleLinear().domain([0, d3.max(months, (m) => counts.get(+m) || 0) || 1]).range([h - 16, 2]);
    const bw = Math.max(1, (w - 8) / months.length - 0.5);
    tlSvg.append("g").selectAll("rect").data(months).join("rect").attr("class", "timeline-bar")
      .attr("x", (m) => tlX(m)).attr("width", bw)
      .attr("y", (m) => y(counts.get(+m) || 0)).attr("height", (m) => h - 16 - y(counts.get(+m) || 0));
    tlSvg.append("g").attr("class", "timeline-axis").attr("transform", `translate(0,${h - 15})`)
      .call(d3.axisBottom(tlX).ticks(Math.max(2, Math.floor(w / 80))).tickSize(3));
    brush = d3.brushX().extent([[4, 0], [w - 4, h - 16]]).on("brush end", onBrush);
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
    rangeLabel.textContent = state.range
      ? `${fmtMonth(a)} – ${fmtMonth(d3.timeDay.offset(b, -1))}`
      : `All time, ${a.getFullYear()}–${d3.timeDay.offset(b, -1).getFullYear()}`;
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
    playBtn.textContent = "❚❚";
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
  const GEO = ["#c9a66b", "#8fa47a", "#b97a56", "#7d95a8", "#d4c08a", "#9c8f7a",
               "#a7b59a", "#c48f6a", "#6f8a83", "#b8a48c", "#8a9a6a", "#a0887a"];
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
    const order = [...clusters.values()].sort((a, b) => b.n - a.n);
    const keys = order.map((c) => String(c.id));
    const hasUnmapped = unmappedMonths.length > 0;
    if (hasUnmapped) keys.push("unmapped");
    const table = months.map((m) => { const r = { date: m }; keys.forEach((k) => (r[k] = 0)); return r; });
    for (const d of visible) {
      if (!d.time || d.c < 0) continue;
      const i = idx.get(+d3.timeMonth.floor(toDate(d.time)));
      if (i != null) table[i][String(d.c)] += d.r;
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
    defs.append("pattern").attr("id", "hatch").attr("patternUnits", "userSpaceOnUse").attr("width", 6).attr("height", 6)
      .attr("patternTransform", "rotate(45)")
      .append("line").attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 6).attr("stroke", css("--rule")).attr("stroke-width", 3);
    const color = (k) => k === "unmapped" ? "url(#hatch)" : GEO[keys.indexOf(k) % GEO.length];

    if (state.range) {
      svg.append("rect").attr("x", x(state.range[0])).attr("width", Math.max(1, x(state.range[1]) - x(state.range[0])))
        .attr("y", margin.top - 8).attr("height", h - margin.top - margin.bottom + 8)
        .attr("fill", css("--water")).attr("opacity", 0.08);
    }
    const label = (k) => k === "unmapped" ? "Not yet mapped (links still waiting for images)" : clusters.get(+k).label;
    svg.append("g").selectAll("path").data(series).join("path")
      .attr("class", "stratum").attr("fill", (s) => color(s.key)).attr("d", area)
      .on("mousemove", (e, s) => {
        const date = d3.timeMonth.floor(x.invert(d3.pointer(e, node)[0]));
        const i = idx.get(+date);
        const raw = i != null ? table[i][s.key] : 0;
        strataTip.textContent = `${label(s.key)}, ${fmtMonth(date)}: ${s.key === "unmapped" ? raw + " links" : "resonance " + raw.toFixed(1)}`;
        strataTip.hidden = false;
        const [px, py] = d3.pointer(e, node);
        strataTip.style.left = Math.min(px + 12, w - 270) + "px";
        strataTip.style.top = py + 12 + "px";
        svg.selectAll(".stratum").classed("dim", (o) => o !== s);
      })
      .on("mouseleave", () => { strataTip.hidden = true; svg.selectAll(".stratum").classed("dim", false); })
      .on("click", (e, s) => { if (s.key !== "unmapped") openRegion(clusters.get(+s.key)); });

    // Name each layer where it is thickest, if there is room.
    const g = svg.append("g");
    const placed = [];
    const byThickness = series.filter((s) => s.key !== "unmapped").map((s) => {
      let best = -1, bi = 0;
      s.forEach((p, i) => { const t = y(p[0]) - y(p[1]); if (t > best) { best = t; bi = i; } });
      return { s, best, p: s[bi] };
    }).sort((a, b) => b.best - a.best);
    for (const { s, best, p } of byThickness) {
      if (best < 16) continue;
      const lx = Math.min(Math.max(x(p.data.date), margin.left + 60), w - margin.right - 60);
      const ly = (y(p[0]) + y(p[1])) / 2;
      const t = g.append("text").attr("class", "stratum-label").attr("text-anchor", "middle")
        .attr("x", lx).attr("y", ly).attr("dy", "0.35em").text(clusters.get(+s.key).label);
      const b = t.node().getBBox();
      if (placed.some((o) => !(b.x + b.width < o.x || b.x > o.x + o.width || b.y + b.height < o.y || b.y > o.y + o.height))) {
        t.remove();
        continue;
      }
      placed.push(b);
    }
    svg.append("g").attr("class", "strata-axis").attr("transform", `translate(0,${h - margin.bottom})`)
      .call(d3.axisBottom(x).ticks(d3.timeYear.every(1)).tickSize(4));
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
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { requestDraw(); drawTimeline(); drawStrata(); });

  computeContours();
  buildQuadtree();
  resizeMap();
  drawTimeline();

  // Handle for automated tests and the console.
  window.topograph = { data: DATA, clusters, openItem, openRegion, flyTo, setView };
})();
