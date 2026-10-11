import json
import os
import signal
import subprocess
import sys
import threading
import time
import uuid

import psutil
import pytest
from fastapi.testclient import TestClient
from studio import resources, server

MEMORY = {"total_gib": 36, "available_gib": 28, "free_gib": 2, "limit_gib": 21.6, "reserve_gib": 6}


def test_estimates_token_duration_guidance_and_sequential_takes(monkeypatch):
    monkeypatch.setattr(resources, "installed", lambda engine: True)
    p = {"engine": "metal-q8", "max_tokens": 9000, "cfg_scale": 1, "cot": "full"}
    one = resources.estimate(p, memory=MEMORY)
    eight = resources.estimate(dict(p, takes=8), memory=MEMORY)
    guided = resources.estimate(dict(p, cfg_scale=1.2), memory=MEMORY)
    assert one["duration_ceiling_seconds"] == 360
    assert eight["peak_high_gib"] == one["peak_high_gib"]
    assert guided["cache_gib"] > one["cache_gib"] * 1.9
    q4 = resources.estimate(dict(p, engine="metal-q4"), memory=MEMORY)
    assert q4["peak_high_gib"] < one["peak_high_gib"]
    constrained = resources.estimate(p, memory=dict(MEMORY, limit_gib=8))
    assert not constrained["allowed"]
    assert "memory limit" in constrained["reason"]
    assert one["allowed"]
    automatic = resources.estimate(dict(p, engine="auto"), memory=dict(MEMORY, available_gib=16))
    assert automatic["allowed"] and automatic["engine"] == "metal-q4"
    assert "Automatic chose 4-bit" in automatic["selection_note"]


def test_low_available_memory_and_missing_engine_are_rejected(monkeypatch):
    monkeypatch.setattr(resources, "installed", lambda engine: True)
    result = resources.estimate({"engine": "metal-q4", "max_tokens": 1500}, memory=dict(MEMORY, available_gib=7))
    assert not result["allowed"] and "available memory" in result["reason"]
    monkeypatch.setattr(resources, "installed", lambda engine: False)
    missing = resources.estimate({"engine": "metal-q8"}, memory=MEMORY)
    assert not missing["allowed"] and "not installed" in missing["reason"]
    assert resources.engine_for({"engine": "metal-q4"}) == "metal-q4"
    # Automatic prefers 8-bit, and falls back to whichever model is installed.
    assert resources.engine_for({}) == "metal-q8"
    monkeypatch.setattr(resources, "installed", lambda engine: engine == "metal-q4")
    assert resources.engine_for({"engine": "auto"}) == "metal-q4"


def test_api_preflight_stores_nothing_when_memory_is_unsafe(tmp_path, monkeypatch):
    (tmp_path / "jobs").mkdir()
    monkeypatch.setattr(server, "DATA", tmp_path)
    monkeypatch.setattr(resources, "memory_snapshot", lambda: dict(MEMORY, available_gib=2))
    monkeypatch.setattr(resources, "installed", lambda engine: True)
    client = TestClient(server.app)
    p = {"style": "Soul", "lyrics": "Coming home", "engine": "metal-q4"}
    estimate = client.post("/api/estimate", json=p)
    assert estimate.status_code == 200 and not estimate.json()["allowed"]
    assert client.post("/api/jobs", json={"kind": "generate", "project": p}).status_code == 409
    assert not list((tmp_path / "jobs").iterdir())


def test_queue_forecast_counts_owned_model_ejection_but_shows_current_memory(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "DATA", tmp_path)
    monkeypatch.setattr(resources, "installed", lambda engine: True)
    monkeypatch.setattr(resources, "memory_snapshot", lambda: dict(MEMORY, available_gib=8))
    job_id = str(uuid.uuid4())
    path = tmp_path / "jobs" / job_id
    path.mkdir(parents=True)
    server.write_json(path / "job.json", {"memory_gib": 10})
    monkeypatch.setattr(server, "PROCESSES", {job_id: object()})
    result = server.queued_estimate({"engine": "metal-q8", "max_tokens": 1500})
    assert result["allowed"] and result["memory"]["available_gib"] == 8
    assert result["queued_reclaim_gib"] == 10


