"""Your own files: screenshots, downloads and working files on this computer.

Unlike the platform importers this reads folders in place. Most images on a
disk were never made or seen by you (app assets, icon sets, code dependencies),
so each file is kept only when macOS has recorded a signal that it is yours:

  screenshot     flagged as a screen capture, or named like one
  download       carries the web address it came from (kMDItemWhereFroms) or a
                 quarantine record naming the app that saved it
  opened         has a "last used" date: you opened it
  working file   a design, 3D or video file you saved yourself

To leave folders out for good, put a `.topographignore` file in any folder: one
relative path or glob per line (a trailing / means folders only, and a leading !
keeps something an earlier line left out), like .gitignore.

Files are referenced, not copied: the library stores a preview and a thumbnail,
and the item's link points back to the file. Sensitive places (medical, ID,
tax, banking) are skipped by default, and so are downloads from banks and
government sites.
"""

from __future__ import annotations

import hashlib
import os
import plistlib
import re
import struct
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from urllib.parse import quote, urlparse

from ..db import Record
from ..util import plausible_ts

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp", ".svg"}
DESIGN_EXT = {".psd", ".psb", ".ai", ".sketch", ".fig", ".xd", ".afdesign", ".afphoto", ".procreate",
              ".indd", ".pxd", ".blend", ".c4d", ".key"}
FAB_EXT = {".stl", ".3mf", ".obj", ".step", ".stp", ".f3d", ".dxf"}
VIDEO_EXT = {".mp4", ".mov", ".m4v"}
PDF_EXT = {".pdf"}

PRUNE_DIRS = {"node_modules", ".git", "Pods", "DerivedData", ".build", "build", "dist", "venv", ".venv",
              "__pycache__", "site-packages", "vendor", ".next", ".cache", "bower_components", ".gradle",
              "target", ".dropbox.cache", "Library", ".Trash"}
PRUNE_SUFFIXES = (".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace", ".photoslibrary",
                  ".lproj", ".plugin", ".kext", ".docset", ".opvault", ".agilekeychain", ".xcassets",
                  ".imageset", ".appiconset", ".sparsebundle")
# A folder that is itself a project (has one of these) holds project assets.
PROJECT_MARKERS = {".git", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "Podfile",
                   "platformio.ini", "Gemfile", "composer.json", "go.mod"}

SENSITIVE_PATH = re.compile(
    r"(^|/)[^/]*\b(medical|health records?|identification|passports?|id cards?|driver'?s? licen[cs]e|"
    r"tax(es)?|w-?9s?|1099s?|w-?2s?|bank(ing)?|statements?|insurance|legal|lease|payroll|invoices?|"
    r"receipts?|1password|keychain|private|passwords?)\b", re.I)
SENSITIVE_HOST = re.compile(
    r"(\.gov$|\.gov\.|chase|bankofamerica|wellsfargo|citi|amex|americanexpress|capitalone|syf\.com|"
    r"synchrony|discover\.com|intuit|turbotax|irs\.|paypal|venmo|schwab|fidelity|vanguard|"
    r"etrade|robinhood|coinbase|mint\.com|healthcare|mychart|patient|insurance)", re.I)
EXPORT_DIR = re.compile(r"^(twitter-\d{4}-\d{2}-\d{2}|instagram-|facebook-|takeout)", re.I)
SCREENSHOT_NAME = re.compile(r"^(Screen ?Shot|Screenshot|CleanShot|Screen Recording|Capture d’écran)", re.I)
# Quarantine agents that mean "from your own camera or devices".
OWN_AGENTS = {"Photos", "PhotosFileProvider", "Image Capture", "Screenshot", "screencaptureui"}
UNNAMED = re.compile(r"^([0-9a-f]{16,}|[0-9A-F-]{30,}|IMG_\d+|DSC_?\d+|image\d*|unnamed|download(\s*\(\d+\))?|"
                     r"\d{10,}[-_].*|[0-9_\-]{8,})$", re.I)

SF_DATALESS = 0x40000000  # macOS: file content lives only in the cloud


# --- extended attributes ------------------------------------------------------

def _getxattr(path: str, name: str) -> bytes | None:
    if hasattr(os, "getxattr"):
        try:
            return os.getxattr(path, name, follow_symlinks=False)
        except OSError:
            return None
    try:  # macOS: the `xattr` package
        import xattr  # type: ignore
        return xattr.getxattr(path, name, symlink=True)
    except Exception:
        return None


