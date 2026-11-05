"""Local media cache: an optimized display copy and a thumbnail per image.

Files are stored by content hash, so the same picture saved three times is
stored once. Videos are represented by a poster frame (needs ffmpeg).
"""

from __future__ import annotations

import hashlib
import io
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import imagehash
from PIL import Image, ImageOps

from .config import DISPLAY_EDGE, THUMB_EDGE

try:  # iPhone exports are often HEIC
    import pillow_heif  # type: ignore
    pillow_heif.register_heif_opener()
except ImportError:
    pass

Image.MAX_IMAGE_PIXELS = 200_000_000


def video_poster(data: bytes) -> bytes | None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.mp4"
        out = Path(tmp) / "poster.jpg"
        src.write_bytes(data)
        for seek in ("1", "0"):
            subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-ss", seek, "-i", str(src),
                            "-frames:v", "1", "-q:v", "3", str(out)],
                           capture_output=True, timeout=60)
            if out.exists() and out.stat().st_size:
                return out.read_bytes()
    return None


VIDEO_SUFFIXES = {".mp4", ".mov", ".m4v", ".webm"}


PREVIEW_TIMEOUT = 20  # seconds; Quick Look can hang on a big or unusual file


def _run(cmd) -> bool:
    """Run a preview tool; a hang or crash means "no preview", never a failed import."""
    try:
        subprocess.run(cmd, capture_output=True, timeout=PREVIEW_TIMEOUT)
        return True
    except (subprocess.TimeoutExpired, OSError):
        return False


def _quicklook(path: Path, size: int = 1600) -> bytes | None:
    """macOS Quick Look renders previews for PSD, AI, Sketch, PDF, STL, 3MF and more."""
    ql = shutil.which("qlmanage")
    if not ql:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        if not _run([ql, "-t", "-s", str(size), "-o", tmp, str(path)]):
            return None
        outs = list(Path(tmp).glob("*.png"))
        return outs[0].read_bytes() if outs else None


def preview_from_path(path: Path) -> tuple[bytes | None, str]:
    """An image to represent any local file: the file itself, a video frame, or a Quick Look preview.

    Returns (bytes or None, kind).
    """
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix in VIDEO_SUFFIXES:
        ffmpeg = shutil.which("ffmpeg")
        if ffmpeg:
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "poster.jpg"
                for seek in ("1", "0"):
                    if not _run([ffmpeg, "-loglevel", "error", "-y", "-ss", seek, "-i", str(path),
                                 "-frames:v", "1", "-q:v", "3", str(out)]):
                        break
                    if out.exists() and out.stat().st_size:
                        return out.read_bytes(), "video"
        return _quicklook(path), "video"
    if suffix != ".svg":
        try:
            with Image.open(path) as im:
                im.verify()
            return path.read_bytes(), "image"
        except Exception:
            pass
    return _quicklook(path), "image"


def palette(img: Image.Image, n: int = 5) -> list[list]:
    """Dominant colors as [[hex, weight], ...], heaviest first."""
    small = img.copy()
    small.thumbnail((96, 96))
    q = small.quantize(colors=n, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette()[: n * 3]
    counts = sorted(q.getcolors(), reverse=True)
    total = sum(c for c, _ in counts) or 1
    out = []
    for count, idx in counts[:n]:
        r, g, b = pal[idx * 3: idx * 3 + 3]
        out.append([f"#{r:02x}{g:02x}{b:02x}", round(count / total, 3)])
    return out


def _resized(img: Image.Image, edge: int) -> Image.Image:
    im = img.copy()
    im.thumbnail((edge, edge), Image.Resampling.LANCZOS)
    return im


def ingest(lib, item_id: str, ord_: int, data: bytes, kind: str = "image", name: str | None = None) -> bool:
    """Process raw bytes into the cache and record them. Returns success."""
    c = lib.conn
    if kind == "video" or (name and Path(name).suffix.lower() in {".mp4", ".mov", ".m4v", ".webm"}):
        poster = video_poster(data)
        if poster is None:
            c.execute("update media set status='failed' where item_id=? and ord=?", (item_id, ord_))
            return False
        data, kind = poster, "video"

    digest = hashlib.sha256(data).hexdigest()
    shard = lib.media_dir / digest[:2]
    disp_path = shard / f"{digest}-d.webp"
    thumb_path = shard / f"{digest}-t.webp"
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img)
        if img.mode not in ("RGB", "RGBA"):
            img = img.convert("RGBA" if "transparency" in img.info else "RGB")
        if img.mode == "RGBA":
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[3])
            img = bg
    except Exception:
        c.execute("update media set status='failed' where item_id=? and ord=?", (item_id, ord_))
        return False

    if not disp_path.exists():
        shard.mkdir(exist_ok=True)
        _resized(img, DISPLAY_EDGE).save(disp_path, "WEBP", quality=82, method=4)
        _resized(img, THUMB_EDGE).save(thumb_path, "WEBP", quality=76, method=4)

    c.execute(
        "update media set content_hash=?, local_path=?, thumb_path=?, width=?, height=?, "
        "phash=?, palette=?, status='ok', kind=? where item_id=? and ord=?",
        (digest, disp_path.relative_to(lib.root).as_posix(),
         thumb_path.relative_to(lib.root).as_posix(), img.width, img.height,
         str(imagehash.phash(img)), json.dumps(palette(img)), kind, item_id, ord_),
    )
    return True
