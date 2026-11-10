"""One thing, one item: a repost joins the post it reposts, and your own Instagram post is
the same item as your like of it. Libraries imported before this are mended on re-import."""

import json
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fixtures import _shim, build_instagram_export, image_bytes  # noqa: E402
from topograph import cli  # noqa: E402
from topograph.db import Library, Record, absorb, upsert_record  # noqa: E402
from topograph.importers import instagram, x  # noqa: E402
from topograph.util import Archive, instagram_shortcode_time  # noqa: E402
from topograph.util import _IG_ALPHABET, INSTAGRAM_EPOCH_MS  # noqa: E402

LIKED = "1750000000000000001"
REPOST = "1760000000000000000"
SOURCE = "1740000000000000000"
REPOST_WITH_PICTURE = "1770000000000000000"
UNLIKED_REPOST = "1780000000000000000"


def x_archive(path: Path) -> Path:
    tw = lambda tid, text, **extra: {"tweet": {"id_str": tid, "id": tid, "full_text": text,
                                                "created_at": "Mon Feb 05 14:00:34 +0000 2024",
                                                "entities": {"urls": []}, **extra}}
    tweets = [
        # Cut short, its link expanded where the like keeps t.co.
        tw(REPOST, "RT @maker: First things first. Enable the flag in settings, then reload https://example.com/a and wa…"),
        tw(REPOST_WITH_PICTURE, "RT @painter: Studio", extended_entities={"media": [
            {"type": "photo", "media_url_https": "https://pbs.twimg.com/media/K.jpg", "source_status_id_str": SOURCE}]}),
        tw(UNLIKED_REPOST, "RT @someone: Something you never liked, only passed on"),
    ]
    likes = [{"like": {"tweetId": LIKED, "fullText": "First things first. Enable the flag in settings, then reload "
                                                     "https://t.co/xyz and watch it go"}}]
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("t/data/account.js", _shim("account", 0, [{"account": {"username": "me"}}]))
        z.writestr("t/data/tweets.js", _shim("tweets", 0, tweets))
        z.writestr("t/data/like.js", _shim("like", 0, likes))
    return path


def test_a_repost_is_the_post_it_reposts(tmp_path):
    every = list(x.parse(Archive([x_archive(tmp_path / "x.zip")])))
    recs = {r.id: r for r in every if r.interactions[0]["type"] == "repost"}
    post = recs[f"x:{LIKED}"]
    assert post.replaces == [f"x:{REPOST}"] and post.author == "maker"
    assert not post.text.startswith("RT @")
    assert recs[f"x:{SOURCE}"].replaces == [f"x:{REPOST_WITH_PICTURE}"]
    # A post you never liked keeps the repost's id: there's nothing to join.
    assert recs[f"x:{UNLIKED_REPOST}"].replaces == []


def test_reimport_mends_a_library(tmp_path):
    lib_dir = tmp_path / "lib"
    lib = Library(lib_dir)
    # As an older import left it: the repost as an item of its own, fetched and mapped.
    upsert_record(lib, Record(id=f"x:{REPOST}", platform="x", kind="image", text="RT @maker: First things",
                              hydrated=1, interactions=[{"type": "repost", "at": 1707141634}]), lambda *a: None)
    lib.conn.execute("insert into media(item_id, ord, thumb_path, status) values (?, 0, 'media/aa/t.webp', 'ok')",
                     (f"x:{REPOST}",))
    lib.conn.execute("insert into layout(item_id, model, x, y, cluster) values (?, 'm', 1, 2, 3)", (f"x:{REPOST}",))
    lib.close()

    cli.main(["--library", str(lib_dir), "import", str(x_archive(tmp_path / "x.zip")), "--platform", "x"])
    lib = Library(lib_dir)
    c = lib.conn
    assert c.execute("select count(*) from item where id=?", (f"x:{REPOST}",)).fetchone()[0] == 0
    types = {r[0] for r in c.execute("select type from interaction where item_id=?", (f"x:{LIKED}",))}
    assert types == {"like", "repost"}
    # Its picture and place came along, so it isn't fetched again or lost from the map.
    assert c.execute("select thumb_path from media where item_id=?", (f"x:{LIKED}",)).fetchone()[0] == "media/aa/t.webp"
    assert c.execute("select x from layout where item_id=?", (f"x:{LIKED}",)).fetchone()[0] == 1
    assert c.execute("select kind from item where id=?", (f"x:{LIKED}",)).fetchone()[0] == "image"
    n = c.execute("select count(*) from item").fetchone()[0]
    lib.close()

    cli.main(["--library", str(lib_dir), "import", str(x_archive(tmp_path / "x.zip")), "--platform", "x"])
    lib = Library(lib_dir)
    assert lib.conn.execute("select count(*) from item").fetchone()[0] == n
    lib.close()


def test_absorb_keeps_what_the_item_already_has(tmp_path):
    lib = Library(tmp_path / "lib")
    c = lib.conn
    for i in ("a", "b"):
        c.execute("insert into item(id, platform, text) values (?, 'x', ?)", (i, f"text {i}"))
        c.execute("insert into media(item_id, ord, thumb_path, status) values (?, 0, ?, 'ok')", (i, f"{i}.webp"))
        c.execute("insert into layout(item_id, model, x, y, cluster) values (?, 'm', 0, 0, 0)", (i,))
    assert absorb(lib, "a", "b")
    assert c.execute("select text from item where id='b'").fetchone()[0] == "text b"
    assert [r[0] for r in c.execute("select thumb_path from media")] == ["b.webp"]
    assert c.execute("select count(*) from layout").fetchone()[0] == 1
    assert not absorb(lib, "a", "b")
    lib.close()


def shortcode_at(ts: int) -> str:
    n = ((ts * 1000 - INSTAGRAM_EPOCH_MS) << 23) + 12345
    code = ""
    for _ in range(11):
        code = _IG_ALPHABET[n % 64] + code
        n //= 64
    return code


def test_your_post_you_liked_is_one_item(tmp_path):
    root = build_instagram_export(tmp_path / "ig", new_format=True)
    code = shortcode_at(1620000000)       # the first post in the export
    assert instagram_shortcode_time(code) == 1620000000
    likes_file = root / "your_instagram_activity" / "likes" / "liked_posts.json"
    likes = json.loads(likes_file.read_text())
    likes.append({"timestamp": 1620000500, "media": [], "label_values": [
        {"label": "URL", "value": f"https://www.instagram.com/p/{code}/", "href": f"https://www.instagram.com/p/{code}/"},
        {"label": "Caption", "value": "Ferns after rain"},
        {"dict": [{"dict": [{"label": "Username", "value": "jb.test"}], "title": ""}], "title": "Owner"}]})
    likes_file.write_text(json.dumps(likes))

    recs = list(instagram.parse(Archive([root])))
    mine = [r for r in recs if r.id == f"ig:{code}"]
    assert {r.interactions[0]["type"] for r in mine} == {"post", "like"}
    post = next(r for r in mine if r.interactions[0]["type"] == "post")
    assert post.url == f"https://www.instagram.com/p/{code}/" and post.replaces[0].startswith("ig:own:")
    # The other post, which you didn't like, keeps its own id.
    assert sum(r.id.startswith("ig:own:") for r in recs) == 1
