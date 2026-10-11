"""A job owns an isolated process so cancelling releases all model memory."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback

from .paths import HOME as ROOT
DATA = ROOT / "data"


def performance_cores():
    """Worker threads belong on performance cores; efficiency cores slow them down.

    Lives here because both model environments can import this module as it is.
    """
    try:
        count = int(subprocess.run(["/usr/sbin/sysctl", "-n", "hw.perflevel0.physicalcpu"],
                                   capture_output=True, text=True, timeout=5).stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        count = (os.cpu_count() or 8) // 2
    return max(4, min(12, count))


def event(**values):
    """Progress for the service: stage text, a phase, and 0–1 progress within it."""
    print("STUDIO_EVENT " + json.dumps(values), flush=True)


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2))


def relative(path):
    return str(path.relative_to(DATA))


def waveform(audio, bins=300):
    import numpy as np
    mono = np.max(np.abs(audio), axis=1) if audio.ndim == 2 else np.abs(audio)
    return [float(np.max(chunk)) if len(chunk) else 0.0 for chunk in np.array_split(mono, bins)]


def retime(abc, scale):
    """The score at another speed: its tempo marks scaled, its notes untouched."""
    if abs(scale - 1) < .005:
        return abc
    return re.sub(r"(?m)^(Q:\s*(?:\d+/\d+\s*=\s*)?)(\d+)", lambda mark: mark[1] + str(max(30, min(300, round(int(mark[2]) * scale)))), abc)


def semantic_artifact(path):
    value = json.loads(path.read_text())
    if isinstance(value, list):
        return value, {}
    return json.loads(bytes.fromhex(value["payload_hex"])), value.get("meta", {})


def music(request, directory):
    """Separate planning and rendering processes; persist tokens before rendering."""
    from .resources import METAL_CLI, GGUF, engine_for
    import soundfile as sf
    import numpy as np
    p = request["project"]
    engine = engine_for(p)
    weight = "yue2-3b-q4_0.gguf" if engine == "metal-q4" else "yue2-3b-q8_0.gguf"
    style = ", ".join(x for x in [p["language"], p["style"], p["vocal_prompt"]] if x)
    tracks = []
    for take in range(1, p["takes"] + 1):
        out = directory / f"take-{take}"
        out.mkdir(exist_ok=True)
        seed = p["seed"] + take - 1
        started = time.perf_counter()
        base = [str(METAL_CLI), "--task", "gen", "--family", "yue2", "--model", str(GGUF),
                "--backend", "metal", "--threads", str(performance_cores()),
                "--session-option", f"yue2.model_gguf={weight}",
                "--session-option", "yue2.vae_gguf=yue2-vae-f16.gguf", "--lyrics", p["lyrics"],
                "--seed", str(seed), "--out-dir", str(out), "--log"]

        def run(options, stage):
            rendering = options.get("stop_after") == "audio"
            event(stage=stage, take=take, phase="render" if rendering else "compose", progress=None,
                  tokens=options["semantic_max_tokens"] if rendering else 0)
            args = base + [arg for key, value in options.items() for arg in ("--request-option", f"{key}={value}")]
            if rendering:
                args += ["--out", str(out / "audio.wav")]
            # Inherit the job's process group, so cancellation/guards cover the engine too.
            proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            tail = []
            for line in proc.stdout:
                print(line, end="", flush=True)
                tail = (tail + [line.strip()])[-12:]
                match = re.search(r"yue2\.ar\.(?:generate|cfg)\.emitted_tokens(?:\s*[=:]\s*|\s+)(\d+)", line)
                if match:
                    event(tokens=int(match[1]))
                progress = re.search(r"moonwire\.progress\.(semantic|abc)\s+(\d+)", line)
                if progress and progress[1] == "semantic":
                    # The budget is a ceiling: the song may end well before it.
                    event(stage="Writing the new arrangement", phase="compose", tokens=int(progress[2]),
                          progress=min(1, int(progress[2]) / p["max_tokens"]))
                elif progress:
                    event(stage="Planning the score", phase="compose", progress=None)
                if "yue2.nar.synthesize.codec_tokens" in line:
                    event(stage="Rendering acoustic detail", phase="render")
                if "yue2.nar_ms" in line:
                    event(stage="Decoding stereo audio", phase="finish", progress=None)
                flow = re.search(r"moonwire\.progress\.flow\s+(\d+)", line)
                if flow:
                    event(stage="Rendering acoustic detail", phase="render",
                          progress=min(1, int(flow[1]) / p["ode_steps"]))
            if proc.wait() != 0:
                raise RuntimeError("The music engine failed: " + " ".join(tail)[-1500:])

        options = {"style": style, "cot": p["cot"], "guidance_scale": p["cfg_scale"],
                   "semantic_temperature": p["temperature"], "semantic_max_tokens": p["max_tokens"],
                   "semantic_min_tokens": min(200, p["max_tokens"]), "num_inference_steps": p["ode_steps"],
                   "export_semantic": "true"}
        if (p.get("nar_chunk_frames") if p.get("nar_chunk_frames") is not None else 1024) > 0:
            options["nar_chunk_frames"] = p.get("nar_chunk_frames") or 1024
        score = out / "score.abc"
        if p["abc"].strip():
            score.write_text(retime(p["abc"], p.get("tempo") or 1))
            options["abc_file"] = str(score)
        if request.get("resume_from"):
            source = DATA / "jobs" / request["resume_from"] / "take-1"
            codes, meta = semantic_artifact(source / "semantic-prefix.json")
            if (source / "score.abc").exists():
                score.write_text((source / "score.abc").read_text())
            write(out / "semantic.json", codes)
        else:
            run(dict(options, stop_after="semantic"), "Loading the music model")
            codes, meta = semantic_artifact(out / "semantic.json")
        if not codes or not all(isinstance(c, int) and 0 <= c < 32768 for c in codes):
            raise RuntimeError("The music engine returned invalid song tokens.")
        if len(codes) > p["max_tokens"]:
            raise RuntimeError("Choose a length large enough for the saved song.")
        checkpoint = out / "semantic-prefix.json"
        write(checkpoint, codes)
        np.save(out / "semantic.npy", np.array(codes, dtype=np.int32))
        # The first process has exited: no planning model or KV cache survives.
        render = dict(options, stop_after="audio", semantic_prefix_file=str(checkpoint),
                      semantic_min_tokens=len(codes), semantic_max_tokens=len(codes))
        if score.exists():
            render["abc_file"] = str(score)
        run(render, "Loading the acoustic renderer")
        event(stage="Saving your cover", phase="finish", progress=None)
        audio, rate = sf.read(out / "audio.wav", dtype="float32", always_2d=True)
        if not np.isfinite(audio).all() or rate != 48000:
            raise RuntimeError("The engine returned invalid audio.")
        sf.write(out / "audio.flac", audio, rate, subtype="PCM_24")
        truncated = len(codes) >= p["max_tokens"] or meta.get("truncated", "false") in {True, "true", "1"}
        track = {"name": f"Take {take}", "audio": relative(out / "audio.wav"), "flac": relative(out / "audio.flac"),
                 "duration": len(audio) / rate, "waveform": waveform(audio), "seed": seed,
                 "abc": score.read_text() if score.exists() else "", "truncated": truncated}
        write(out / "metadata.json", {"engine": engine, "weights": weight, "project": p,
              "semantic_frames": len(codes), "truncated": truncated, "e2e_seconds": time.perf_counter() - started,
              "model_card": "https://huggingface.co/m-a-p/YuE2-3B",
              "license": "CC-BY-NC-4.0", "license_url": "https://huggingface.co/m-a-p/YuE2-3B/blob/main/LICENSE",
              "conversion_card": "https://huggingface.co/audio-cpp/Yue2-3B-GGUF"})
        tracks.append(track)
        # Preserve completed takes if a later take fails or is cancelled.
        write(directory / "partial.json", {"tracks": tracks})
        event(result={"tracks": tracks})
    return {"tracks": tracks}


if __name__ == "__main__":
    directory = Path(sys.argv[1]).resolve()
    request = json.loads((directory / "job.json").read_text())["request"]
    try:
        if request["kind"] == "transcribe":
            from .covers import transcribe as handler
        else:
            handler = music
            write(directory / "model-attribution.json", {
                "model_card": "https://huggingface.co/m-a-p/YuE2-3B",
                "license": "CC BY-NC 4.0; see upstream additional creator permission", "license_url": "https://github.com/multimodal-art-projection/YuE/blob/main/MODEL_LICENSE",
                "decoder_card": "https://huggingface.co/m-a-p/YuE2-Vae",
                "conversion_card": "https://huggingface.co/audio-cpp/Yue2-3B-GGUF",
                "runtime": "https://github.com/0xShug0/audio.cpp",
                "runtime_license": "https://github.com/0xShug0/audio.cpp/blob/main/LICENSE"})
        write(directory / "output.json", handler(request, directory))
    except Exception as exc:
        traceback.print_exc()
        write(directory / "error.json", {"error": str(exc)})
        sys.exit(1)
