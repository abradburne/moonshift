"""Optional online lookup. Transcription and music workers remain offline.

Metadata and subtitle parsing never contact a provider. Recognition is isolated
in a small environment; only the explicit identify endpoint invokes it.
"""
import html
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata
from xml.etree import ElementTree

import httpx

from .audio import duration_within_limit, ffmpeg, probe
from .paths import CODE


def lookup_installed(root):
    return (root / ".lookup-venv/bin/python").is_file() and any(
        (root / ".lookup-venv/lib").glob("python*/site-packages/shazamio/api.py"))


def parse_lyrics(text, extension=".txt"):
    """Remove subtitle timing/markup, preserving repeated sung lines and sections."""
    extension = extension.lower()
    if extension == ".ttml":
        return checked_lyrics(ttml_lyrics(text))
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
    return checked_lyrics("\n".join(result))


def checked_lyrics(lyrics):
    lyrics = lyrics.strip()
    if not lyrics:
        raise ValueError("No lyric text was found in that file. Paste the words instead.")
    if len(lyrics) > 18000:
        raise ValueError("Import lyrics up to 18,000 characters.")
    return lyrics


def ttml_lyrics(text):
    """Read timed-text lyrics (as Apple Music exports them): each <p> is a line,
    each <div> a stanza, labelled by its song part when the file names one."""
    # TTML never declares entities, and refusing them keeps expansion attacks out.
    if re.search(r"<!(?:DOCTYPE|ENTITY)", text, re.I):
        raise ValueError("That TTML file could not be read.")
    try:
        root = ElementTree.fromstring(text.lstrip("\ufeff"))
    except ElementTree.ParseError:
        raise ValueError("That TTML file could not be read.")

    def local(name):
        return name.rsplit("}", 1)[-1]

    def attribute(element, *names):
        return next((value for key, value in element.attrib.items()
                     if local(key).replace("-", "").lower() in names), "")

    def words(element):
        parts = [element.text or ""]
        for child in element:
            tag, role = local(child.tag), attribute(child, "role")
            if tag == "br":
                parts.append("\n")
            elif tag == "span" and role not in {"x-translation", "x-roman"}:
                inner = words(child)
                # Background vocals sit beside the lead line, in brackets.
                if role == "x-bg" and inner.strip():
                    inner = inner.strip()
                    inner = f" {inner}" if inner.startswith("(") else f" ({inner})"
                parts.append(inner)
            parts.append(child.tail or "")
        return "".join(parts)

    body = next((element for element in root.iter() if local(element.tag) == "body"), None)
    if body is None:
        raise ValueError("No lyric text was found in that file. Paste the words instead.")
    # A stanza is whichever element holds the lines directly, however deeply divs nest.
    stanzas = [element for element in body.iter() if any(local(child.tag) == "p" for child in element)]
    result = []
    for stanza in stanzas:
        lines = [" ".join(line.split()) for p in stanza if local(p.tag) == "p" for line in words(p).split("\n")]
        lines = [line for line in lines if line]
        if not lines:
            continue
        part = attribute(stanza, "songpart")
        if part:
            lines.insert(0, "[" + re.sub(r"(?<=[a-z])(?=[A-Z])", "-", part.strip()) + "]")
        if result:
            result.append("")
        result.extend(lines)
    return "\n".join(result)


def audio_metadata(path, name):
    duration, tags = probe(path)
    if not duration_within_limit(duration):
        raise ValueError("Choose an audio file up to 15 minutes long.")
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
        subprocess.run([ffmpeg(), "-v", "error", "-nostdin", "-i", str(path), "-t", "24", "-ac", "1", "-ar", "16000", str(excerpt)],
                       check=True, capture_output=True, timeout=20)
        process = subprocess.run([str(python), "-m", "studio.recognize", str(excerpt)],
                                 cwd=CODE, capture_output=True, text=True, timeout=35)
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
