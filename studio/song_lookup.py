"""Optional online lookup. Transcription and music workers remain offline.

Metadata and subtitle parsing never contact a provider. Recognition is isolated
in a small environment; only the explicit identify endpoint invokes it.
"""
import html
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata

import httpx


def lookup_installed(root):
    return (root / ".lookup-venv/bin/python").is_file() and any(
        (root / ".lookup-venv/lib").glob("python*/site-packages/shazamio/api.py"))


def parse_lyrics(text, extension=".txt"):
    """Remove subtitle timing/markup, preserving repeated sung lines and sections."""
    extension = extension.lower()
    lines = text.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    result = []
    in_vtt_metadata = False
    for index, line in enumerate(lines):
        line = line.strip()
        if extension == ".vtt":
            if line.startswith(("NOTE", "STYLE", "REGION")):
                in_vtt_metadata = True
                continue
            if in_vtt_metadata:
                if not line:
                    in_vtt_metadata = False
                continue
            if line.startswith(("WEBVTT", "Kind:", "Language:", "X-TIMESTAMP-MAP")):
                continue
        if extension in {".srt", ".vtt"}:
            if "-->" in line or (line and index + 1 < len(lines) and "-->" in lines[index + 1]):
                continue
        if extension == ".lrc":
            if re.match(r"^\[(?:ar|ti|al|by|offset|length|re|ve):", line, re.I):
                continue
            line = re.sub(r"\[\d+:\d+(?:[.:]\d+)?\]", "", line)
            line = re.sub(r"<\d+:\d+(?:[.:]\d+)?>", "", line)
        if extension in {".srt", ".vtt", ".lrc"}:
            line = html.unescape(re.sub(r"<[^>]*>|\{\\[^}]*\}", "", line))
        if line or (result and result[-1]):
            result.append(line)
    lyrics = "\n".join(result).strip()
    if not lyrics:
        raise ValueError("No lyric text was found in that file. Paste the words instead.")
    if len(lyrics) > 18000:
        raise ValueError("Import lyrics up to 18,000 characters.")
    return lyrics


def audio_metadata(path, name):
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration:format_tags=title,artist,album", "-of", "json", str(path)],
        capture_output=True, text=True, timeout=20, check=True,
    )
    info = json.loads(probe.stdout).get("format", {})
    duration = float(info.get("duration", 0))
    if not math.isfinite(duration) or not 0 < duration <= 900:
        raise ValueError("Choose an audio file up to 15 minutes long.")
    tags = {k.lower(): str(v) for k, v in info.get("tags", {}).items()}
    title = tags.get("title", "")
    artist = tags.get("artist", "")
    if not title:
        filename = Path(name).stem if Path(name).suffix.lower() in {".wav", ".flac", ".mp3", ".aiff", ".aif", ".m4a"} else name
        filename = re.sub(r"^\d+[. _-]+", "", filename)
        if " - " in filename:
            guessed_artist, title = filename.split(" - ", 1)
            artist = artist or guessed_artist
        else:
            title = filename
    return {"title": title[:300], "artist": artist[:300], "duration": duration,
            "method": "tags" if tags.get("title") else "filename"}


def recognize(path, root):
    python = root / ".lookup-venv/bin/python"
    if not lookup_installed(root):
        return {"title": "", "artist": "", "note": "Audio identification is not installed yet. You can search by song name or install lookup in Settings."}
    # Decode a bounded excerpt locally, avoiding loading a whole long file in RAM.
    with tempfile.TemporaryDirectory(dir=root / ".cache/tmp", prefix="identify-") as directory:
        excerpt = Path(directory) / "excerpt.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-t", "24", "-ac", "1", "-ar", "16000", str(excerpt)],
                       check=True, capture_output=True, timeout=20)
        process = subprocess.run([str(python), "-m", "studio.recognize", str(excerpt)],
                                 cwd=root, capture_output=True, text=True, timeout=35)
        if process.returncode:
            return {"title": "", "artist": "", "note": "Online identification is unavailable. Check the song details and search for lyrics, or import a lyric file."}
        return json.loads(process.stdout)


def normalized(value):
    return re.sub(r"\W+", "", unicodedata.normalize("NFKC", value).casefold())


def search_lyrics(title, artist="", duration=0):
    if not title.strip():
        raise ValueError("Enter a song title to look for lyrics.")
    params = {"track_name": title.strip()}
    if artist.strip():
        params["artist_name"] = artist.strip()
    with httpx.Client(timeout=15, headers={"User-Agent": "Moonshift/0.1 (personal local music app)"}) as client:
        response = client.get("https://lrclib.net/api/search", params=params)
        response.raise_for_status()
        records = response.json()
    if not isinstance(records, list):
        raise ValueError("The lyric service returned an unexpected response. Import or paste lyrics instead.")
    def rank(record):
        exact = normalized(record.get("trackName", "")) == normalized(title)
        same_artist = bool(artist) and normalized(record.get("artistName", "")) == normalized(artist)
        difference = abs(float(record.get("duration") or 0) - duration) if duration else 0
        return (not exact, not same_artist, difference)
    candidates = []
    for record in sorted(records, key=rank):
        text = record.get("plainLyrics") or record.get("syncedLyrics") or ""
        if not text or record.get("instrumental"):
            continue
        try:
            lyrics = parse_lyrics(text, ".txt" if record.get("plainLyrics") else ".lrc")
        except ValueError:
            continue
        candidates.append({"id": record["id"], "title": record.get("trackName", ""),
                           "artist": record.get("artistName", ""), "album": record.get("albumName", ""),
                           "duration": record.get("duration") or 0, "lyrics": lyrics,
                           "source": f"https://lrclib.net/api/get/{record['id']}"})
        if len(candidates) == 6:
            break
    return candidates
