"""Official SheetSage2 transcription, isolated from every other model worker."""
import io
import json
from pathlib import Path
import sys


def melody_preview(midi_bytes, path):
    """Small additive note preview; no soundfont downloads or GPU required."""
    import numpy as np
    import pretty_midi
    import soundfile as sf
    midi = pretty_midi.PrettyMIDI(io.BytesIO(midi_bytes))
    rate = 24000
    duration = midi.get_end_time() + .4
    audio = np.zeros(int(duration * rate) + 1, dtype=np.float32)
    for instrument in midi.instruments:
        if instrument.is_drum:
            continue
        for note in instrument.notes:
            start = int(note.start * rate)
            length = min(len(audio) - start, int((note.end - note.start + .25) * rate))
            if length <= 0:
                continue
            t = np.arange(length, dtype=np.float32) / rate
            frequency = pretty_midi.note_number_to_hz(note.pitch)
            tone = sum(np.sin(2 * np.pi * frequency * harmonic * t) / harmonic ** 2
                       for harmonic in range(1, 5))
            envelope = np.minimum(t / .008, 1) * np.exp(-t * 2)
            envelope *= np.clip((note.end - note.start + .25 - t) / .25, 0, 1)
            audio[start:start + length] += tone * envelope * (note.velocity / 127)
    peak = float(np.max(np.abs(audio)))
    audio *= .7 / max(peak, 1)
    sf.write(path, audio, rate, subtype="PCM_16")
    return audio, rate


def transcribe(request, directory):
    from .audio import duration_within_limit, probe
    from .worker import ROOT, DATA, event, performance_cores, relative, waveform, write
    source = (DATA / request["source"]).resolve()
    if not source.is_relative_to(DATA.resolve()) or not source.is_file():
        raise ValueError("Reference recording is missing.")
    event(stage="Checking the recording", phase="listen", progress=None)
    duration, _ = probe(source)
    if not duration_within_limit(duration):
        raise ValueError("Import a reference recording up to 15 minutes.")
    import torch
    # Import audited, pinned local source; the MERT parent is also explicitly local.
    sys.path.insert(0, str(ROOT / ".models"))
    from SheetSage2.modeling_sheetsage2 import SheetSage2Model
    from SheetSage2.exports_sheetsage2 import export_result
    torch.set_num_threads(performance_cores())
    event(stage="Loading the transcription model")
    model = SheetSage2Model.from_pretrained(
        str(ROOT / ".models/SheetSage2"),
        base_model_path=str(ROOT / ".models/MERT-v2-FullSong"),
        local_files_only=True, torch_dtype=torch.float32,
    ).eval()

    def progress(value):
        stage = value["stage"]
        if stage in {"encoding", "decoding", "window_complete"}:
            label = "Listening to the song" if stage == "encoding" else "Transcribing melody and harmony"
            done = value["window"] - {"encoding": 1, "decoding": .5}.get(stage, 0)
            event(stage=label, tokens=value.get("tokens", 0), progress=max(0, min(1, done / max(1, value["windows"]))))
        elif stage == "notation":
            event(stage="Writing the score", progress=None)

    # Original five-minute windows, cached overlap and lookahead; no GPU models coexist.
    result = model.transcribe(source, output_dir=directory / "full-score", dtype="fp32", progress=progress)
    decoded = json.loads((directory / "full-score/events.json").read_text())
    melody = export_result(decoded, model.tokenizer, directory / "melody-score",
                           result["duration_seconds"], melody_only=True)
    full_abc = result.get("abc")
    melody_abc = melody["payload"].get("abc")
    if not full_abc or not melody_abc:
        raise ValueError("The reference could not be turned into a cover score: " +
                         str(result.get("abc_error") or melody.get("abc_error") or "no usable melody"))
    if len(full_abc) > 30000 or len(melody_abc) > 30000:
        raise ValueError("This score is too long for one cover. Import a shorter excerpt of the song.")
    midi = melody["payload"]["midi"]
    del model
    event(stage="Making a melody preview", progress=None)
    signal, rate = melody_preview(midi, directory / "melody-preview.wav")
    write(directory / "model-attribution.json", {
        "model_card": "https://huggingface.co/m-a-p/SheetSage2",
        "encoder_card": "https://huggingface.co/m-a-p/MERT-v2-FullSong",
        "license": "CC BY-NC 4.0",
        "license_url": "https://huggingface.co/m-a-p/SheetSage2/blob/main/LICENSE",
    })
    return {"abc": melody_abc, "full_abc": full_abc, "source": request["source"],
            "duration": result["duration_seconds"], "warnings": result.get("warnings", []),
            "tracks": [{"name": "Transcribed melody · note preview", "audio": relative(directory / "melody-preview.wav"),
                        "duration": len(signal) / rate, "waveform": waveform(signal), "seed": 0,
                        "abc": melody_abc, "truncated": False}]}
