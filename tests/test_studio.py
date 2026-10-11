import json
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from studio import server
from studio.models import JobRequest, Project


@pytest.fixture
def client(tmp_path, monkeypatch):
    for name in ("projects", "jobs", "imports", "exports"):
        (tmp_path / name).mkdir()
    monkeypatch.setattr(server, "DATA", tmp_path)
    # Tests must not depend on other applications' memory use or downloaded engines.
    from studio import resources
    monkeypatch.setattr(resources, "memory_snapshot", lambda: {"total_gib": 36, "available_gib": 32, "free_gib": 2, "limit_gib": 21.6, "reserve_gib": 6})
    monkeypatch.setattr(resources, "installed", lambda engine: True)
    return TestClient(server.app)


def test_project_roundtrip_and_job_snapshot(client):
    original = client.post("/api/projects", json={"title": "First take", "style": "Soul", "cover_preset": "Vintage soul", "lyrics": "[Chorus]\nComing home"}).json()
    response = client.post("/api/jobs", json={"kind": "generate", "project": original})
    assert response.status_code == 200
    job = response.json()
    revised = dict(original, lyrics="[Chorus]\nChanged words", style="Jazz", cover_preset="Late-night jazz")
    assert client.post("/api/projects", json=revised).status_code == 200
    assert client.get(f"/api/jobs/{job['id']}").json()["request"]["project"]["lyrics"] == original["lyrics"]
    saved_take = client.get(f"/api/jobs/{job['id']}").json()["request"]["project"]
    assert saved_take["style"] == "Soul" and saved_take["cover_preset"] == "Vintage soul"
    assert client.get("/api/projects").json()[0]["lyrics"] == revised["lyrics"]


SONG = {"style": "Soul", "lyrics": "[Chorus]\nComing home", "engine": "metal-q4"}


def test_cancel_is_terminal_and_retains_completed_takes(client):
    job = client.post("/api/jobs", json={"kind": "generate", "project": SONG}).json()
    server.update_job(job["id"], result={"tracks": [{"audio": "finished.wav"}]})
    assert client.post(f"/api/jobs/{job['id']}/cancel").json()["status"] == "cancelled"
    server.update_job(job["id"], status="complete", stage="Complete")
    saved = client.get(f"/api/jobs/{job['id']}").json()
    assert saved["status"] == "cancelled"
    assert saved["result"]["tracks"][0]["audio"] == "finished.wav"


def test_external_origin_host_and_path_traversal_rejected(client, tmp_path):
    assert client.post("/api/projects", json={}, headers={"origin": "https://example.com"}).status_code == 403
    # A page that points its own hostname at the loopback address is refused too.
    assert client.get("/api/projects", headers={"host": "attacker.example:8766"}).status_code == 403
    assert client.get("/api/projects", headers={"host": "127.0.0.1:8766", "origin": "http://127.0.0.1:8766"}).status_code == 200
    with pytest.raises(Exception):
        server.resolve_data_file("../../outside.wav")
    assert client.post("/api/projects", json={"id": "../../bad"}).status_code == 400


def test_import_accepts_audio_only(client):
    imported = client.post("/api/import", content=b"audio", headers={"x-filename": "recording.wav"})
    assert imported.status_code == 200 and imported.json()["source"].startswith("imports/")
    assert client.post("/api/import", content=b"script", headers={"x-filename": "bad.py"}).status_code == 400


def test_cover_reference_paths_are_checked_before_queueing(client, monkeypatch):
    from studio import resources
    monkeypatch.setattr(resources, "covers_installed", lambda: True)
    imported = client.post("/api/import", content=b"audio", headers={"x-filename": "reference.wav"}).json()
    assert client.post("/api/jobs", json={"kind": "transcribe", "project": {}, "source": imported["source"]}).status_code == 200
    assert client.post("/api/jobs", json={"kind": "transcribe", "project": {}, "source": "../../outside.wav"}).status_code == 404
    project = {"style": "Jazz", "lyrics": "New words", "cot": "melody", "abc": "K:C\nCDEF|", "cover_source": "missing.wav", "cover_job": "imported"}
    assert client.post("/api/jobs", json={"kind": "generate", "project": project}).status_code == 404


