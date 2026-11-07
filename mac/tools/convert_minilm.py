#!/usr/bin/env python3
"""Turn the text model the maps read words with into a Core ML model the Mac app can run.

The app compares what it computes with vectors the pipeline stored, so the weights must be
the same ones (sentence-transformers/all-MiniLM-L6-v2) and stay 32-bit floats. Texts are given
one at a time, so no padding or attention mask is needed, and the result is the same.

Needs torch, transformers and coremltools (see convert_clip.py for the environment):

    /tmp/convert/bin/pip install coremltools transformers torch
    /tmp/convert/bin/python mac/tools/convert_minilm.py

It goes beside the CLIP model, with the vocabulary the tokenizer reads.
"""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from huggingface_hub import hf_hub_download
from transformers import AutoModel

REPO = "sentence-transformers/all-MiniLM-L6-v2"
DEFAULT_OUT = Path.home() / "Library/Application Support/Topograph/models/minilm-l6-v2"
MAX_TOKENS = 256  # the model's max_seq_length


class Encoder(torch.nn.Module):
    """Mean of the token vectors, at unit length, as sentence-transformers does it."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, tokens):
        tokens = tokens.long()
        # Past the padding logic in BertModel's own forward, which Core ML can't convert.
        hidden = self.model.encoder(self.model.embeddings(input_ids=tokens, token_type_ids=tokens * 0)).last_hidden_state
        return torch.nn.functional.normalize(hidden.mean(1), dim=-1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    model = AutoModel.from_pretrained(REPO, attn_implementation="eager").eval()
    example = torch.ones(1, 12, dtype=torch.int32)
    with torch.no_grad():
        # The shortcut has to give what the whole model gives.
        check = torch.tensor([[101, 7592, 2088, 102]])
        whole = model(input_ids=check).last_hidden_state.mean(1)
        assert torch.allclose(torch.nn.functional.normalize(whole, dim=-1), Encoder(model)(check), atol=1e-5)
        traced = torch.jit.trace(Encoder(model).eval(), example, strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=ct.Shape(shape=(1, ct.RangeDim(1, MAX_TOKENS, default=12))), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
    )
    with tempfile.TemporaryDirectory() as tmp:
        package = Path(tmp) / "text.mlpackage"
        mlmodel.save(str(package))
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), tmp], check=True, stdout=subprocess.DEVNULL)
        out = args.out / "text.mlmodelc"
        if out.exists():
            shutil.rmtree(out)
        args.out.mkdir(parents=True, exist_ok=True)
        shutil.move(str(Path(tmp) / "text.mlmodelc"), out)
    shutil.copy(hf_hub_download(REPO, "vocab.txt"), args.out / "vocab.txt")
    print("Text model:", out)


if __name__ == "__main__":
    main()
