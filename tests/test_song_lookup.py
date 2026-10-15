import json
from pathlib import Path
import subprocess

import httpx
import pytest
from fastapi.testclient import TestClient

from studio import server, song_lookup
from studio.models import Project


@pytest.mark.parametrize("extension,text,expected", [
    (".srt", "1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>Come home</i>\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,000\r\nCome home", "Come home\n\nCome home"),
    (".lrc", "[ar:Artist]\n[ti:Title]\n[offset:0]\n[00:01.20]Come <00:02.00>home\n[00:04.20][00:06.00]Come home\n[Chorus]\nStay", "Come home\nCome home\n[Chorus]\nStay"),
    (".vtt", "WEBVTT\n\nNOTE ignore this\nprivate cue note\n\nintro\n00:01.000 --> 00:03.000 align:start\n<v Singer>Come &amp; stay</v>\n\n00:04.000 --> 00:06.000\nCome &amp; stay", "Come & stay\n\nCome & stay"),
    (".ttml", '<?xml version="1.0" encoding="UTF-8"?><tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word"><head><metadata><iTunesMetadata><translations><translation><text for="L1">Ignore me</text></translation></translations></iTunesMetadata></metadata></head><body><div itunes:song-part="Verse"><p begin="1.0" end="3.0"><span begin="1.0" end="1.5">Come</span> <span begin="1.5" end="2.0">ho</span><span begin="2.0" end="3.0">me</span><span ttm:role="x-bg"><span>stay</span></span></p><p>Rock &amp; roll<br/>Again</p></div><div itunes:song-part="PreChorus"><p>Come home</p></div><div><p>Come home</p></div></body></tt>', "[Verse]\nCome home (stay)\nRock & roll\nAgain\n\n[Pre-Chorus]\nCome home\n\nCome home"),
    (".txt", "\ufeff[Verse]\n123\nCome home\n\n[Chorus]\nCome home", "[Verse]\n123\nCome home\n\n[Chorus]\nCome home"),
])
def test_subtitle_formats_preserve_sung_repetition(extension, text, expected):
    assert song_lookup.parse_lyrics(text, extension) == expected


def test_empty_and_oversized_lyrics_are_rejected():
    with pytest.raises(ValueError):
        song_lookup.parse_lyrics("1\n00:01:00,000 --> 00:01:01,000", ".srt")
    with pytest.raises(ValueError):
        song_lookup.parse_lyrics("x" * 18001)
    with pytest.raises(ValueError):
        song_lookup.parse_lyrics('<!DOCTYPE tt [<!ENTITY a "aaaa">]><tt><body><p>&a;</p></body></tt>', ".ttml")
    with pytest.raises(ValueError):
        song_lookup.parse_lyrics("<tt><body><p>Unclosed</body></tt>", ".ttml")


def test_metadata_is_local_and_falls_back_to_filename(monkeypatch, tmp_path):
    monkeypatch.setattr(song_lookup, "probe", lambda path: (123.5, {"title": "Tagged song", "artist": "Tagged artist"}))
    result = song_lookup.audio_metadata(tmp_path / "song.wav", "File title")
    assert result == {"title": "Tagged song", "artist": "Tagged artist", "duration": 123.5, "method": "tags"}
    monkeypatch.setattr(song_lookup, "probe", lambda path: (120.0, {}))
    result = song_lookup.audio_metadata(tmp_path / "song.wav", "01 Artist - Song.mp3")
    assert result["title"] == "Song" and result["artist"] == "Artist" and result["method"] == "filename"


def test_metadata_refuses_nonfinite_and_long_audio(monkeypatch, tmp_path):
    for duration in [float("nan"), float("inf"), 901.0, 0.0]:
        monkeypatch.setattr(song_lookup, "probe", lambda path: (duration, {}))
        with pytest.raises(ValueError):
            song_lookup.audio_metadata(tmp_path / "song.wav", "song")


def test_ffmpeg_summary_gives_duration_and_file_tags_only():
    from studio.audio import describe
    summary = """Input #0, mp3, from 'song.mp3':
  Metadata:
    title           : Come Home
    ARTIST          : The Singer: Live
    album           : Late
  Duration: 00:04:11.05, start: 0.025057, bitrate: 226 kb/s
  Stream #0:0: Audio: mp3, 44100 Hz, stereo, fltp, 226 kb/s
      Metadata:
        encoder         : Lavc
    title           : Not a file tag
At least one output file must be specified
"""
    duration, tags = describe(summary)
    assert duration == pytest.approx(251.05)
    assert tags == {"title": "Come Home", "artist": "The Singer: Live", "album": "Late"}
    with pytest.raises(ValueError):
        describe("song.txt: Invalid data found when processing input")


