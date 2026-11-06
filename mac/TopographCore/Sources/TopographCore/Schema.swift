/// The library's tables, the same as `SCHEMA` in pipeline/topograph/db.py, which stays the
/// reference until the Python tools retire.
public enum LibrarySchema {
    public static let sql = """
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
}
