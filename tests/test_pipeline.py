import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fixtures import IG_CODES, X_IDS, build_instagram_export, build_x_archive  # noqa: E402
from topograph import cli  # noqa: E402
from topograph.db import Library  # noqa: E402
from topograph.hydrate import (parse_instagram_embed, parse_instagram_og,  # noqa: E402
                               parse_x_syndication, x_token)
from topograph.importers import detect, instagram, x  # noqa: E402
from topograph.util import (Archive, fix_mojibake, instagram_shortcode,  # noqa: E402
                            instagram_shortcode_time, iso, parse_twitter_date, snowflake_time)


# --- util ---------------------------------------------------------------------

def test_dates_and_ids():
    assert iso(parse_twitter_date("Wed Jul 03 14:23:01 +0000 2024")) == "2024-07-03"
    assert iso(snowflake_time(X_IDS["post1"])) == "2019-09-24"
    assert snowflake_time("12345") is None  # pre-snowflake ids carry no time
    assert instagram_shortcode("https://www.instagram.com/reel/CVa1b2c3d4E/?igsh=x") == "CVa1b2c3d4E"
    assert instagram_shortcode("https://www.instagram.com/someone/p/CK3x9QmnAbC/") == "CK3x9QmnAbC"
    year = int(iso(instagram_shortcode_time("CK3x9QmnAbC"))[:4])
    assert 2020 <= year <= 2021


def test_mojibake():
    assert fix_mojibake("Ferns after rain ð\u009f\u008c¿") == "Ferns after rain 🌿"
    assert fix_mojibake("plain") == "plain"
    assert fix_mojibake("already fine ✨") == "already fine ✨"


# --- X ------------------------------------------------------------------------

@pytest.fixture
def x_archive(tmp_path):
    return Archive([build_x_archive(tmp_path / "twitter.zip")])


def test_x_detect_and_parse(x_archive):
    assert detect(x_archive) == ["x"]
    recs = list(x.parse(x_archive))
    by = {}
    for r in recs:
        by.setdefault(r.id, []).append(r)
    post1 = by[f"x:{X_IDS['post1']}"][0]
    assert post1.kind == "image" and post1.media[0]["data"]
    assert post1.text == "Morning light on the harbor"           # media t.co stripped
    assert post1.interactions[0]["type"] == "post"
    assert "https://example.com/maps" in by[f"x:{X_IDS['post2']}"][0].text  # urls expanded
    assert by[f"x:{X_IDS['reply']}"][0].interactions[0]["type"] == "reply"
    rt = by[f"x:{X_IDS['rt']}"][0]
    assert rt.interactions[0]["type"] == "repost" and rt.author == "cartographer"
    assert f"x:{X_IDS['post3']}" in by                            # from tweets-part1.js
    like = by[f"x:{X_IDS['like1']}"][0]
    assert like.interactions[0]["estimated"] and like.created_at
    types = {r.interactions[0]["type"] for r in by[f"x:{X_IDS['bm1']}"]}
    assert types == {"like", "bookmark"}


# --- Instagram ------------------------------------------------------------------

@pytest.mark.parametrize("new_format", [False, True])
def test_instagram_parse(tmp_path, new_format):
    arch = Archive([build_instagram_export(tmp_path / "ig", new_format=new_format)])
    assert detect(arch) == ["instagram"]
    recs = list(instagram.parse(arch))
    own = [r for r in recs if r.id.startswith("ig:own:")]
    assert len(own) == 2
    assert own[0].text == "Ferns after rain 🌿 café stop" and len(own[0].media) == 2
    assert own[1].text == "Blue hour, Zürich"
    assert own[0].url == "https://www.instagram.com/jb.test/"
    likes = [r for r in recs if r.interactions[0]["type"] == "like"]
    assert {r.id for r in likes} == {f"ig:{IG_CODES[0]}", f"ig:{IG_CODES[1]}"}
    assert likes[0].author == "photographer_a"
    assert likes[0].interactions[0]["at"] == 1610000000
    saves = [r for r in recs if r.interactions[0]["type"] == "save"]
    cols = {r.id: r.interactions[0]["collection"] for r in saves if r.interactions[0]["collection"]}
    assert cols == {f"ig:{IG_CODES[2]}": "Spaces", f"ig:{IG_CODES[3]}": "Spaces"}
    comments = [r for r in recs if r.id.startswith("ig:comment:")]
    assert comments[0].text == "This light is unreal ✨"