def test_lookup_rank_and_payload_never_send_audio(monkeypatch):
    seen = []
    records = [
        {"id": 1, "trackName": "Home", "artistName": "Other", "duration": 121, "plainLyrics": "Wrong artist"},
        {"id": 2, "trackName": "Home", "artistName": "Singer", "duration": 100, "plainLyrics": "Other version"},
        {"id": 3, "trackName": "Home", "artistName": "Singer", "duration": 120, "syncedLyrics": "[00:01.00]Come home\n[00:03.00]Come home"},
        {"id": 4, "trackName": "Home", "artistName": "Singer", "instrumental": True},
    ]
    def request(req):
        seen.append(req)
        return httpx.Response(200, json=records)
    real_client = httpx.Client
    monkeypatch.setattr(song_lookup.httpx, "Client", lambda **kwargs: real_client(transport=httpx.MockTransport(request), **kwargs))
    result = song_lookup.search_lyrics("Home", "Singer", 121)
    assert [r["id"] for r in result] == [3, 2, 1]
    assert result[0]["lyrics"] == "Come home\nCome home"
    assert seen[0].url.host == "lrclib.net" and not seen[0].content
    assert dict(seen[0].url.params) == {"track_name": "Home", "artist_name": "Singer"}


def test_cover_endpoints_keep_offline_import_and_online_lookup_separate(monkeypatch, tmp_path):
    monkeypatch.setattr(server, "DATA", tmp_path)
    (tmp_path / "imports").mkdir()
    source = tmp_path / "imports/song.wav"
    source.write_bytes(b"audio")
    client = TestClient(server.app)
    calls = []
    monkeypatch.setattr(song_lookup, "recognize", lambda *a: calls.append("recognize") or {"title": "Song", "artist": "Singer", "note": "Possible match"})
    monkeypatch.setattr(song_lookup, "audio_metadata", lambda *a: {"title": "Song", "artist": "Singer", "duration": 100, "method": "tags"})
    assert client.post("/api/cover/metadata", json={"source": "imports/song.wav"}).status_code == 200
    parsed = client.post("/api/cover/lyrics/import", json={"text": "[00:01.00]Words", "extension": ".lrc"})
    assert parsed.json()["lyrics"] == "Words" and calls == []
    assert client.post("/api/cover/lyrics/import", json={"text": "Words", "extension": ".exe"}).status_code == 400
    assert client.post("/api/cover/identify", json={"source": "../../outside.wav"}).status_code == 404
    assert calls == []
    assert client.post("/api/cover/identify", json={"source": "imports/song.wav"}).status_code == 200
    assert calls == ["recognize"]
    assert client.post("/api/cover/identify", json={"source": "imports/song.wav"}, headers={"origin": "https://example.com"}).status_code == 403
    monkeypatch.setattr(song_lookup, "search_lyrics", lambda *a: (_ for _ in ()).throw(httpx.ConnectError("offline")))
    assert client.post("/api/cover/lyrics/search", json={"title": "Song"}).status_code == 503


def test_cover_provenance_survives_saved_project_and_old_sessions_still_load():
    project = Project(app_mode="covers", song_title="Home", song_artist="Singer", lyrics_source="Imported.lrc", cover_preset="Vintage soul", engine="metal-q4", nar_chunk_frames=0, max_tokens=4500)
    assert Project.model_validate_json(project.model_dump_json()) == project
    old = Project.model_validate({"title": "Old session", "concept": "retired field", "device": "mps", "engine": "torch"})
    assert old.app_mode == "studio" and old.engine == "auto"


def test_shared_service_tracks_both_apps_and_does_not_exit_early(monkeypatch):
    monkeypatch.setattr(server, "CLIENTS", {})
    monkeypatch.setenv("MOONSHIFT_MANAGED", "1")
    timers = []
    monkeypatch.setattr(server.threading, "Timer", lambda *args: timers.append(args) or type("Timer", (), {"start": lambda self: None})())
    assert server.attach_client("studio")["remaining"] == 1
    assert server.attach_client("covers")["remaining"] == 2
    assert server.release_client("studio")["remaining"] == 1 and not timers
    assert server.release_client("covers")["remaining"] == 0 and len(timers) == 1
