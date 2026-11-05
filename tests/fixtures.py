"""Builders for small, realistic export archives used by the tests.

They follow the shapes of real exports (including Instagram's mis-encoded
text and both of its record formats) with procedurally drawn images.
"""

from __future__ import annotations

import io
import json
import random
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw


def mojibake(s: str) -> str:
    """What Instagram does to non-ASCII text."""
    return s.encode("utf-8").decode("latin-1")


def image_bytes(seed: int, theme: str = "warm", size=(480, 360), fmt="JPEG") -> bytes:
    rnd = random.Random(seed)
    base = {"warm": (230, 140, 80), "cool": (60, 110, 200), "green": (70, 160, 90)}[theme]
    im = Image.new("RGB", size, tuple(max(0, min(255, c + rnd.randint(-30, 30))) for c in base))
    d = ImageDraw.Draw(im)
    for _ in range(12):
        x, y = rnd.randint(0, size[0]), rnd.randint(0, size[1])
        r = rnd.randint(10, 80)
        col = tuple(max(0, min(255, c + rnd.randint(-80, 80))) for c in base)
        (d.ellipse if theme != "cool" else d.rectangle)([x - r, y - r, x + r, y + r], fill=col)
    buf = io.BytesIO()
    im.save(buf, fmt, quality=85)
    return buf.getvalue()


def _shim(feed: str, part: int, data) -> str:
    return f"window.YTD.{feed}.part{part} = " + json.dumps(data, indent=2)


# Real-looking snowflake ids (2019–2024).
X_IDS = {
    "post1": "1176551392934137857",   # 2019-09-24
    "post2": "1352010011145928704",   # 2021-01-20
    "reply": "1479111234567890944",   # 2022-01-06
    "rt": "1600000000000000000",      # 2022-12-06
    "post3": "1750000000000000000",   # 2024-01-24
    "like1": "1234567890123456789",   # 2020-03-02
    "like2": "1700000000000000000",   # 2023-09-08
    "bm1": "1650000000000000000",     # 2023-04-23
}


def build_x_archive(path: Path) -> Path:
    tw = lambda key, text, created, **extra: {"tweet": {
        "id_str": X_IDS[key], "id": X_IDS[key], "full_text": text, "created_at": created,
        "entities": extra.pop("entities", {"urls": [], "user_mentions": []}), **extra}}
    media_key = "EAbCdEf123"
    tweets_part0 = [
        tw("post1", "Morning light on the harbor https://t.co/abc123", "Tue Sep 24 08:12:00 +0000 2019",
           extended_entities={"media": [{"type": "photo",
                                         "media_url_https": f"https://pbs.twimg.com/media/{media_key}.jpg",
                                         "url": "https://t.co/abc123"}]}),
        tw("post2", "Reading about map projections — https://t.co/xyz is great",
           "Wed Jan 20 16:00:00 +0000 2021",
           entities={"urls": [{"url": "https://t.co/xyz", "expanded_url": "https://example.com/maps"}]}),
        tw("reply", "@friend agreed, the contour lines make it", "Thu Jan 06 10:00:00 +0000 2022",
           in_reply_to_status_id_str="1479000000000000000", in_reply_to_screen_name="friend"),
    ]
    tweets_part1 = [
        tw("rt", "RT @cartographer: A topographic map of nowhere in particular",
           "Tue Dec 06 12:00:00 +0000 2022"),
        tw("post3", "New year, new sketchbook", "Wed Jan 24 09:30:00 +0000 2024"),
    ]
    likes = [
        {"like": {"tweetId": X_IDS["like1"], "fullText": "Hand-drawn type specimen, 1923",
                  "expandedUrl": f"https://twitter.com/i/web/status/{X_IDS['like1']}"}},
        {"like": {"tweetId": X_IDS["like2"], "fullText": "",
                  "expandedUrl": f"https://twitter.com/i/web/status/{X_IDS['like2']}"}},
        # Liking your own repost's original shows up as the same id twice.
        {"like": {"tweetId": X_IDS["bm1"], "fullText": "Fog over the ridge at dawn"}},
    ]
    bookmarks = [{"bookmark": {"tweetId": X_IDS["bm1"]}}]
    account = [{"account": {"username": "jb_test", "accountId": "42", "displayName": "JB"}}]

    with zipfile.ZipFile(path, "w") as z:
        root = "twitter-2026-11-05-abc/"
        z.writestr(root + "Your archive.html", "<html></html>")
        z.writestr(root + "data/account.js", _shim("account", 0, account))
        z.writestr(root + "data/tweets.js", _shim("tweets", 0, tweets_part0))
        z.writestr(root + "data/tweets-part1.js", _shim("tweets", 1, tweets_part1))
        z.writestr(root + "data/like.js", _shim("like", 0, likes))
        z.writestr(root + "data/bookmark.js", _shim("bookmark", 0, bookmarks))
        z.writestr(root + f"data/tweets_media/{X_IDS['post1']}-{media_key}.jpg", image_bytes(1, "warm"))
    return path