def test_live_guard_cannot_be_overwritten_by_worker_completion(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "DATA", tmp_path)
    job_id = str(uuid.uuid4())
    path = tmp_path / "jobs" / job_id
    path.mkdir(parents=True)
    server.write_json(path / "job.json", {"id": job_id, "status": "running", "result": {"tracks": [{"audio": "previous.wav"}]}})
    monkeypatch.setattr(server, "process_tree_footprint", lambda pid: 23)
    monkeypatch.setattr(server, "memory_snapshot", lambda: MEMORY)
    stopped = []
    monkeypatch.setattr(server, "stop_process_group", lambda p: stopped.append(p.pid))
    class Process:
        pid = 123456
        def poll(self): return None
    server.monitor_worker(job_id, Process(), 21.6, threading.Event())
    server.update_job(job_id, status="complete", result={"tracks": []})
    job = server.read_job(job_id)
    assert job["status"] == "failed" and job["stage"] == "Memory guard"
    assert job["peak_memory_gib"] == 23 and "23.0 GB" in job["error"]
    assert job["result"]["tracks"][0]["audio"] == "previous.wav"
    assert stopped == [123456]


def test_memory_accounting_reads_own_process():
    assert resources.physical_footprint(os.getpid()) > 0
    assert resources.process_tree_footprint(os.getpid()) > 0


def test_stalled_music_is_stopped_without_waiting_for_memory_overflow(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "DATA", tmp_path)
    job_id = str(uuid.uuid4())
    path = tmp_path / "jobs" / job_id
    path.mkdir(parents=True)
    server.write_json(path / "job.json", {"status": "running", "result": {}})
    monkeypatch.setattr(server, "process_tree_footprint", lambda pid: 3)
    monkeypatch.setattr(server, "memory_snapshot", lambda: MEMORY)
    stopped = []
    monkeypatch.setattr(server, "stop_process_group", lambda p: stopped.append(p.pid))
    class Process:
        pid = 123
        def poll(self): return None
    server.monitor_worker(job_id, Process(), 21.6, threading.Event(), [time.monotonic() - 200])
    job = server.read_job(job_id)
    assert job["status"] == "failed" and job["stage"] == "Progress guard"
    assert "no progress" in job["error"] and stopped == [123]


def test_saved_song_resume_rejects_changed_lyrics_and_accepts_render_settings(tmp_path, monkeypatch):
    from studio.models import Project
    monkeypatch.setattr(server, "DATA", tmp_path)
    monkeypatch.setattr(resources, "installed", lambda engine: True)
    monkeypatch.setattr(resources, "memory_snapshot", lambda: MEMORY)
    prior = str(uuid.uuid4())
    path = tmp_path / "jobs" / prior
    (path / "take-1").mkdir(parents=True)
    p = Project(style="Soul", lyrics="Original song", engine="metal-q4").model_dump()
    server.write_json(path / "job.json", {"request": {"project": p}})
    (path / "take-1/semantic-prefix.json").write_text("[1,2,3]")
    client = TestClient(server.app)
    changed = dict(p, lyrics="Different song")
    assert client.post("/api/jobs", json={"kind": "generate", "project": changed, "resume_from": prior}).status_code == 409
    rendering = dict(p, nar_chunk_frames=512, ode_steps=8, engine="metal-q8")
    assert client.post("/api/jobs", json={"kind": "generate", "project": rendering, "resume_from": prior}).status_code == 200


def test_ejection_kills_hung_worker_and_child_before_return(tmp_path):
    child_pid = tmp_path / "child.pid"
    script = """import os, signal, subprocess, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([sys.executable, '-c', 'import signal,time;signal.signal(signal.SIGTERM, signal.SIG_IGN);time.sleep(60)'])
open(sys.argv[1], 'w').write(str(child.pid))
time.sleep(60)
"""
    proc = subprocess.Popen([sys.executable, "-c", script, str(child_pid)], start_new_session=True)
    try:
        for _ in range(100):
            if child_pid.exists(): break
            time.sleep(.02)
        assert child_pid.exists()
        pid = int(child_pid.read_text())
        time.sleep(.1)
        resources.stop_process_group(proc)
        assert proc.poll() is not None
        assert not psutil.pid_exists(pid) or psutil.Process(pid).status() == psutil.STATUS_ZOMBIE
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


def test_semantic_artifact_handles_both_cli_layouts(tmp_path):
    from studio.worker import semantic_artifact
    path = tmp_path / "semantic.json"
    path.write_text(json.dumps([1, 2, 3]))
    assert semantic_artifact(path)[0] == [1, 2, 3]
    path.write_text(json.dumps({"payload_hex": b"[1,2,3]".hex(), "meta": {"truncated": "true"}}))
    assert semantic_artifact(path) == ([1, 2, 3], {"truncated": "true"})
