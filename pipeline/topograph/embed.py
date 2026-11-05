"""Embeddings: one vector per item in a shared image-text space.

Backends
  clip  OpenCLIP ViT-B/32 (LAION-2B). Uses Apple's Metal (MPS) on a Mac.
        Image items embed the image, blended with the caption when present;
        text-only items embed the text. Recommended.
  lite  No machine learning model: color/texture statistics for images and
        hashed word counts for text. For testing, or machines without torch.
"""

from __future__ import annotations

import hashlib
import re
from collections import defaultdict

import numpy as np
from PIL import Image

IMAGE_WEIGHT = 0.75  # image vs caption when an item has both

WORD_RX = re.compile(r"[a-z][a-z0-9']+")


def _norm(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-9)


class LiteBackend:
    name = "lite-v1"
    dim = 256

    def images(self, paths):
        out = []
        for p in paths:
            im = Image.open(p).convert("RGB").resize((32, 32))
            a = np.asarray(im, dtype=np.float32) / 255.0
            hsv = np.asarray(im.convert("HSV"), dtype=np.float32) / 255.0
            hist = np.concatenate([
                np.histogram(hsv[..., 0], 24, (0, 1), weights=hsv[..., 1])[0],
                np.histogram(hsv[..., 1], 8, (0, 1))[0],
                np.histogram(hsv[..., 2], 8, (0, 1))[0],
            ])
            gy, gx = np.gradient(a.mean(-1))
            tex = np.histogram(np.arctan2(gy, gx), 16, (-np.pi, np.pi), weights=np.hypot(gx, gy))[0]
            small = np.asarray(im.resize((8, 8)), dtype=np.float32).ravel() / 255.0
            v = np.concatenate([hist / 1024, tex, small])
            v = np.pad(v, (0, self.dim - len(v)))[: self.dim]
            out.append(v)
        return _norm(np.array(out, dtype=np.float32))

    def texts(self, texts):
        out = np.zeros((len(texts), self.dim), dtype=np.float32)
        for i, t in enumerate(texts):
            for w in WORD_RX.findall(t.lower()):
                h = int(hashlib.md5(w.encode()).hexdigest(), 16)
                out[i, h % self.dim] += 1 if (h >> 64) & 1 else -1
        return _norm(out)

    def concept_scores(self, vectors, concepts):
        return None  # lite vectors don't share a space with text


class ClipBackend:
    name = "clip-vit-b-32"
    dim = 512

    def __init__(self, batch_size: int = 32):
        import open_clip
        import torch
        self.torch = torch
        if torch.backends.mps.is_available():
            self.device = "mps"
        elif torch.cuda.is_available():
            self.device = "cuda"
        else:
            self.device = "cpu"
        self.model, _, self.preprocess = open_clip.create_model_and_transforms(
            "ViT-B-32", pretrained="laion2b_s34b_b79k", device=self.device)
        self.model.eval()
        self.tokenizer = open_clip.get_tokenizer("ViT-B-32")
        self.batch_size = batch_size

    def images(self, paths):
        out = []
        with self.torch.no_grad():
            for i in range(0, len(paths), self.batch_size):
                batch = [self.preprocess(Image.open(p).convert("RGB")) for p in paths[i:i + self.batch_size]]
                x = self.torch.stack(batch).to(self.device)
                out.append(self.model.encode_image(x).float().cpu().numpy())
        return _norm(np.concatenate(out)) if out else np.zeros((0, self.dim), np.float32)

    def texts(self, texts):
        out = []
        with self.torch.no_grad():
            for i in range(0, len(texts), self.batch_size * 4):
                toks = self.tokenizer(texts[i:i + self.batch_size * 4]).to(self.device)
                out.append(self.model.encode_text(toks).float().cpu().numpy())
        return _norm(np.concatenate(out)) if out else np.zeros((0, self.dim), np.float32)

    def concept_scores(self, vectors, concepts):
        prompts = [f"an image of {c}" for c in concepts]
        return vectors @ self.texts(prompts).T


def get_backend(name: str):
    if name == "lite":
        return LiteBackend()
    if name == "clip":
        return ClipBackend()
    raise ValueError(f"Unknown backend {name!r} (use 'clip' or 'lite')")


def auto_backend() -> str:
    try:
        import open_clip  # noqa: F401
        import torch  # noqa: F401
        return "clip"
    except ImportError:
        return "lite"


def embed_library(lib, backend, log=print, force: bool = False) -> int:
    c = lib.conn
    if force:
        c.execute("delete from embedding where model=?", (backend.name,))
    rows = c.execute(
        "select i.id, i.text from item i where i.kind != 'trace' and not exists "
        "(select 1 from embedding e where e.item_id=i.id and e.model=?)", (backend.name,)).fetchall()
    media = defaultdict(list)
    for m in c.execute("select item_id, local_path from media where status='ok' order by ord"):
        if len(media[m["item_id"]]) < 4:
            media[m["item_id"]].append(lib.root / m["local_path"])

    todo_img = [(r["id"], r["text"]) for r in rows if media.get(r["id"])]
    todo_txt = [(r["id"], r["text"]) for r in rows if not media.get(r["id"]) and r["text"]]
    from .progress import Progress
    total = len(todo_img) + len(todo_txt)
    if not total:
        lib.set_meta("embedding_model", backend.name)
        c.commit()
        return 0
    with Progress("Reading images and captions", total=total, unit="items") as prog:

        done = 0
        chunk = 64   # small batches keep the progress line moving
        for start in range(0, len(todo_img), chunk):
            part = todo_img[start:start + chunk]
            paths, owners = [], []
            for idx, (iid, _) in enumerate(part):
                for p in media[iid]:
                    paths.append(p)
                    owners.append(idx)
            img_vecs = backend.images(paths)
            agg = np.zeros((len(part), backend.dim), np.float32)
            np.add.at(agg, owners, img_vecs)
            agg = _norm(agg)
            captions = [(k, t) for k, (_, t) in enumerate(part) if t]
            if captions:
                tv = backend.texts([t[:300] for _, t in captions])
                for (k, _), v in zip(captions, tv):
                    agg[k] = IMAGE_WEIGHT * agg[k] + (1 - IMAGE_WEIGHT) * v
                agg = _norm(agg)
            c.executemany("insert or replace into embedding(item_id, model, vector) values (?,?,?)",
                          [(iid, backend.name, agg[k].astype(np.float32).tobytes())
                           for k, (iid, _) in enumerate(part)])
            c.commit()
            done += len(part)
            prog.advance(len(part), note="images")

        for start in range(0, len(todo_txt), 256):
            part = todo_txt[start:start + 256]
            tv = backend.texts([t[:300] for _, t in part])
            c.executemany("insert or replace into embedding(item_id, model, vector) values (?,?,?)",
                          [(iid, backend.name, tv[k].astype(np.float32).tobytes())
                           for k, (iid, _) in enumerate(part)])
            c.commit()
            done += len(part)
            prog.advance(len(part), note="text")
        lib.set_meta("embedding_model", backend.name)
        c.commit()
        prog.close(f"{len(todo_img):,} images, {len(todo_txt):,} text items")
    return done
