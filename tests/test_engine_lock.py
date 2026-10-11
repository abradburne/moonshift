"""A shared worker lease protects unified memory across the two local apps."""
import fcntl
import json
import subprocess
import sys
import threading
import uuid

from studio import server


def job_fixture(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "ROOT", tmp_path)
    monkeypatch.setattr(server, "DATA", tmp_path / "data")
    identifier = str(uuid.uuid4())
    directory = tmp_path / "data/jobs" / identifier
    directory.mkdir(parents=True)
    server.write_json(directory / "job.json", {"id": identifier, "status": "queued", "stage": "Queued"})
    return identifier


def test_model_lease_excludes_another_process_until_release(tmp_path, monkeypatch):
    identifier = job_fixture(tmp_path, monkeypatch)
    lease = server.acquire_engine_lock(identifier)
    script = """
import fcntl, sys
with open(sys.argv[1], 'a+') as lock:
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit(2)
"""
    path = tmp_path / ".runtime/model-job.lock"
    assert subprocess.run([sys.executable, "-c", script, str(path)]).returncode == 2
    lease.close()
    assert subprocess.run([sys.executable, "-c", script, str(path)]).returncode == 0


def test_cancel_while_waiting_never_acquires_model_lease(tmp_path, monkeypatch):
    identifier = job_fixture(tmp_path, monkeypatch)
    (tmp_path / ".runtime").mkdir()
    with (tmp_path / ".runtime/model-job.lock").open("a+") as blocker:
        fcntl.flock(blocker, fcntl.LOCK_EX)
        waiting = threading.Event()
        update = server.update_job
        def observed(job_id, **changes):
            update(job_id, **changes)
            if changes.get("stage") == "Waiting for another local music job": waiting.set()
        monkeypatch.setattr(server, "update_job", observed)
        result = []
        worker = threading.Thread(target=lambda: result.append(server.acquire_engine_lock(identifier)), daemon=True)
        worker.start()
        assert waiting.wait(3)
        server.update_job(identifier, status="cancelled")
        worker.join(timeout=3)
        assert not worker.is_alive() and result == [None]