def test_incompatible_score_empty_prompts_and_retired_jobs_rejected(client):
    assert client.post("/api/jobs", json={"kind": "generate", "project": {}}).status_code == 422
    assert client.post("/api/jobs", json={"kind": "generate", "project": {"style": "Jazz", "lyrics": "Hello", "abc": "X:1\nK:C\nCDEF", "cot": "off"}}).status_code == 422
    assert client.post("/api/jobs", json={"kind": "separate", "project": SONG}).status_code == 422


def test_state_is_unchanged_until_something_is_written(client):
    first = client.get("/api/state", params={"client": "app"})
    assert first.status_code == 200 and first.json() == {"revision": first.headers["etag"], "jobs": [], "projects": []}
    assert "app" in server.CLIENTS
    assert client.get("/api/state", headers={"if-none-match": first.headers["etag"]}).status_code == 304
    saved = client.post("/api/projects", json=dict(SONG, title="First")).json()
    job = client.post("/api/jobs", json={"kind": "generate", "project": saved}).json()
    second = client.get("/api/state", headers={"if-none-match": first.headers["etag"]})
    assert second.status_code == 200 and second.headers["etag"] != first.headers["etag"]
    assert [p["title"] for p in second.json()["projects"]] == ["First"]
    assert [j["id"] for j in second.json()["jobs"]] == [job["id"]]
    assert client.get("/api/state", headers={"if-none-match": second.headers["etag"]}).status_code == 304
    # An update to a job is visible on the next poll, not served from the cache.
    server.update_job(job["id"], stage="Writing the new arrangement", phase="compose", progress=.5)
    third = client.get("/api/state", headers={"if-none-match": second.headers["etag"]})
    assert third.status_code == 200 and third.json()["jobs"][0]["progress"] == .5


def test_stopped_render_with_saved_song_is_resumable(client, tmp_path):
    job = client.post("/api/jobs", json={"kind": "generate", "project": SONG}).json()
    (tmp_path / "jobs" / job["id"] / "take-1").mkdir()
    (tmp_path / "jobs" / job["id"] / "take-1/semantic-prefix.json").write_text("[1, 2, 3]")
    assert client.get("/api/jobs").json()[0]["resumable"] is False
    server.update_job(job["id"], status="failed", stage="Progress guard", error="stalled")
    assert client.get("/api/jobs").json()[0]["resumable"] is True
    assert "resumable" not in server.read_job(job["id"])


def test_deleting_a_cover_removes_its_takes_and_unshared_recording(client, tmp_path):
    source = client.post("/api/import", content=b"audio", headers={"x-filename": "song.wav"}).json()["source"]
    cover = client.post("/api/projects", json=dict(SONG, cover_source=source, cover_job="t", abc="K:C\nCDEF|", cot="melody")).json()
    twin = client.post("/api/projects", json=dict(SONG, cover_source=source)).json()
    job = client.post("/api/jobs", json={"kind": "generate", "project": cover}).json()
    other = client.post("/api/jobs", json={"kind": "generate", "project": SONG}).json()
    assert client.delete(f"/api/projects/{cover['id']}").status_code == 409
    assert client.delete(f"/api/jobs/{job['id']}").status_code == 409
    client.post(f"/api/jobs/{job['id']}/cancel")
    assert client.delete(f"/api/projects/{cover['id']}").json() == {"deleted": cover["id"], "jobs": 1}
    assert not (tmp_path / "jobs" / job["id"]).exists() and (tmp_path / "jobs" / other["id"]).exists()
    # The recording stays while another cover still uses it.
    assert (tmp_path / source).exists()
    assert client.delete(f"/api/projects/{twin['id']}").status_code == 200
    assert not (tmp_path / source).exists()
    assert client.delete(f"/api/projects/{twin['id']}").status_code == 404
    assert client.delete("/api/projects/..%2F..%2Fbad").status_code == 404
    client.post(f"/api/jobs/{other['id']}/cancel")
    assert client.delete(f"/api/jobs/{other['id']}").status_code == 200
    assert client.get("/api/state").json()["jobs"] == []
