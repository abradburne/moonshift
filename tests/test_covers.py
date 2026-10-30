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


def test_a_note_shorter_than_the_rhythm_grid_does_not_lose_the_score():
    # SheetSage2's own grid code refuses the whole score; the helper drops the blip.
    code = '''
import sys, numpy as np, pretty_midi
sys.path.insert(0, ".models")
from SheetSage2 import notation_sheetsage2 as notation
from studio.covers import forgive_short_notes
grid = np.arange(0, 4.01, .25)
notes = [pretty_midi.Note(90, 60, 0, 1), pretty_midi.Note(90, 72, 1.95, 1.99), pretty_midi.Note(90, 64, 2, 3),
         pretty_midi.Note(90, 65, 2.5, 3.5)]
try:
    notation._notes_to_arr(notes, grid, "Vocal")
    raise SystemExit("SheetSage2 now accepts short notes; the workaround may be unneeded")
except notation.MelodyVoiceError:
    pass
forgive_short_notes(notation)
voice = notation._notes_to_arr(notes, grid, "Vocal")
onsets = [int(v // 2 - 1) for v in voice if v % 2]
assert onsets == [60, 64, 65], onsets
assert list(voice[8:10]) == [64 * 2 + 3, 64 * 2 + 2] and voice[10] == 65 * 2 + 3
keys = notation._fill_intervals([(0, 2, "C"), (2, 2.05, "G"), (2.05, 4, "F")], grid, default="C", dtype="<U16")
assert keys[0] == "C" and keys[9] == "F"
'''
    python = ROOT / ".covers-venv/bin/python"
    if not python.exists() or not (ROOT / ".models/SheetSage2").exists():
        pytest.skip("Optional cover environment is not installed")
    subprocess.run([str(python), "-c", code], check=True, cwd=ROOT)