def where_from(path: str) -> list[str]:
    raw = _getxattr(path, "com.apple.metadata:kMDItemWhereFroms")
    if not raw:
        return []
    try:
        val = plistlib.loads(raw)
    except Exception:
        return []
    return [u for u in (val if isinstance(val, list) else [val]) if isinstance(u, str)]


def quarantine(path: str) -> dict | None:
    raw = _getxattr(path, "com.apple.quarantine")
    if not raw:
        return None
    parts = raw.decode("utf-8", errors="ignore").split(";")
    out = {"agent": parts[2] if len(parts) > 2 and parts[2] else None, "at": None}
    try:
        ts = int(parts[1], 16)
        out["at"] = ts if plausible_ts(ts) else None
    except (IndexError, ValueError):
        pass
    return out


def last_used(path: str) -> int | None:
    raw = _getxattr(path, "com.apple.lastuseddate#PS")
    if not raw or len(raw) < 8:
        return None
    ts = struct.unpack("<q", raw[:8])[0]
    return ts if plausible_ts(ts) else None


def is_screen_capture(path: str, name: str) -> bool:
    return bool(SCREENSHOT_NAME.match(name)) or \
        _getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture") is not None


# --- decisions -------------------------------------------------------------------

@dataclass
class Options:
    include_code: bool = False      # images inside code projects
    include_pdf: bool = False
    include_cloud_only: bool = False  # reading these downloads them from the cloud
    include_sensitive: bool = False
    min_bytes: int = 12_000
    min_unsignaled_bytes: int = 40_000  # an image with no signal at all must be at least this big
    exclude: list = field(default_factory=list)  # folders to leave out entirely


@dataclass
class Report:
    kept: Counter = field(default_factory=Counter)
    skipped: Counter = field(default_factory=Counter)
    by_root: dict = field(default_factory=lambda: defaultdict(Counter))
    archives: list = field(default_factory=list)
    sources: Counter = field(default_factory=Counter)
    # Images with no signal, by folder: the ones worth a human look before importing.
    unsignaled_folders: Counter = field(default_factory=Counter)
    left_out: list = field(default_factory=list)  # folders skipped by --exclude or an ignore file


def _created(st) -> int | None:
    now = time.time()
    for ts in (getattr(st, "st_birthtime", None), st.st_mtime):
        if ts and plausible_ts(ts) and ts <= now + 86400:
            return int(ts)
    return None


def _display_name(p: Path) -> str | None:
    stem = re.sub(r"[_]+", " ", p.stem).strip()
    if not stem or UNNAMED.match(p.stem) or SCREENSHOT_NAME.match(p.stem):
        stem = None
    parent = p.parent.name
    if stem and parent:
        return f"{stem}, in {parent}"
    return stem or (f"in {parent}" if parent else None)


def _file_id(path: Path, size: int) -> str:
    h = hashlib.sha1(str(size).encode())
    with open(path, "rb") as f:
        h.update(f.read(256 * 1024))
    return h.hexdigest()[:20]


def classify(path: Path, st, in_project: bool, opts: Options):
    """Return (decision, details). decision is a skip reason or one of the kept kinds."""
    name = path.name
    ext = path.suffix.lower()
    sp = str(path)
    if ext in IMAGE_EXT:
        family = "image"
    elif ext in DESIGN_EXT:
        family = "design"
    elif ext in FAB_EXT:
        family = "3d"
    elif ext in VIDEO_EXT:
        family = "video"
    elif ext in PDF_EXT:
        family = "pdf"
    else:
        return None, {}
    if family == "pdf" and not opts.include_pdf:
        return "skip: PDF (use --include-pdf)", {}
    if not opts.include_sensitive and SENSITIVE_PATH.search(sp):
        return "skip: sensitive folder or name", {}
    if not opts.include_cloud_only and getattr(st, "st_flags", 0) & SF_DATALESS:
        return "skip: only in the cloud", {}
    if st.st_size < opts.min_bytes and family == "image":
        return "skip: tiny (icons, sprites)", {}

    froms = where_from(sp)
    q = quarantine(sp)
    used = last_used(sp)
    shot = is_screen_capture(sp, name)
    url = next((u for u in froms if u.startswith("http")), None)
    host = urlparse(url).hostname if url else None
    if host and not opts.include_sensitive and SENSITIVE_HOST.search(host):
        return "skip: download from a bank or government site", {}
    details = {"family": family, "url": url, "host": host, "agent": (q or {}).get("agent"),
               "downloaded_at": (q or {}).get("at"), "used": used}

    if shot:
        return "screenshot", details
    if q and q.get("agent") in OWN_AGENTS and not url:
        return "your photo", details
    if url or q:
        return "download", details
    if in_project and not opts.include_code and not used:
        return "skip: asset inside a code project", {}
    if family in ("design", "3d", "video"):
        return "working file", details
    if used:
        return "opened image", details
    if st.st_size >= opts.min_unsignaled_bytes:
        return "image, no signal", details
    return "skip: small image nobody opened", {}


