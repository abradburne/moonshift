"""Reading recordings with FFmpeg. Imports nothing beyond the standard library,
so both the service and the transcription environment can use it."""
import math
import re
import shutil
import subprocess

from .paths import HOME


def ffmpeg():
    """The FFmpeg that setup installed, or one already on the PATH."""
    installed = HOME / ".runtime/bin/ffmpeg"
    return str(installed) if installed.is_file() else shutil.which("ffmpeg") or "ffmpeg"


def describe(text):
    """Duration in seconds and lower-cased tags from FFmpeg's summary of a file."""
    length = re.search(r"^\s*Duration: (\d+):(\d+):(\d+(?:\.\d+)?)", text, re.M)
    if not length:
        raise ValueError("FFmpeg could not read this recording.")
    hours, minutes, seconds = length.groups()
    duration = int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    tags = {}
    # File-level tags sit above the duration, indented four spaces; stream tags come later.
    for key, value in re.findall(r"^ {4}(\w+) *: (.*)$", text[:length.start()], re.M):
        tags.setdefault(key.lower(), value.strip())
    return duration, tags


def probe(path):
    result = subprocess.run([ffmpeg(), "-hide_banner", "-nostdin", "-i", str(path)],
                            capture_output=True, text=True, errors="replace", timeout=30)
    return describe(result.stderr)


def duration_within_limit(duration, limit=900):
    return math.isfinite(duration) and 0 < duration <= limit