# --- hydration parsers ------------------------------------------------------------

def test_x_syndication_parse():
    data = {"text": "Fog", "user": {"screen_name": "someone"},
            "created_at": "2023-04-23T10:00:00.000Z",
            "mediaDetails": [{"type": "photo", "media_url_https": "https://pbs.twimg.com/media/a.jpg"},
                             {"type": "video", "media_url_https": "https://pbs.twimg.com/b.jpg"}]}
    out = parse_x_syndication(data)
    assert out["author"] == "someone" and len(out["media"]) == 2 and out["media"][1]["video"]
    assert iso(out["created_at"]) == "2023-04-23"
    assert x_token(X_IDS["post1"]).isalnum()


def test_instagram_page_parsers():
    embed = ('<div><img class="EmbeddedMediaImage" alt="x" src="https://scontent.cdninstagram.com/a.jpg?x=1&amp;y=2">'
             '<div class="Caption"><a class="CaptionUsername" href="#">studio_b</a> Clay &amp; light<br />'
             'second line<div class="CaptionComments"></div></div></div>')
    out = parse_instagram_embed(embed)
    assert out["media"][0]["url"].endswith("x=1&y=2")
    assert out["author"] == "studio_b" and out["text"].startswith("Clay & light")
    og = ('<meta property="og:image" content="https://cdn/b.jpg" />'
          '<meta property="og:description" content="12 likes, 3 comments - architect_c on March 3, 2023: '
          '&quot;Concrete stairs&quot;. " />')
    out = parse_instagram_og(og)
    assert out["media"][0]["url"] == "https://cdn/b.jpg" and out["author"] == "architect_c"
    assert "Concrete stairs" in out["text"]
    assert parse_instagram_og("<html>login</html>") is None


# --- end to end ---------------------------------------------------------------------

def test_end_to_end(tmp_path, capsys):
    xzip = build_x_archive(tmp_path / "twitter.zip")
    igdir = build_instagram_export(tmp_path / "ig")
    libdir = tmp_path / "lib"
    cli.main(["--library", str(libdir), "import", str(xzip)])
    cli.main(["--library", str(libdir), "import", str(igdir)])

    lib = Library(libdir)
    n_items = lib.conn.execute("select count(*) from item").fetchone()[0]
    n_ix = lib.conn.execute("select count(*) from interaction").fetchone()[0]
    n_media = lib.conn.execute("select count(*) from media where status='ok'").fetchone()[0]
    lib.close()
    assert n_media == 4  # 1 tweet photo + 3 Instagram photos

    # Re-importing is idempotent.
    cli.main(["--library", str(libdir), "import", str(xzip)])
    cli.main(["--library", str(libdir), "import", str(igdir)])
    lib = Library(libdir)
    assert lib.conn.execute("select count(*) from item").fetchone()[0] == n_items
    assert lib.conn.execute("select count(*) from interaction").fetchone()[0] == n_ix
    lib.close()

    cli.main(["--library", str(libdir), "build", "--backend", "lite"])
    data = json.loads((libdir / "topograph.json").read_text())
    assert data["meta"]["placed"] > 0
    assert all(0 <= it["x"] <= 1000.01 for it in data["items"])
    placed = {it["id"] for it in data["items"]}
    assert f"x:{X_IDS['post1']}" in placed                      # image item
    assert f"ig:{IG_CODES[0]}" not in placed                    # bare link: not mapped yet
    assert sum(data["unmapped"].values()) >= 2                  # ...but counted for Strata
    bm = next(it for it in data["items"] if it["id"] == f"x:{X_IDS['bm1']}")
    assert bm["r"] == 4.0                                        # like 1 + bookmark 3
    for it in data["items"]:
        if it["th"]:
            assert (libdir / it["th"]).exists()
