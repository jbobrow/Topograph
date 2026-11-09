"""YouTube and Google Takeout, and Bluesky and Are.na sync, on fixtures. No network."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))

from topograph import cli  # noqa: E402
from topograph.db import Library  # noqa: E402
from topograph.hydrate import hydrate_youtube  # noqa: E402
from topograph.importers import detect, google, youtube  # noqa: E402
from topograph.sync import ARENA, BSKY_APP, BSKY_PDS, Fetcher, run  # noqa: E402
from topograph.util import Archive  # noqa: E402


def takeout(root: Path) -> Path:
    yt = root / "Takeout" / "YouTube and YouTube Music"
    (yt / "history").mkdir(parents=True)
    (yt / "history" / "watch-history.json").write_text(json.dumps([
        {"header": "YouTube", "title": "Watched How risograph works", "titleUrl": "https://www.youtube.com/watch?v=abc123DEF",
         "subtitles": [{"name": "Print Shop", "url": "x"}], "time": "2024-01-02T03:04:05.000Z"},
        {"header": "YouTube", "title": "Watched a video that has been removed", "time": "2024-01-03T03:04:05.000Z"},
    ]))
    (yt / "playlists").mkdir()
    (yt / "playlists" / "Liked videos-videos.csv").write_text(
        "Video ID,Playlist Video Creation Timestamp\nabc123DEF,2024-02-01T00:00:00+00:00\n")
    (yt / "playlists" / "Type-videos.csv").write_text(
        "Video ID,Playlist Video Creation Timestamp\nxyz789GHI,2024-03-01T00:00:00+00:00\n")
    (yt / "playlists" / "playlists.csv").write_text("Playlist ID,Title\nP1,Type\n")
    (yt / "comments").mkdir()
    (yt / "comments" / "comments.csv").write_text(
        "Comment ID,Channel ID,Comment Create Timestamp,Video ID,Comment Text\nc1,ch,2024-04-01T00:00:00+00:00,xyz789GHI,Nice\n")

    for product, rows in {
        "Search": [
            {"title": "Searched for foggy coastline", "titleUrl": "https://google.com/search?q=foggy", "time": "2023-01-01T00:00:00Z"},
            {"title": "Searched for Foggy Coastline", "time": "2023-06-01T00:00:00Z"},
            {"title": "Searched for mri results lab", "time": "2023-01-02T00:00:00Z"},
            {"title": "Visited Some site", "time": "2023-01-03T00:00:00Z"},
        ],
        "Image Search": [{"title": "Searched for hand drawn type", "time": "2023-02-01T00:00:00Z"}],
        "Chrome": [{"title": "Searched for something in chrome", "time": "2023-03-01T00:00:00Z"}],
    }.items():
        folder = root / "Takeout" / "My Activity" / product
        folder.mkdir(parents=True)
        (folder / "MyActivity.json").write_text(json.dumps(rows))
    return root


def test_detects_both_from_one_takeout(tmp_path):
    assert set(detect(Archive([takeout(tmp_path)]))) == {"youtube", "google"}


def test_youtube_merges_a_videos_interactions(tmp_path):
    records = list(youtube.parse(Archive([takeout(tmp_path)])))
    assert {r.id for r in records} == {"youtube:abc123DEF", "youtube:xyz789GHI"}
    watched = next(r for r in records if r.interactions[0]["type"] == "view")
    assert (watched.text, watched.author) == ("How risograph works", "Print Shop")
    saved = next(r for r in records if r.interactions[0]["type"] == "save")
    assert saved.interactions[0]["collection"] == "Type"
    assert {r.interactions[0]["type"] for r in records} == {"view", "like", "save", "comment"}


def test_youtube_thumbnail_comes_from_the_id():
    found = hydrate_youtube({"id": "youtube:abc123DEF"})
    assert found["media"][0]["url"] == "https://i.ytimg.com/vi/abc123DEF/hqdefault.jpg"


def test_google_reads_searches_only_and_skips_sensitive_ones(tmp_path):
    records = list(google.parse(Archive([takeout(tmp_path)])))
    assert sorted({r.text.lower() for r in records}) == ["foggy coastline", "hand drawn type"]
    again = [r for r in records if r.text.lower() == "foggy coastline"]
    assert len({r.id for r in again}) == 1, "the same search twice is one item"
    assert all(r.platform == "google" and r.hydrated == 1 for r in records)


def test_cli_imports_takeout_into_one_library(tmp_path):
    lib_dir = tmp_path / "lib"
    cli.main(["--library", str(lib_dir), "import", str(takeout(tmp_path / "t"))])
    lib = Library(lib_dir)
    counts = dict(lib.conn.execute("select platform, count(*) from item group by platform").fetchall())
    assert counts == {"youtube": 2, "google": 2}
    types = {r[0] for r in lib.conn.execute("select type from interaction where item_id='youtube:abc123DEF'")}
    assert types == {"view", "like"}
    lib.close()


def fake(pages):
    calls = []

    def opener(url):
        calls.append(url)
        for prefix, body in pages:
            if url.startswith(prefix):
                return json.dumps(body).encode()
        raise AssertionError(f"unexpected request: {url}")
    return opener, calls


def post(uri, handle="ann.test", did="did:me", text="hello", images=()):
    embed = {"images": [{"fullsize": i} for i in images]} if images else None
    return {"uri": uri, "author": {"did": did, "handle": handle},
            "record": {"text": text, "createdAt": "2024-05-01T00:00:00Z"}, "embed": embed}


def test_bluesky_reads_posts_reposts_and_likes(tmp_path):
    opener, _ = fake([
        (f"{BSKY_APP}/com.atproto.identity.resolveHandle", {"did": "did:me"}),
        (f"{BSKY_APP}/app.bsky.feed.getAuthorFeed", {"feed": [
            {"post": post("at://did:me/app.bsky.feed.post/1")},
            {"post": post("at://did:other/app.bsky.feed.post/2", handle="bo.test", did="did:other"),
             "reason": {"$type": "app.bsky.feed.defs#reasonRepost", "indexedAt": "2024-06-01T00:00:00Z"}},
        ]}),
        (f"{BSKY_PDS}/com.atproto.repo.listRecords", {"records": [
            {"value": {"subject": {"uri": "at://did:other/app.bsky.feed.post/3"}, "createdAt": "2024-07-01T00:00:00Z"}}]}),
        (f"{BSKY_APP}/app.bsky.feed.getPosts", {"posts": [
            post("at://did:other/app.bsky.feed.post/3", handle="bo.test", did="did:other", images=["https://cdn.test/a.jpg"])]}),
    ])
    lib = Library(tmp_path)
    seen, new = run(lib, "bluesky", "ann.test", fetcher=Fetcher(delay=0, opener=opener, sleep=lambda s: None))
    assert (seen, new) == (3, 3)
    types = sorted(r[0] for r in lib.conn.execute("select type from interaction"))
    assert types == ["like", "post", "repost"]
    assert lib.conn.execute("select original_url from media").fetchone()[0] == "https://cdn.test/a.jpg"
    lib.close()


def test_arena_reads_blocks_as_saves_in_their_channel(tmp_path):
    opener, _ = fake([
        (f"{ARENA}/users/ann/channels", {"channels": [{"slug": "spaces", "title": "Spaces"}], "total_pages": 1}),
        (f"{ARENA}/channels/spaces/contents", {"contents": [
            {"id": 7, "base_class": "Block", "class": "Image", "title": "A room", "created_at": "2024-01-01T00:00:00Z",
             "image": {"large": {"url": "https://cdn.test/room.jpg"}}, "user": {"slug": "ann"}},
            {"id": 8, "base_class": "Channel", "class": "Channel", "title": "nested"},
        ]}),
    ])
    lib = Library(tmp_path)
    seen, _ = run(lib, "arena", "ann", fetcher=Fetcher(delay=0, opener=opener, sleep=lambda s: None))
    assert seen == 1
    row = lib.conn.execute("select type, collection from interaction").fetchone()
    assert (row[0], row[1]) == ("save", "Spaces")
    lib.close()


def test_fetcher_waits_between_requests_and_stops_after_ten_failures():
    import urllib.error
    waits = []

    def failing(url):
        raise urllib.error.URLError("offline")
    fetcher = Fetcher(delay=1.5, opener=failing, sleep=waits.append)
    stopped = False
    for _ in range(10):
        try:
            fetcher.json("https://x.test", "a")
        except urllib.error.URLError:
            pass
        except SystemExit:
            stopped = True
    assert stopped and waits == [1.5] * 10


def test_searches_are_clouds_not_land(tmp_path):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from fixtures import build_x_archive
    lib_dir = tmp_path / "lib"
    args = ["--library", str(lib_dir)]
    cli.main(args + ["import", str(build_x_archive(tmp_path / "twitter.zip")), "--platform", "x"])
    cli.main(args + ["import", str(takeout(tmp_path / "t"))])
    cli.main(args + ["build", "--backend", "lite"])
    lib = Library(lib_dir)
    land = {r[0] for r in lib.conn.execute("select item_id from layout")}
    clouds = {r[0] for r in lib.conn.execute("select item_id from cloud")}
    searches = {r[0] for r in lib.conn.execute("select id from item where platform = 'google'")}
    lib.close()
    assert searches and clouds == searches and not land & searches
    assert land, "the rest is still land"
    exported = json.loads((lib_dir / "topograph.json").read_text())
    assert len(exported["clouds"]) == len(searches)
    searched = {"2023-01", "2023-02", "2023-06"}   # when the fixture's searches were made
    assert not searched & set(exported["unmapped"]), "clouds aren't waiting to be mapped"
