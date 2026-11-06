"""The library: one SQLite file plus a media folder.

The schema mirrors docs/SPEC.md §3 so the native app can open a library
built by this prototype.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field
from pathlib import Path

SCHEMA = """
create table if not exists item (
  id               text primary key,
  platform         text not null,
  kind             text not null default 'link',
  url              text,
  author           text,
  text             text,
  created_at       integer,
  created_estimated integer not null default 0,
  hydrated         integer not null default 0,   -- 0 link only, 1 fetched, -1 unreachable
  hydrate_attempts integer not null default 0
);

create table if not exists interaction (
  item_id      text not null references item(id) on delete cascade,
  type         text not null,
  at           integer not null default 0,
  at_estimated integer not null default 0,
  collection   text,
  source_file  text,
  primary key (item_id, type, at)
);

create table if not exists media (
  item_id      text not null references item(id) on delete cascade,
  ord          integer not null default 0,
  kind         text not null default 'image',     -- image | video
  original_url text,
  content_hash text,
  local_path   text,
  thumb_path   text,
  width        integer,
  height       integer,
  phash        text,
  palette      text,
  status       text not null default 'pending',   -- pending | ok | failed
  primary key (item_id, ord)
);

create table if not exists embedding (
  item_id text not null references item(id) on delete cascade,
  model   text not null,
  vector  blob not null,
  primary key (item_id, model)
);

create table if not exists layout (
  item_id     text not null references item(id) on delete cascade,
  model       text not null,
  x           real not null,
  y           real not null,
  cluster     integer not null,
  neighbors   text,
  primary key (item_id, model)
);

create table if not exists cluster (
  model  text not null,
  id     integer not null,
  label  text,
  terms  text,
  parent integer,          -- the region this one sits inside (null at the top)
  depth  integer not null default 0,
  x      real,             -- where its name goes on the map
  y      real,
  r      real,             -- its size (rms distance of members from its center)
  primary key (model, id)
);

create table if not exists phrase_vec (
  model  text not null,
  phrase text not null,
  vector blob not null,
  primary key (model, phrase)
);

create table if not exists meta (key text primary key, value text);

create index if not exists interaction_at on interaction(at);
create index if not exists media_status on media(status);
"""


class Library:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.media_dir = self.root / "media"
        self.media_dir.mkdir(exist_ok=True)
        self.conn = sqlite3.connect(self.root / "topograph.sqlite")
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("pragma foreign_keys = on")
        self.conn.execute("pragma journal_mode = wal")
        self.conn.executescript(SCHEMA)
        self._migrate()

    def _migrate(self):
        have = {r[1] for r in self.conn.execute("pragma table_info(cluster)")}
        for col, decl in (("parent", "integer"), ("depth", "integer not null default 0"),
                          ("x", "real"), ("y", "real"), ("r", "real")):
            if col not in have:
                self.conn.execute(f"alter table cluster add column {col} {decl}")

    def close(self):
        self.conn.commit()
        self.conn.close()

    # --- meta -------------------------------------------------------------
    def get_meta(self, key, default=None):
        row = self.conn.execute("select value from meta where key=?", (key,)).fetchone()
        return row[0] if row else default

    def set_meta(self, key, value):
        self.conn.execute(
            "insert into meta(key, value) values(?, ?) "
            "on conflict(key) do update set value=excluded.value",
            (key, str(value)),
        )


@dataclass
class Record:
    """One item plus what you did with it, as emitted by an importer."""

    id: str
    platform: str
    kind: str = "link"
    url: str | None = None
    author: str | None = None
    text: str | None = None
    created_at: int | None = None
    created_estimated: bool = False
    hydrated: int = 0
    interactions: list[dict] = field(default_factory=list)
    # each: {"ord": int, "kind": "image"|"video", "data": bytes|None, "url": str|None}
    media: list[dict] = field(default_factory=list)


def upsert_record(lib: Library, rec: Record, ingest_media) -> bool:
    """Insert or merge a record. Returns True when the item is new."""
    c = lib.conn
    existing = c.execute("select * from item where id=?", (rec.id,)).fetchone()
    if existing is None:
        c.execute(
            "insert into item(id, platform, kind, url, author, text, created_at, "
            "created_estimated, hydrated) values (?,?,?,?,?,?,?,?,?)",
            (rec.id, rec.platform, rec.kind, rec.url, rec.author, rec.text,
             rec.created_at, int(rec.created_estimated), rec.hydrated),
        )
    else:
        # Merge: never replace richer data with poorer data.
        kind = existing["kind"] if rec.kind == "link" else rec.kind
        created, estimated = existing["created_at"], existing["created_estimated"]
        if rec.created_at and (created is None or (estimated and not rec.created_estimated)):
            created, estimated = rec.created_at, int(rec.created_estimated)
        c.execute(
            "update item set kind=?, url=coalesce(url, ?), author=coalesce(author, ?), "
            "text=coalesce(text, ?), created_at=?, created_estimated=?, "
            "hydrated=max(hydrated, ?) where id=?",
            (kind, rec.url, rec.author, rec.text, created, estimated, rec.hydrated, rec.id),
        )

    for ix in rec.interactions:
        c.execute(
            "insert or ignore into interaction(item_id, type, at, at_estimated, collection, source_file) "
            "values (?,?,?,?,?,?)",
            (rec.id, ix["type"], int(ix.get("at") or 0), int(bool(ix.get("estimated"))),
             ix.get("collection"), ix.get("source")),
        )

    for m in rec.media:
        have = c.execute(
            "select status from media where item_id=? and ord=?", (rec.id, m["ord"])
        ).fetchone()
        if have and have["status"] == "ok":
            continue
        c.execute(
            "insert or replace into media(item_id, ord, kind, original_url, status) values (?,?,?,?, 'pending')",
            (rec.id, m["ord"], m.get("kind", "image"), m.get("url")),
        )
        if m.get("data") is not None:
            ingest_media(lib, rec.id, m["ord"], m["data"], m.get("kind", "image"), m.get("name"))
    return existing is None
