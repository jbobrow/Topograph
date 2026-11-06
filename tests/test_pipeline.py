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
    if new_format:
        # Newer exports carry captions and hashtags, so likes can be mapped before hydration.
        assert likes[0].text == "Fog on the ridge ⛰" and likes[0].kind == "text"
        assert likes[1].text == "#ceramics #glaze"
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


# --- Facebook -------------------------------------------------------------------

from fixtures import build_facebook_export  # noqa: E402
from topograph.importers import facebook  # noqa: E402


def test_facebook_parse(tmp_path):
    arch = Archive([build_facebook_export(tmp_path / "fb")])
    assert detect(arch) == ["facebook"]
    recs = list(facebook.parse(arch))
    own = [r for r in recs if r.id.startswith("fb:own:")]
    # The album repeats the first post's photo: same item, so it merges on import.
    ids = [r.id for r in own]
    assert len(set(ids)) == 3
    first = next(r for r in own if r.text and r.text.startswith("First snow"))
    assert first.text == "First snow on the stoop ❄️" and first.media[0]["data"]
    assert any(r.text == "Workshop wall" for r in own)
    assert any(r.kind == "text" and r.text == "Thinking about kinetic sculpture" for r in own)
    saved = next(r for r in recs if r.interactions[0]["type"] == "save")
    assert saved.url == "https://shapeofdesignbook.com/" and saved.text == "The Shape of Design"
    assert any(r.text == "Hand Lettering Daily" for r in recs)
    assert any(r.text == "That joinery!" for r in recs)
    trace = next(r for r in recs if r.kind == "trace")
    assert trace.interactions[0]["type"] == "react"


# --- your files --------------------------------------------------------------------

from topograph.importers import files as files_mod  # noqa: E402


def test_files_classification(tmp_path, monkeypatch):
    from fixtures import image_bytes
    root = tmp_path / "Desktop"
    (root / "Screenshots").mkdir(parents=True)
    (root / "Poster Drafts").mkdir()
    (root / "Taxes 2023").mkdir()
    (root / "my-app" / "assets").mkdir(parents=True)
    (root / "my-app" / "package.json").write_text("{}")
    (root / "Saved Page_files").mkdir()
    big = image_bytes(1, size=(1600, 1200), fmt="PNG")
    # Distinct content: the same bytes in two places are one item.
    (root / "Screenshots" / "Screenshot 2024-05-01 at 10.00.00.png").write_bytes(image_bytes(5, size=(1600, 1200), fmt="PNG"))
    (root / "Poster Drafts" / "poster v2.png").write_bytes(image_bytes(6, "warm", size=(1600, 1200), fmt="PNG"))
    (root / "Poster Drafts" / "from-web.jpg").write_bytes(image_bytes(7, "green", size=(1600, 1200)))
    (root / "Poster Drafts" / "pattern.jpg").write_bytes(big)
    (root / "Taxes 2023" / "w2.png").write_bytes(big)
    (root / "my-app" / "assets" / "hero.png").write_bytes(big)
    (root / "Saved Page_files" / "banner.png").write_bytes(big)
    (root / "icon.png").write_bytes(image_bytes(2, size=(16, 16), fmt="PNG"))

    def fake_xattr(path, name):
        if path.endswith("from-web.jpg") and name.endswith("kMDItemWhereFroms"):
            import plistlib
            return plistlib.dumps(["https://images.example.com/a.jpg", "https://example.com/post"],
                                  fmt=plistlib.FMT_BINARY)
        if path.endswith("from-web.jpg") and name == "com.apple.quarantine":
            return b"0081;6316bc7c;Chrome;ABC"
        if path.endswith("pattern.jpg") and name.endswith("kMDItemWhereFroms"):
            import plistlib
            return plistlib.dumps(["https://secure.chase.com/statement.jpg"], fmt=plistlib.FMT_BINARY)
        if path.endswith("poster v2.png") and name == "com.apple.lastuseddate#PS":
            import struct
            return struct.pack("<qq", 1714557600, 0)
        return None
    monkeypatch.setattr(files_mod, "_getxattr", fake_xattr)

    report = files_mod.Report()
    seen = {p.name: decision for p, st, decision, d in files_mod.walk([root], files_mod.Options(), report)}
    assert seen["Screenshot 2024-05-01 at 10.00.00.png"] == "screenshot"
    assert seen["poster v2.png"] == "opened image"
    assert seen["from-web.jpg"] == "download"
    assert seen["pattern.jpg"].startswith("skip: download from a bank")
    assert seen["w2.png"] == "skip: sensitive folder or name"
    assert seen["hero.png"] == "skip: asset inside a code project"
    assert seen["icon.png"].startswith("skip: tiny")
    assert "banner.png" not in seen                       # saved web page assets are pruned

    # Excluding a folder is honored.
    report = files_mod.Report()
    opts = files_mod.Options(exclude=[str(root / "Poster Drafts")])
    seen = {p.name for p, *_ in files_mod.walk([root], opts, report)}
    assert "poster v2.png" not in seen

    # Importing: the download keeps where it came from.
    libdir = tmp_path / "lib"
    monkeypatch.setattr(files_mod, "_getxattr", fake_xattr)
    cli.main(["--library", str(libdir), "files", str(root)])
    lib = Library(libdir)
    rows = {r["text"]: r for r in lib.conn.execute("select * from item where platform='files'")}
    lib.conn.row_factory = None
    assert "from-web, in Poster Drafts" in rows
    src = lib.conn.execute("select original_url from media m join item i on i.id=m.item_id "
                           "where i.text='from-web, in Poster Drafts'").fetchone()[0]
    assert src == "https://images.example.com/a.jpg"
    types = {r[0] for r in lib.conn.execute("select type from interaction")}
    assert {"capture", "made", "download", "open"} <= types
    lib.close()