TYPE_FOR = {"screenshot": "capture", "your photo": "made", "download": "download",
            "working file": "made", "opened image": "made", "image, no signal": "made"}


def walk(roots, opts: Options, report: Report):
    """Yield (path, stat, decision, details) for candidate files under roots."""
    report_project_dirs.clear()
    excluded = {str(Path(e).expanduser()) for e in opts.exclude}
    for root in roots:
        root = Path(root).expanduser()
        rules: dict[Path, list[str]] = {}
        for dirpath, dirnames, filenames in os.walk(root):
            here = Path(dirpath)
            patterns = read_ignore(here)
            if patterns:
                rules[here] = patterns
            # A folder is part of a code project if it, or any folder above it, has a marker.
            in_project = str(here.parent) in report_project_dirs or \
                any((here / m).exists() for m in PROJECT_MARKERS)
            if in_project:
                report_project_dirs.add(str(here))
            keep = []
            for d in dirnames:
                if d in PRUNE_DIRS or d.startswith(".") or d.endswith(PRUNE_SUFFIXES) or d.endswith("_files"):
                    continue  # "_files": the assets folder of a saved web page
                if str(here / d) in excluded or (rules and ignored(here / d, True, rules)):
                    report.left_out.append(str(here / d))
                    continue
                if EXPORT_DIR.match(d):
                    report.archives.append(str(here / d))
                    continue
                keep.append(d)
            dirnames[:] = keep
            for f in filenames:
                p = here / f
                try:
                    st = p.lstat()
                except OSError:
                    continue
                if not p.is_file() or f == IGNORE_FILE:
                    continue
                if rules and ignored(p, False, rules):
                    continue
                decision, details = classify(p, st, in_project, opts)
                if decision is None:
                    continue
                bucket = report.skipped if decision.startswith("skip") else report.kept
                bucket[decision] += 1
                report.by_root[str(root)][decision] += 1
                if details.get("host"):
                    report.sources[".".join(details["host"].split(".")[-2:])] += 1
                if decision == "image, no signal":
                    report.unsignaled_folders[(str(root),) + p.parent.relative_to(root).parts] += 1
                yield p, st, decision, details


report_project_dirs: set[str] = set()

IGNORE_FILE = ".topographignore"


def read_ignore(folder: Path) -> list[str]:
    """Patterns from a .topographignore in this folder: one path or glob per line, relative
    to the folder; a trailing / matches folders only; # starts a comment."""
    f = folder / IGNORE_FILE
    if not f.is_file():
        return []
    try:
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return [ln.strip() for ln in lines if ln.strip() and not ln.lstrip().startswith("#")]


@lru_cache(maxsize=512)
def _glob(pat: str):
    """Glob to regex where * and ? stay within one folder and ** crosses folders."""
    out, i = "", 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**", i):
            out += ".*"
            i += 2
            continue
        out += "[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c)
        i += 1
    return re.compile(out)


def ignored(path: Path, is_dir: bool, rules: dict) -> bool:
    """Later lines win, and a line starting with ! keeps what an earlier line left out."""
    for base, patterns in rules.items():
        try:
            rel = path.relative_to(base).as_posix()
        except ValueError:
            continue
        verdict = None
        for raw in patterns:
            keep = raw.startswith("!")
            pat = raw[1:] if keep else raw
            dir_only = pat.endswith("/")
            pat = pat.rstrip("/").lstrip("/")
            if dir_only and not is_dir:
                continue
            if _glob(pat).fullmatch(rel) or ("/" not in pat and _glob(pat).fullmatch(path.name)):
                verdict = not keep
        if verdict:
            return True
    return False


