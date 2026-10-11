"""An agent can read, edit and render covers through the MCP endpoint."""
import json

import pytest
from fastapi.testclient import TestClient

from studio import resources, server, song_lookup

SCORE = "X:1\nM:4/4\nL:1/16\nQ:1/4=120\nK:C\nV: Vocal\nc4d4e4f4|\n"


@pytest.fixture
def agent(tmp_path, monkeypatch):
    for name in ("projects", "jobs", "imports", "exports"):
        (tmp_path / name).mkdir()
    monkeypatch.setattr(server, "DATA", tmp_path)
    monkeypatch.setattr(resources, "memory_snapshot", lambda: {"total_gib": 36, "available_gib": 32, "free_gib": 2, "limit_gib": 21.6, "reserve_gib": 6})
    monkeypatch.setattr(resources, "installed", lambda engine: True)
    monkeypatch.setattr(resources, "covers_installed", lambda: True)
    monkeypatch.setattr(song_lookup, "probe", lambda path: (200.0, {"title": "Home", "artist": "Singer"}))
    client = TestClient(server.app)
    counter = iter(range(1, 1000))

    def rpc(method, **params):
        return client.post("/mcp", json={"jsonrpc": "2.0", "id": next(counter), "method": method, "params": params}).json()

    def tool(name, **arguments):
        result = rpc("tools/call", name=name, arguments=arguments)["result"]
        body = result["content"][0]["text"]
        return (body if result.get("isError") else json.loads(body)), bool(result.get("isError"))

    return client, rpc, tool


def test_handshake_lists_tools_and_ignores_notifications(agent):
    client, rpc, _ = agent
    hello = rpc("initialize", protocolVersion="2025-06-18", capabilities={}, clientInfo={"name": "test", "version": "1"})["result"]
    assert hello["protocolVersion"] == "2025-06-18" and hello["serverInfo"]["name"] == "moonshift" and "tools" in hello["capabilities"]
    assert client.post("/mcp", json={"jsonrpc": "2.0", "method": "notifications/initialized"}).status_code == 202
    names = [tool["name"] for tool in rpc("tools/list")["result"]["tools"]]
    assert {"list_covers", "get_cover", "update_cover", "create_take", "transcribe", "get_job"} <= set(names)
    assert rpc("nonsense")["error"]["code"] == -32601
    assert client.get("/mcp").status_code == 405
    # The endpoint is as closed to web pages as the rest of the service.
    assert client.post("/mcp", json={}, headers={"origin": "https://example.com"}).status_code == 403


def test_agent_edits_the_score_and_renders_the_revision(agent, tmp_path):
    client, rpc, tool = agent
    recording = tmp_path / "Singer - Home.mp3"
    recording.write_bytes(b"audio")
    cover, failed = tool("create_cover", audio_path=str(recording), lyrics="[Verse]\nComing home", style="Soul")
    assert not failed and cover["title"] == "Home" and cover["score_source"] == "none" and "transcribe" in cover["note"]
    assert [c["cover_id"] for c in tool("list_covers")[0]] == [cover["cover_id"]]

    # No score yet: rendering is refused with an instruction, not a crash.
    message, failed = tool("create_take", cover_id=cover["cover_id"])
    assert failed and "transcribe" in message
    listening, _ = tool("transcribe", cover_id=cover["cover_id"])
    assert listening["kind"] == "transcription" and listening["status"] == "queued"
    server.update_job(listening["job_id"], status="complete", result={"abc": SCORE, "full_abc": SCORE.replace("c4", '"C"c4')})
    assert tool("transcribe", cover_id=cover["cover_id"])[0]["note"] == "This recording is already transcribed."

    heard, _ = tool("get_cover", cover_id=cover["cover_id"])
    assert heard["score"] == SCORE and heard["score_source"] == "transcription"
    assert tool("update_cover", cover_id=cover["cover_id"], keep="melody_and_harmony")[0]["score"].count('"C"') == 1

    revised = SCORE.replace("c4d4e4f4", "c4e4g4c'4").replace("Q:1/4=120", "Q:1/4=96")
    edited, failed = tool("update_cover", cover_id=cover["cover_id"], score=revised, lyrics="[Verse]\nGoing home", tempo=0.9, length_seconds=60, quality="high")
    assert not failed and edited["score"] == revised and edited["score_source"] == "edited"
    assert edited["lyrics"] == "[Verse]\nGoing home" and edited["tempo"] == 0.9 and edited["length_seconds"] == 60 and edited["quality"] == "high"

    take, failed = tool("create_take", cover_id=cover["cover_id"])
    assert not failed and take["kind"] == "take" and take["status"] == "queued"
    queued = server.read_job(take["job_id"])["request"]["project"]
    assert queued["abc"] == revised and queued["score_edited"] and queued["lyrics"] == "[Verse]\nGoing home" and queued["max_tokens"] == 1500
    # While it renders, the cover cannot be changed underneath it.
    assert tool("update_cover", cover_id=cover["cover_id"], style="Jazz")[1]
    assert tool("cancel_job", job_id=take["job_id"])[0]["status"] == "cancelled"

    # Clearing the score returns to what was heard in the recording.
    assert tool("update_cover", cover_id=cover["cover_id"], score="")[0]["score_source"] == "transcription"


def test_bad_requests_come_back_as_readable_tool_errors(agent, tmp_path):
    _, _, tool = agent
    assert tool("get_cover", cover_id="../../etc")[1]
    assert tool("get_cover")[0] == "Missing argument: cover_id"
    assert tool("create_cover", audio_path=str(tmp_path / "notes.txt"))[1]
    recording = tmp_path / "song.wav"
    recording.write_bytes(b"audio")
    cover, _ = tool("create_cover", audio_path=str(recording))
    message, failed = tool("update_cover", cover_id=cover["cover_id"], tempo=9)
    assert failed and "tempo" in message
    assert tool("no_such_tool")[1]