def test_files_ignore_file(tmp_path, monkeypatch):
    from fixtures import image_bytes
    monkeypatch.setattr(files_mod, "_getxattr", lambda p, n: None)
    root = tmp_path / "Dropbox"
    (root / "napkin" / "class" / "people" / "someone").mkdir(parents=True)
    (root / "napkin" / "class" / "mine").mkdir(parents=True)
    (root / "napkin" / "class" / "people" / "someone" / "their-work.png").write_bytes(
        image_bytes(8, size=(1600, 1200), fmt="PNG"))
    (root / "napkin" / "class" / "mine" / "my-work.png").write_bytes(image_bytes(9, size=(1600, 1200), fmt="PNG"))
    (root / "napkin" / "class" / "mine" / "scratch.tmp.png").write_bytes(image_bytes(10, size=(1600, 1200), fmt="PNG"))
    (root / "napkin" / "class" / "people" / "me" / "projects").mkdir(parents=True)
    (root / "napkin" / "class" / "people" / "me" / "projects" / "my-page.png").write_bytes(
        image_bytes(11, size=(1600, 1200), fmt="PNG"))
    (root / "napkin" / ".topographignore").write_text(
        "# classmates' pages, not mine\nclass/people/*/\n!class/people/me/\n*.tmp.png\n")
    report = files_mod.Report()
    names = {p.name for p, *_ in files_mod.walk([root], files_mod.Options(), report)}
    assert names == {"my-work.png", "my-page.png"}
    assert report.left_out == [str(root / "napkin" / "class" / "people" / "someone")]


def test_review_groups_split_big_folders():
    from collections import Counter
    c = Counter()
    c[("/D", "napkin", "MIT", "site", "wp")] = 1800
    c[("/D", "napkin", "MIT", "Process")] = 1400
    c[("/D", "napkin", "MIT", "people", "me", "projects")] = 400
    c[("/D", "Personal", "Family", "2015")] = 300
    c[("/D", "Personal", "Family", "2016")] = 310
    groups = dict(files_mod.review_groups(c))
    assert groups["/D/napkin/MIT/site/wp"] == 1800
    assert groups["/D/napkin/MIT/Process"] == 1400
    assert groups["/D/napkin/MIT/people/me/projects"] == 400
    # Family splits by year only because it's big; each year stays one line.
    assert groups["/D/Personal/Family/2016"] == 310


def test_scan_and_site_rules(tmp_path, monkeypatch):
    from fixtures import image_bytes
    monkeypatch.setattr(files_mod, "_getxattr", lambda p, n: None)
    root = tmp_path / "Dropbox"
    scans = root / "Family" / "Scans" / "PATIENT_CT_Scan_2026.04.01"
    wp = root / "site" / "wordpress" / "wp-content"
    for d in (scans, wp / "uploads" / "2014", wp / "themes" / "twenty", root / "site" / "wordpress" / "wp-includes"):
        d.mkdir(parents=True)
    for i, f in enumerate([scans / "slice001.jpg", wp / "uploads" / "2014" / "board.jpg",
                           wp / "themes" / "twenty" / "header.jpg",
                           root / "site" / "wordpress" / "wp-includes" / "bg.jpg"]):
        f.write_bytes(image_bytes(30 + i, size=(1600, 1200), fmt="PNG"))
    report = files_mod.Report()
    opts = files_mod.Options(min_unsignaled_bytes=1000)   # drawn test images compress well
    seen = {p.name: d for p, st, d, _ in files_mod.walk([root], opts, report)}
    assert seen["slice001.jpg"] == "skip: sensitive folder or name"
    assert seen["board.jpg"] == "image, no signal"
    assert "header.jpg" not in seen and "bg.jpg" not in seen


def test_review_groups_count_each_image_once():
    from collections import Counter
    c = Counter({("/D", "Portfolio"): 5, ("/D", "Portfolio", "Old Site"): 225, ("/D",): 48})
    groups = files_mod.review_groups(c)
    assert sum(n for _, n in groups) == 278
    assert len({name for name, _ in groups}) == len(groups)


