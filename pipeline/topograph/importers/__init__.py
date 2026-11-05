"""Platform importers. Each module exposes detect(archive) and parse(archive)."""

from . import instagram, x

IMPORTERS = {"x": x, "instagram": instagram}


def detect(archive):
    return [name for name, mod in IMPORTERS.items() if mod.detect(archive)]
