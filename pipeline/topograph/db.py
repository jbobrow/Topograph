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
  hydrated         integer not null default 0,   -- 0 link only, 1 fetched, -1 unreachable or gone
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

-- Searches float over a map rather than shaping it: curiosity, not taste.
create table if not exists cloud (
  item_id  text not null references item(id) on delete cascade,
  model    text not null,     -- the map it's over, named as in layout
  x        real not null,
  y        real not null,
  region   integer not null,  -- the region under it
  near     text,              -- the land nearest it in meaning (JSON list of item ids)
  primary key (item_id, model)
);

-- Items showing the same picture from different places: one point on the map (same.py).
create table if not exists same_picture (
  item_id  text primary key references item(id) on delete cascade,
  lead     text not null      -- the one that stands for the set on the map; its own row too
);

create table if not exists phrase_vec (
  model  text not null,
  phrase text not null,
  vector blob not null,
  primary key (model, phrase)
);

create table if not exists meta (key text primary key, value text);

create index if not exists interaction_at on interaction(at);
-- Status first, so finding an item's pictures uses it too: by status alone, looking up each
-- item's pictures read every picture there is (minutes on a large library).
drop index if exists media_status;
create index if not exists media_status_item on media(status, item_id);
"""


BUSY_TIMEOUT = 120  # seconds


class Library:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.media_dir = self.root / "media"
        self.media_dir.mkdir(exist_ok=True)
        # Tools can run side by side, like a build during a long hydrate. One waits its turn.
        self.conn = sqlite3.connect(self.root / "topograph.sqlite", timeout=BUSY_TIMEOUT)
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
    # Ids this same thing was stored under before the importer knew better, like an X repost
    # under its own id rather than the post's. They're folded into this one (`absorb`).
    replaces: list[str] = field(default_factory=list)


# How much an item's kind says it has. Merging never moves down.
KIND_RANK = {"link": 0, "text": 1, "image": 2, "video": 2}


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
        # A like says "text" for a post whose pictures were fetched since: still pictures.
        kind = rec.kind if KIND_RANK.get(rec.kind, 0) >= KIND_RANK.get(existing["kind"], 0) else existing["kind"]
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
    for old in rec.replaces:
        absorb(lib, old, rec.id)
    return existing is None


def absorb(lib: Library, old: str, new: str) -> bool:
    """Fold the item stored as `old` into `new`, the same thing under its right id.

    What you did with it moves over. So do its pictures, vectors and place on the map
    when `new` has none, so a repost that was fetched isn't fetched again and the item
    keeps its place until the map is next built. Then `old` goes.
    """
    c = lib.conn
    was = c.execute("select * from item where id=?", (old,)).fetchone()
    if was is None or old == new:
        return False
    c.execute(
        "update item set kind=case when kind in ('link', 'text') and ? in ('image', 'video') then ? else kind end, "
        "author=coalesce(author, ?), text=coalesce(text, ?), hydrated=max(hydrated, ?) where id=?",
        (was["kind"], was["kind"], was["author"], was["text"], was["hydrated"], new))
    c.execute(
        "insert or ignore into interaction(item_id, type, at, at_estimated, collection, source_file) "
        "select ?, type, at, at_estimated, collection, source_file from interaction where item_id=?", (new, old))
    has_pictures = c.execute("select 1 from media where item_id=? and status='ok'", (new,)).fetchone()
    if not has_pictures and c.execute("select 1 from media where item_id=? and status='ok'", (old,)).fetchone():
        c.execute("delete from media where item_id=?", (new,))
        c.execute("update media set item_id=? where item_id=?", (new, old))
    for table in ("embedding", "layout", "cloud"):
        # Per model: a row `new` already has for a model stays, and `old`'s is dropped.
        c.execute(f"update or ignore {table} set item_id=? where item_id=?", (new, old))
    c.execute("delete from item where id=?", (old,))
    return True


# An item is "gone" when the original can't be reached and we have nothing of it:
# no text of its own and no picture. Gone items stay in the library (so a later
# import doesn't bring them back as new, and hydrate doesn't keep retrying) but
# are left off the map, Strata and counts.
GONE_SQL = ("item.hydrated = -1 and coalesce(item.text, '') = '' and not exists "
            "(select 1 from media m where m.item_id = item.id and m.status = 'ok')")

# Items you only searched for. They're clouds over the map, not land.
SEARCH_ONLY_SQL = "select item_id from interaction group by item_id having sum(type != 'search') = 0"


def mark_unavailable(lib: Library) -> int:
    """Clear X's "this post is unavailable" notices that were stored as text.

    Returns how many items turned out to be gone. Their stale embeddings are
    dropped so they leave the map on the next layout.
    """
    from .util import has_words, is_unavailable
    c = lib.conn
    rows = c.execute("select id, text from item where text like '%{learnmore}%' or text like '%unable to view this%' "
                     "or text like 'This Post %' or text like 'This Tweet %'").fetchall()
    ids = [r["id"] for r in rows if is_unavailable(r["text"])]
    # Unreachable posts whose only text is a link: nothing left to show.
    ids += [r["id"] for r in c.execute(
        "select id, text from item where hydrated=-1 and coalesce(text, '') != '' and not exists "
        "(select 1 from media m where m.item_id=item.id and m.status='ok')") if not has_words(r["text"])]
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        q = ",".join("?" * len(chunk))
        c.execute("update item set text=null, hydrated=case when exists (select 1 from media m where "
                  "m.item_id=item.id and m.status='ok') then hydrated else -1 end "
                  f"where id in ({q})", chunk)
    gone = [r[0] for r in c.execute(f"select id from item where {GONE_SQL}")]
    for i in range(0, len(gone), 500):
        chunk = gone[i:i + 500]
        q = ",".join("?" * len(chunk))
        c.execute(f"delete from embedding where item_id in ({q})", chunk)
        c.execute(f"delete from layout where item_id in ({q})", chunk)
        c.execute(f"delete from cloud where item_id in ({q})", chunk)
    c.commit()
    return len(gone)