def test_files_import_survives_bad_files_and_resumes(tmp_path, monkeypatch):
    from fixtures import image_bytes
    monkeypatch.setattr(files_mod, "_getxattr", lambda p, n: None)
    root = tmp_path / "Desktop"
    root.mkdir()
    for i in range(4):
        (root / f"part {i}.stl").write_bytes(f"solid part{i}\n".encode() * 10)
    opts = files_mod.Options()

    def preview(path):
        if path.name == "part 1.stl":
            raise TimeoutError("Quick Look hung")      # must not stop the import
        if path.name == "part 2.stl":
            return None, "image"                       # no preview available
        return image_bytes(len(path.name), fmt="PNG"), "image"

    skipped = []
    report = files_mod.Report()
    recs = list(files_mod.parse(files_mod.collect([root], opts, report), report, preview,
                                on_skip=skipped.append))
    assert {r.text for r in recs} == {"part 0, in Desktop", "part 3, in Desktop"}
    assert len(skipped) == 2

    # A second run skips what was already imported.
    done = {r.id for r in recs}
    report = files_mod.Report()
    again = list(files_mod.parse(files_mod.collect([root], opts, report), report, preview, done))
    assert again == [] and sum(report.already.values()) == 2


# --- regions ------------------------------------------------------------------

def test_regions_nest_and_get_distinct_names():
    import numpy as np
    from topograph.regions import build_tree, key, name_tree, ngrams, tokens

    rng = np.random.default_rng(0)
    topics = ["synth patch sequencer", "kerning typeface specimen", "fern moss garden",
              "senate vote bill", "pinball arcade machine", "sourdough bread crumb",
              "eurorack oscillator module", "lettering brush script", "succulent cactus pot",
              "election ballot county"]
    # Ten blobs in two big groups of five, one topic per blob.
    xy, texts, leaf = [], [], []
    for t, topic in enumerate(topics):
        cx = (t % 5) * 60 + (0 if t < 5 else 600)
        for _ in range(40):
            xy.append([cx + rng.normal(0, 8), 300 + rng.normal(0, 8)])
            texts.append(f"{topic} {rng.choice(['today', 'again', 'lol', ''])}")
            leaf.append(t)
    xy, leaf = np.array(xy), np.array(leaf)
    regions, roots = build_tree(xy, leaf, top=2, branching=3)
    assert len(roots) == 2 and all(len(regions[r].children) == 5 for r in roots)
    assert all(regions[l].parent in roots for l in range(10))

    vecs = np.zeros((len(xy), 4), np.float32)
    name_tree(regions, roots, vecs, texts, np.zeros(len(xy), bool), concepts=["gardens"])
    leaf_names = [regions[l].label for l in range(10)]
    assert len({key(n) for n in leaf_names}) == 10                      # each name used once
    for l, topic in enumerate(topics):
        assert set(regions[l].label.split()) <= set(topic.split()), (l, regions[l].label)
    for r in roots:                                                     # a child never repeats its parent
        assert all(key(regions[k].label) != key(regions[r].label) for k in regions[r].children)

    assert tokens("#GenerativeArt by @someone https://x.co/a") == ["generative", "art", "by"]
    assert "drum machine" in ngrams(tokens("my new drum machine")) and "my new" not in ngrams(tokens("my new"))
    assert key("Houseplants") == key("houseplant")


def test_unavailable_posts_leave_the_map(tmp_path):
    from topograph.db import GONE_SQL, Record, mark_unavailable, upsert_record
    from topograph.util import is_unavailable

    assert is_unavailable("You’re unable to view this Post because this account owner limits who can "
                          "view their Posts. {learnmore}")
    assert is_unavailable("This Post is from a suspended account. {learnmore}")
    assert is_unavailable("This Tweet was deleted by the Tweet author. Learn more")
    assert not is_unavailable("This post is about suspended ceilings")

    lib = Library(tmp_path / "lib")
    notice = "This Post is from a suspended account. {learnmore}"
    for i, text in enumerate([notice, "a real liked post", notice]):
        upsert_record(lib, Record(id=f"x:{i}", platform="x", kind="text", text=text,
                                  interactions=[{"type": "like", "at": 0}]), lambda *a, **k: True)
    lib.conn.execute("insert into embedding(item_id, model, vector) values ('x:0', 'm', x'00')")
    assert mark_unavailable(lib) == 2
    gone = {r[0] for r in lib.conn.execute(f"select id from item where {GONE_SQL}")}
    assert gone == {"x:0", "x:2"}
    assert lib.conn.execute("select count(*) from embedding").fetchone()[0] == 0
    assert lib.conn.execute("select text from item where id='x:1'").fetchone()[0] == "a real liked post"
