"""The transcription helper is the one part of Moonshift still in Python.

Run with the transcription environment installed:
    uv run --no-project --with pytest python -m pytest tests
"""
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent


def test_note_preview_preserves_silence_timing_and_is_finite(tmp_path):
    # Run in the cover environment; no model is loaded.
    code = '''
import io, numpy as np, pretty_midi, soundfile as sf
from studio.covers import melody_preview
from pathlib import Path
import sys
midi = pretty_midi.PrettyMIDI()
part = pretty_midi.Instrument(0)
part.notes = [pretty_midi.Note(100, 69, 1, 1.5)]
midi.instruments.append(part)
data = io.BytesIO(); midi.write(data)
audio, sr = melody_preview(data.getvalue(), Path(sys.argv[1]))
assert sr == 24000 and np.isfinite(audio).all()
assert not np.any(audio[:24000])
assert np.max(np.abs(audio[24000:36000])) > .1
assert np.max(np.abs(audio)) <= .70001
'''
    python = ROOT / ".covers-venv/bin/python"
    if not python.exists():
        pytest.skip("Optional cover environment is not installed")
    subprocess.run([str(python), "-c", code, str(tmp_path / "preview.wav")], check=True, cwd=ROOT)