IG_CODES = ["CK3x9QmnAbC", "CVa1b2c3d4E", "Cq9ZzYyXxWv", "C1aBcDeFgHi", "DAbcdefghij"]


def build_instagram_export(path: Path, new_format: bool = False) -> Path:
    """An unzipped Instagram export folder (old or new record format)."""
    act = path / "your_instagram_activity"
    (act / "content").mkdir(parents=True)
    (act / "likes").mkdir()
    (act / "saved").mkdir()
    (act / "comments").mkdir()
    (path / "personal_information" / "personal_information").mkdir(parents=True)
    media_dir = path / "media" / "posts" / "202105"
    media_dir.mkdir(parents=True)

    (path / "personal_information" / "personal_information" / "personal_information.json").write_text(
        json.dumps({"profile_user": [{"string_map_data": {"Username": {"value": "jb.test"}}}]}))

    (media_dir / "111.jpg").write_bytes(image_bytes(11, "green"))
    (media_dir / "112.jpg").write_bytes(image_bytes(12, "green"))
    (media_dir / "113.jpg").write_bytes(image_bytes(13, "cool"))
    posts = [
        {"media": [{"uri": "media/posts/202105/111.jpg", "creation_timestamp": 1620000000, "title": ""},
                   {"uri": "media/posts/202105/112.jpg", "creation_timestamp": 1620000000, "title": ""}],
         "title": mojibake("Ferns after rain 🌿 café stop"), "creation_timestamp": 1620000000},
        {"media": [{"uri": "media/posts/202105/113.jpg", "creation_timestamp": 1621000000,
                    "title": mojibake("Blue hour, Zürich")}]},
    ]
    (act / "content" / "posts_1.json").write_text(json.dumps(posts))

    if not new_format:
        likes = {"likes_media_likes": [
            {"title": "photographer_a", "string_list_data": [
                {"href": f"https://www.instagram.com/p/{IG_CODES[0]}/", "value": "ð\u009f\u0091\u008d",
                 "timestamp": 1610000000}]},
            {"title": "studio_b", "string_list_data": [
                {"href": f"https://www.instagram.com/reel/{IG_CODES[1]}/", "value": "x", "timestamp": 1650000000}]},
        ]}
        saved = {"saved_saved_media": [
            {"title": "architect_c", "string_map_data": {"Saved on": {
                "href": f"https://www.instagram.com/p/{IG_CODES[2]}/", "timestamp": 1680000000}}},
        ]}
    else:
        likes = [
            {"timestamp": 1610000000, "media": [], "label_values": [
                {"label": "URL", "value": f"https://www.instagram.com/p/{IG_CODES[0]}/",
                 "href": f"https://www.instagram.com/p/{IG_CODES[0]}/"},
                {"label": "Owner", "title": "", "dict": [{"dict": [
                    {"label": "Username", "value": "photographer_a"}]}]}]},
            {"timestamp": 1650000000, "media": [], "label_values": [
                {"label": "URL", "value": f"https://www.instagram.com/reel/{IG_CODES[1]}/",
                 "href": f"https://www.instagram.com/reel/{IG_CODES[1]}/"}]},
        ]
        saved = {"saved_saved_media": [
            {"title": "architect_c", "string_map_data": {"Saved on": {
                "href": f"https://www.instagram.com/p/{IG_CODES[2]}/", "timestamp": 1680000000}}}]}
    collections = {"saved_saved_collections": [
        {"title": "Collection", "string_map_data": {"Name": {"value": "Spaces"},
                                                    "Creation Time": {"timestamp": 1679000000}}},
        {"title": "architect_c", "string_map_data": {"Name": {"value": "architect_c"}, "Added Time": {
            "href": f"https://www.instagram.com/p/{IG_CODES[2]}/", "timestamp": 1680000000}}},
        {"title": "interiors_d", "string_map_data": {"Name": {"value": "interiors_d"}, "Added Time": {
            "href": f"https://www.instagram.com/p/{IG_CODES[3]}/", "timestamp": 1690000000}}},
    ]}
    comments = [{"string_map_data": {
        "Comment": {"value": mojibake("This light is unreal ✨")},
        "Media Owner": {"value": "photographer_a"},
        "Time": {"timestamp": 1611000000}}}]

    (act / "likes" / "liked_posts.json").write_text(json.dumps(likes))
    (act / "saved" / "saved_posts.json").write_text(json.dumps(saved))
    (act / "saved" / "saved_collections.json").write_text(json.dumps(collections))
    (act / "comments" / "post_comments_1.json").write_text(json.dumps(comments))
    return path
