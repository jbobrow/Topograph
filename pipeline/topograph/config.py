"""Defaults shared across the pipeline."""

import os
import sys
from pathlib import Path

# How much each kind of interaction says about your taste (see docs/SPEC.md §3).
INTERACTION_WEIGHTS = {
    "bookmark": 3.0,
    "save": 3.0,
    "post": 2.5,
    "repost": 2.0,
    "reply": 1.5,
    "comment": 1.5,
    "like": 1.0,
    "view": 0.3,
    "search": 0.2,
}

DISPLAY_EDGE = 1600  # long edge of the display copy, px
THUMB_EDGE = 320     # long edge of the grid thumbnail, px

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.5 Safari/605.1.15"
)


def default_library() -> Path:
    env = os.environ.get("TOPOGRAPH_LIBRARY")
    if env:
        return Path(env).expanduser()
    if sys.platform == "darwin":
        return Path("~/Library/Application Support/Topograph").expanduser()
    return Path("~/.topograph").expanduser()
