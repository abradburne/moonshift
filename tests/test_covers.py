import io
import numpy as np
import pytest
from studio.models import JobRequest, Project
from studio import resources


def test_reference_and_score_survive_session_snapshot():
    project = Project(cover_source="imports/song.wav", cover_name="Original", cover_job="transcription",
                      lyrics="[Chorus]\nNew words", style="Jazz", cot="melody", abc="X:1\nK:C\nCDEF|")
    request = JobRequest(kind="generate", project=project)
    saved = JobRequest.model_validate_json(request.model_dump_json())
    assert saved.project.cover_source == project.cover_source
    assert saved.project.abc == project.abc
    assert Project.model_validate({"title": "Old session"}).cover_source == ""
    with pytest.raises(ValueError):
        JobRequest(kind="transcribe", project=Project())
    with pytest.raises(ValueError):
        JobRequest(kind="generate", project=project.model_copy(update={"cover_job": ""}))


def test_transcription_uses_its_own_forecast(monkeypatch):
    monkeypatch.setattr(resources, "covers_installed", lambda: True)
    memory = dict(total_gib=36, available_gib=16, free_gib=2, limit_gib=21.6, reserve_gib=6)
    forecast = resources.estimate({"max_tokens": 16000}, "transcribe", memory)
    assert forecast["allowed"] and forecast["peak_high_gib"] == 6
    assert not resources.estimate({}, "transcribe", dict(memory, available_gib=11))["allowed"]
    monkeypatch.setattr(resources, "covers_installed", lambda: False)
    assert "not installed" in resources.estimate({}, "transcribe", memory)["reason"]


def test_note_preview_preserves_silence_timing_and_is_finite(tmp_path):
    # Run in the cover environment; no model is loaded.
    import subprocess
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
    python = resources.ROOT / ".covers-venv/bin/python"
    if not python.exists():
        pytest.skip("Optional cover environment is not installed")
    subprocess.run([str(python), "-c", code, str(tmp_path / "preview.wav")], check=True, cwd=resources.ROOT)
