"""Platform importers. Each module exposes detect(archive) and parse(archive).

`files` is different: it reads folders on this computer in place (see files.py).
"""

from . import facebook, google, instagram, x, youtube

IMPORTERS = {"x": x, "instagram": instagram, "facebook": facebook, "youtube": youtube, "google": google}


def detect(archive):
    return [name for name, mod in IMPORTERS.items() if mod.detect(archive)]