def parse(roots, opts: Options, report: Report, preview):
    """Yield Records for kept files. `preview(path) -> (bytes|None, kind)`."""
    for p, st, decision, d in walk(roots, opts, report):
        if decision.startswith("skip"):
            continue
        try:
            fid = _file_id(p, st.st_size)
        except OSError:
            report.skipped["skip: unreadable"] += 1
            continue
        created = _created(st)
        data, kind = preview(p)
        if data is None:
            report.skipped["skip: no preview available"] += 1
            report.kept[decision] -= 1
            continue
        ix = [{"type": TYPE_FOR[decision], "at": d.get("downloaded_at") or created or 0,
               "collection": p.parent.name, "source": str(p)}]
        if d.get("used"):
            ix.append({"type": "open", "at": d["used"], "source": str(p)})
        yield Record(
            id=f"file:{fid}",
            platform="files",
            kind="video" if d["family"] == "video" else "image",
            url="file://" + quote(str(p.resolve())),
            author=d.get("host"),
            text=_display_name(p),
            created_at=created,
            hydrated=1,
            interactions=ix,
            media=[{"ord": 0, "kind": "image", "data": data, "name": p.name,
                    "url": d.get("url")}],
        )


def review_groups(counts: Counter, big: int = 250, max_depth: int = 6) -> list[tuple[str, int]]:
    """Folders to review, split until each line is something a person can judge.

    `counts` maps (root, *parts) -> images directly in that folder. A big group is
    split into its subfolders when no single subfolder holds nearly all of it.
    """
    def total(prefix):
        n = len(prefix)
        return sum(v for k, v in counts.items() if k[:n] == prefix)

    def expand(prefix):
        t = total(prefix)
        n = len(prefix)
        children = Counter()
        for k, v in counts.items():
            if k[:n] == prefix and len(k) > n:
                children[k[: n + 1]] += v
        here = t - sum(children.values())
        if t <= big or n - 1 >= max_depth or not children:
            return [(prefix, t)]
        # One child holding nearly everything: descend without listing the parent.
        if len(children) == 1 or max(children.values()) >= 0.9 * t:
            top = max(children, key=children.get)
            rest = [(prefix + ("(other)",), t - children[top])] if t - children[top] else []
            return expand(top) + rest
        out = []
        for child in children:
            out += expand(child)
        if here:
            out.append((prefix, here))
        return out

    tops = Counter()
    for k, v in counts.items():
        tops[k[:3]] += v                      # root + two folders, as a starting point
    result = []
    for prefix in tops:
        result += expand(prefix)
    named = [(str(Path(*[x for x in k if x != "(other)"])) + (" (other files)" if k[-1] == "(other)" else ""), n)
             for k, n in result]
    return sorted(named, key=lambda kv: -kv[1])


def format_report(report: Report) -> str:
    lines = []
    total_kept = sum(v for v in report.kept.values() if v > 0)
    lines.append(f"Would keep {total_kept:,} files:")
    for k, v in report.kept.most_common():
        if v > 0:
            lines.append(f"  {v:7,}  {k}")
    lines.append(f"Skipping {sum(report.skipped.values()):,}:")
    for k, v in report.skipped.most_common():
        lines.append(f"  {v:7,}  {k[6:]}")
    if report.sources:
        lines.append("Most common download sources: " +
                     ", ".join(f"{h} ({n})" for h, n in report.sources.most_common(8)))
    if report.left_out:
        parents = Counter(str(Path(f).parent) for f in report.left_out)
        lines.append(f"Left out {len(report.left_out):,} folder(s) you excluded:")
        lines += [f"  {n:5,} in {parent}" for parent, n in parents.most_common(8)]
    if report.unsignaled_folders:
        lines.append("Images with no sign of being yours, by folder. If one isn't your work, leave it "
                     "out with --exclude PATH, or list it in a .topographignore file in a folder above it:")
        groups = review_groups(report.unsignaled_folders)
        lines += [f"  {n:7,}  {f}" for f, n in groups[:15]]
    if report.archives:
        lines.append("Platform exports found (import these with `topograph import`):")
        lines += [f"  {a}" for a in report.archives]
    return "\n".join(lines)


if __name__ == "__main__":  # quick dry run: python -m topograph.importers.files ~/Desktop
    rep = Report()
    for _ in walk(sys.argv[1:], Options(), rep):
        pass
    print(format_report(rep))
