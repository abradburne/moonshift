"""Model selection, conservative preflight estimates and macOS physical footprint.

No tensor libraries are imported by the service. GPU models belong to workers.
Estimates are planning aids; the independent live guard enforces the limit.
"""
import ctypes
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

import psutil

GIB = 1024 ** 3
ROOT = Path(__file__).resolve().parent.parent
METAL_CLI = ROOT / ".runtime/audio.cpp/build/macos-metal-release/bin/audiocpp_cli"
GGUF = ROOT / ".models/YuE2-GGUF"


def covers_installed():
    return all(path.is_file() for path in (
        ROOT / ".covers-venv/bin/python", ROOT / ".models/SheetSage2/model.safetensors",
        ROOT / ".models/SheetSage2/modeling_sheetsage2.py",
        ROOT / ".models/MERT-v2-FullSong/model.safetensors"))


def installed(engine):
    weight = "yue2-3b-q4_0.gguf" if engine == "metal-q4" else "yue2-3b-q8_0.gguf"
    sidecars = ("yue2-model-config.json", "yue2-generation-config.json", "yue2-qwen.tiktoken", "yue2-vae-config.json")
    return METAL_CLI.is_file() and os.access(METAL_CLI, os.X_OK) and all(
        p.is_file() for p in [GGUF / weight, GGUF / "yue2-vae-f16.gguf", *(GGUF / "sidecars" / s for s in sidecars)])


def engine_for(project):
    choice = project.get("engine") or "auto"
    if choice in {"metal-q4", "metal-q8"}:
        return choice
    return "metal-q8" if installed("metal-q8") or not installed("metal-q4") else "metal-q4"


def memory_snapshot():
    vm = psutil.virtual_memory()
    total = vm.total / GIB
    return {"total_gib": round(total, 2), "available_gib": round(vm.available / GIB, 2),
            "free_gib": round(vm.free / GIB, 2), "limit_gib": round(min(24, total * .60), 2),
            "reserve_gib": min(6.0, total * .17)}


def estimate(project, kind="generate", memory=None):
    mem = memory if memory is not None else memory_snapshot()
    engine = engine_for(project)
    budget = project.get("max_tokens", 9000)
    # Text/ABC prefix approximation includes an allowance for automatic planning.
    text = " ".join(project.get(k, "") for k in ("lyrics", "style", "vocal_prompt", "abc"))
    prefix = int(len(text.encode("utf-8")) / 3) + (4096 if project.get("cot", "full") != "off" and not project.get("abc", "").strip() else 256)
    branches = 1 if project.get("cfg_scale", 1) == 1 else 2
    # 28 layers * 8 KV heads * 128 dimensions * K+V * fp16 bytes.
    kv = (prefix + budget) * 114688 * branches / GIB
    if kind == "transcribe":
        # CPU FP32 transcription measured 2.38 GB; retain room for longer songs.
        low, high = 3.0, 6.0
        engine_label = "Reference transcription · CPU"
    else:
        base = 5.8 if engine == "metal-q4" else 7.4
        low, high = base + kv, base + kv + 2.5
        engine_label = "Metal · 4-bit" if engine == "metal-q4" else "Metal · 8-bit"
    reasons = []
    if kind == "transcribe" and not covers_installed():
        reasons.append("The transcription models are not installed yet. Install them in Settings.")
    if kind == "generate" and not installed(engine):
        reasons.append("This music model is not installed yet. Install it in Settings.")
    if high > mem["limit_gib"]:
        reasons.append(f"Estimated peak {high:.1f} GB exceeds the {mem['limit_gib']:.1f} GB memory limit. Choose 4-bit or a shorter length.")
    if high + mem["reserve_gib"] > mem["available_gib"]:
        reasons.append(f"About {high + mem['reserve_gib']:.1f} GB of available memory is needed, including space for macOS. Close other heavy apps or choose a shorter length.")
    words = len(re.findall(r"\S+", re.sub(r"\[[^\]]+\]", "", project.get("lyrics", ""))))
    suggested = min(16000, max(1500, int((words / 100 * 60 + 30) * 25 / 500 + .999) * 500))
    result = {"engine": engine, "engine_label": engine_label, "memory": mem,
            "peak_low_gib": round(low, 1), "peak_high_gib": round(high, 1),
            "cache_gib": round(kv, 2), "prompt_tokens_estimate": prefix,
            "audio_tokens": budget, "duration_ceiling_seconds": budget / 25,
            "suggested_tokens": suggested, "allowed": not reasons, "reason": " ".join(reasons)}
    if kind == "generate" and (project.get("engine") or "auto") == "auto" and engine == "metal-q8" and reasons and installed("metal-q4"):
        smaller = estimate(dict(project, engine="metal-q4"), kind, memory=mem)
        if smaller["allowed"]:
            smaller["selection_note"] = "Automatic chose 4-bit to fit available memory. You can choose 8-bit explicitly for more weight precision."
            return smaller
    return result


class _Rusage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "idle_wakeups", "interrupt_wakeups", "pageins", "wired",
        "resident", "footprint", "start", "exit")]


def physical_footprint(pid):
    """Darwin ledger footprint counts compressed pages, unlike RSS."""
    if sys.platform == "darwin":
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        call = lib.proc_pid_rusage
        call.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        call.restype = ctypes.c_int
        usage = _Rusage()
        if call(pid, 0, ctypes.byref(usage)) == 0:
            return usage.footprint
        raise RuntimeError("Cannot read the worker's physical memory footprint; rendering was stopped.")
    return psutil.Process(pid).memory_info().rss


def process_tree_footprint(pid):
    process = psutil.Process(pid)
    total = 0
    for item in [process, *process.children(recursive=True)]:
        try:
            total += physical_footprint(item.pid)
        except (psutil.NoSuchProcess, ProcessLookupError):
            pass
        except RuntimeError:
            if item.is_running():
                raise
    return total / GIB


def stop_process_group(proc):
    """Only an owned worker group. Escalate if Metal ignores termination."""
    members = []
    try:
        candidates = psutil.pids()
    except (PermissionError, psutil.AccessDenied):
        # Still terminate the owned group if process enumeration is restricted.
        candidates = [proc.pid]
    for pid in candidates:
        try:
            if os.getpgid(pid) == proc.pid:
                members.append(psutil.Process(pid))
        except (ProcessLookupError, PermissionError, psutil.NoSuchProcess):
            pass
    if not members and proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # The group may still have a child even when the Python parent has exited.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=5)
    _, alive = psutil.wait_procs(members, timeout=5)
    alive = [p for p in alive if p.is_running() and p.status() != psutil.STATUS_ZOMBIE]
    if alive:
        raise RuntimeError("A previous engine could not be ejected. Quit Moonshift before starting another model.")
