#!/usr/bin/env python3
"""Turn the CLIP model the pipeline uses into Core ML models the Mac app can run.

The app compares what it computes with vectors the pipeline stored, so the weights
must be the same ones (OpenCLIP ViT-B-32, laion2b_s34b_b79k) and stay 32-bit floats:
16-bit weights would move every vector a little.

Needs torch, open_clip_torch and coremltools. coremltools doesn't install on the
Python the pipeline uses, so give this its own environment:

    python3.13 -m venv /tmp/convert
    /tmp/convert/bin/pip install coremltools open_clip_torch torch
    /tmp/convert/bin/python mac/tools/convert_clip.py

The result is about 600 MB, too large for the repository, and goes beside the
library. It uses weights already on disk and only downloads them if they aren't.
"""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
import open_clip
import torch

DEFAULT_OUT = Path.home() / "Library/Application Support/Topograph/models/clip-vit-b-32"


class ImageEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixels):
        return self.model.encode_image(pixels)


class TextEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, tokens):
        return self.model.encode_text(tokens.long())


def convert(module, example, input_type, out: Path):
    traced = torch.jit.trace(module.eval(), example, strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[input_type],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
    )
    with tempfile.TemporaryDirectory() as tmp:
        package = Path(tmp) / f"{out.stem}.mlpackage"
        mlmodel.save(str(package))
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), tmp], check=True,
                       stdout=subprocess.DEVNULL)
        if out.exists():
            shutil.rmtree(out)
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(Path(tmp) / f"{out.stem}.mlmodelc"), out)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    model, _, _ = open_clip.create_model_and_transforms("ViT-B-32", pretrained="laion2b_s34b_b79k")
    model.eval()

    with torch.no_grad():
        pixels = torch.zeros(1, 3, 224, 224)
        print("Image encoder:", convert(
            ImageEncoder(model), pixels,
            ct.TensorType(name="pixels", shape=pixels.shape, dtype=np.float32),
            args.out / "image.mlmodelc"))
        tokens = open_clip.get_tokenizer("ViT-B-32")(["a photo of a topographic map"]).int()
        print("Text encoder:", convert(
            TextEncoder(model), tokens,
            ct.TensorType(name="tokens", shape=tokens.shape, dtype=np.int32),
            args.out / "text.mlmodelc"))


if __name__ == "__main__":
    main()
