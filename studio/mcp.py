"""Model Context Protocol endpoint: lets an agent read, edit and render covers.

Served by the same loopback service as the app, at /mcp, as plain JSON over
HTTP. An agent can read a cover's lyrics, style and ABC score, change any of
them (reharmonize, write a solo, adapt the words), and render each revision.
"""
import json
from pathlib import Path
import random
import shutil
import uuid

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import JSONResponse

from .models import JobRequest, Project

router = APIRouter()
PROTOCOL = "2025-06-18"
AUDIO = {".wav", ".flac", ".mp3", ".aiff", ".aif", ".m4a"}

INSTRUCTIONS = """Moonshift turns a song into a cover in a new style, on this Mac.

A cover has a reference recording, lyrics, a style, a singer, and a score. The
score is ABC notation transcribed from the recording: a melody, and optionally
chords. Rendering a take follows the score, so editing it changes the music.

Typical work: get_cover to read the lyrics, style and score; update_cover with
your changes (a reharmonized or extended score, adapted lyrics, a new style);
create_take to render; get_job until it completes; then tell the user where
the audio is. A cover needs a transcription before its first take: call
transcribe and wait for that job. Rendering takes minutes and uses most of the
machine's memory, so render one take at a time and only when asked.

Keep the score valid ABC: keep the header fields (X, M, L, Q, K) and voice
lines, and change notes, chords in quotes, or the Q tempo. Section labels in
lyrics look like [Verse] and [Chorus]."""


def text(value):
    return {"content": [{"type": "text", "text": value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2)}]}


def schema(properties, required=()):
    return {"type": "object", "properties": properties, "required": list(required), "additionalProperties": False}


COVER_ID = {"type": "string", "description": "The cover's id, from list_covers."}
EDITABLE = {
    "title": {"type": "string", "description": "Name of the cover."},
    "lyrics": {"type": "string", "description": "The words, with section labels such as [Verse] and [Chorus]."},
    "style": {"type": "string", "description": "Genre, instruments, mood and production, as a short description."},
    "vocal_prompt": {"type": "string", "description": "Who sings and how, for example 'Smooth female jazz contralto, gentle vibrato'."},
    "language": {"type": "string", "description": "Language of the lyrics."},
    "keep": {"type": "string", "enum": ["melody", "melody_and_harmony"], "description": "What to follow from the reference: the melody alone, or its chords too."},
    "tempo": {"type": "number", "minimum": 0.5, "maximum": 1.5, "description": "Speed relative to the reference. 1 keeps its tempo; 0.8 is 20% slower."},
    "length_seconds": {"type": "number", "minimum": 20, "maximum": 640, "description": "Upper limit on the rendered length. A shorter song ends sooner."},
    "quality": {"type": "string", "enum": ["standard", "high"], "description": "standard is the 4-bit music model; high is 8-bit and needs more memory."},
    "score": {"type": "string", "description": "The full ABC score to render from, replacing the transcription. Pass an empty string to go back to the transcribed score."},
}

TOOLS = [
    {"name": "status", "description": "Whether the models are installed, how much memory is free, and what is rendering now.",
     "inputSchema": schema({})},
    {"name": "list_covers", "description": "Every cover, most recently edited first, with its song, style and number of takes.",
     "inputSchema": schema({})},
    {"name": "get_cover", "description": "One cover in full: lyrics, style, singer, settings, the ABC score it will render from, and its takes with the paths of their audio files.",
     "inputSchema": schema({"cover_id": COVER_ID}, ["cover_id"])},
    {"name": "create_cover", "description": "Start a new cover from a recording on this Mac. Give lyrics and style now or with update_cover later.",
     "inputSchema": schema({"audio_path": {"type": "string", "description": "Absolute path of a WAV, FLAC, MP3, AIFF or M4A file, up to 15 minutes."},
                            **{key: EDITABLE[key] for key in ("title", "lyrics", "style", "vocal_prompt", "language")}}, ["audio_path"])},
    {"name": "update_cover", "description": "Change any part of a cover: lyrics, style, singer, tempo, length, or the score itself. Only the fields you pass change. Nothing is rendered until create_take.",
     "inputSchema": schema({"cover_id": COVER_ID, **EDITABLE}, ["cover_id"])},
    {"name": "transcribe", "description": "Listen to a cover's recording and write its score. Needed once per recording, before the first take. Returns a job to follow with get_job.",
     "inputSchema": schema({"cover_id": COVER_ID}, ["cover_id"])},
    {"name": "create_take", "description": "Render the cover as it stands now. Takes several minutes; follow the returned job with get_job. Each take is a new performance.",
     "inputSchema": schema({"cover_id": COVER_ID}, ["cover_id"])},
    {"name": "get_job", "description": "Progress of a transcription or render, and its result when complete.",
     "inputSchema": schema({"job_id": {"type": "string"}}, ["job_id"])},
    {"name": "cancel_job", "description": "Stop a transcription or render that is queued or running.",
     "inputSchema": schema({"job_id": {"type": "string"}}, ["job_id"])},
    {"name": "delete_take", "description": "Delete a finished take and its audio. This cannot be undone.",
     "inputSchema": schema({"job_id": {"type": "string", "description": "The take's job id, from get_cover."}}, ["job_id"])},
]


def load_cover(server, cover_id):
    try:
        uuid.UUID(cover_id)
    except (ValueError, TypeError, AttributeError):
        raise ValueError("Unknown cover. Use list_covers to see the ids.")
    path = server.DATA / "projects" / f"{cover_id}.json"
    if not path.is_file():
        raise ValueError("Unknown cover. Use list_covers to see the ids.")
    return Project.model_validate(json.loads(path.read_text()))


def jobs_of(server, cover_id):
    return [job for job in server.list_jobs() if (job.get("request") or {}).get("project", {}).get("id") == cover_id]


def transcription_of(server, source):
    return next((job for job in server.list_jobs() if job["request"]["kind"] == "transcribe" and job["status"] == "complete"
                 and job["request"].get("source") == source), None) if source else None


def score_for(server, cover):
    """The score a take would render from, and where it came from."""
    if cover.score_edited and cover.abc.strip():
        return cover.abc, "edited", cover.cover_job or "edited"
    heard = transcription_of(server, cover.cover_source)
    if heard:
        return heard["result"].get("full_abc" if cover.cot == "full" else "abc") or "", "transcription", heard["id"]
    return (cover.abc, "saved", cover.cover_job) if cover.abc.strip() else ("", "none", "")


def describe_job(server, job):
    summary = {"job_id": job["id"], "kind": "transcription" if job["request"]["kind"] == "transcribe" else "take",
               "status": job["status"], "stage": job.get("stage", ""), "created_at": job.get("created_at", "")}
    if job["status"] in server.ACTIVE and job.get("progress") is not None:
        summary["progress"] = round(job["progress"], 2)
    if job.get("error"):
        summary["error"] = job["error"]
    tracks = (job.get("result") or {}).get("tracks") or []
    if job["request"]["kind"] == "generate":
        made = job["request"]["project"]
        summary["settings"] = {"style": made.get("style", ""), "vocal_prompt": made.get("vocal_prompt", ""),
                               "keep": "melody_and_harmony" if made.get("cot") == "full" else "melody", "tempo": made.get("tempo", 1)}
        summary["audio"] = [{"wav": str(server.DATA / track["audio"]), "flac": str(server.DATA / track["flac"]) if track.get("flac") else None,
                             "seconds": round(track["duration"], 1), "reached_length_limit": track.get("truncated", False)} for track in tracks]
    return summary


def describe_cover(server, cover, full=False):
    jobs = jobs_of(server, cover.id)
    takes = [job for job in jobs if job["request"]["kind"] == "generate" and (job.get("result") or {}).get("tracks")]
    summary = {"cover_id": cover.id, "title": cover.title, "song": " · ".join(part for part in (cover.song_title, cover.song_artist) if part) or cover.cover_name,
               "style": cover.style, "takes": len(takes), "busy": any(job["status"] in server.ACTIVE for job in jobs), "updated_at": cover.updated_at}
    if not full:
        return summary
    score, origin, _ = score_for(server, cover)
    summary.update({
        "lyrics": cover.lyrics, "vocal_prompt": cover.vocal_prompt, "language": cover.language,
        "keep": "melody_and_harmony" if cover.cot == "full" else "melody", "tempo": cover.tempo,
        "length_seconds": cover.max_tokens / 25, "quality": "high" if cover.engine == "metal-q8" else "standard",
        "recording": str(server.DATA / cover.cover_source) if cover.cover_source else None,
        "score": score, "score_source": origin,
        "jobs": [describe_job(server, job) for job in jobs],
    })
    if origin == "none":
        summary["note"] = "This cover has no score yet. Call transcribe, wait for it to complete, then create_take."
    return summary


def apply_changes(server, cover, changes):
    for key in ("title", "lyrics", "style", "vocal_prompt", "language", "tempo"):
        if key in changes:
            setattr(cover, key, changes[key])
    if "keep" in changes:
        cover.cot = "full" if changes["keep"] == "melody_and_harmony" else "melody"
    if "length_seconds" in changes:
        cover.max_tokens = max(500, min(16000, round(changes["length_seconds"] * 25)))
    if "quality" in changes:
        cover.engine = "metal-q8" if changes["quality"] == "high" else "metal-q4"
    if "score" in changes:
        cover.score_edited = bool(changes["score"].strip())
        cover.abc = changes["score"] if cover.score_edited else ""
    # Validates lengths and ranges exactly as the app's own saves do.
    return server.save_project(Project.model_validate(cover.model_dump()))


def call(server, name, args):
    if name == "status":
        health = server.health()
        running = [describe_job(server, job) for job in server.list_jobs() if job["status"] in server.ACTIVE]
        return {"transcription_installed": health["models"]["covers"], "standard_quality_installed": health["engines"]["metal-q4"],
                "high_quality_installed": health["engines"]["metal-q8"], "memory_available_gb": health["memory"]["available_gib"],
                "library": health["root"], "working_on": running}
    if name == "list_covers":
        return [describe_cover(server, Project.model_validate(cover)) for cover in server.list_projects() if cover.get("app_mode") == "covers"]
    if name == "get_cover":
        return describe_cover(server, load_cover(server, args["cover_id"]), full=True)
    if name == "create_cover":
        source = Path(args["audio_path"]).expanduser()
        if source.suffix.lower() not in AUDIO or not source.is_file():
            raise ValueError("Give the path of an existing WAV, FLAC, MP3, AIFF or M4A file.")
        if source.stat().st_size > 512 * 1024 * 1024:
            raise ValueError("Recordings can be up to 512 MB.")
        relative = f"imports/{uuid.uuid4()}{source.suffix.lower()}"
        shutil.copyfile(source, server.DATA / relative)
        try:
            from .song_lookup import audio_metadata
            details = audio_metadata(server.DATA / relative, source.name)
        except Exception:
            (server.DATA / relative).unlink(missing_ok=True)
            raise ValueError("That recording could not be read, or is longer than 15 minutes.")
        cover = Project(app_mode="covers", cover_source=relative, cover_name=source.stem, song_title=details["title"],
                        song_artist=details["artist"], title=args.get("title") or details["title"] or source.stem,
                        cot="melody", max_tokens=4500, nar_chunk_frames=0, engine="metal-q4")
        saved = apply_changes(server, cover, {key: args[key] for key in ("lyrics", "style", "vocal_prompt", "language") if key in args})
        return describe_cover(server, saved, full=True)
    if name == "update_cover":
        cover = load_cover(server, args["cover_id"])
        if any(job["status"] in server.ACTIVE for job in jobs_of(server, cover.id)):
            raise ValueError("This cover is being rendered. Wait for it, or cancel the job, before changing it.")
        return describe_cover(server, apply_changes(server, cover, args), full=True)
    if name == "transcribe":
        cover = load_cover(server, args["cover_id"])
        if not cover.cover_source:
            raise ValueError("This cover has no recording to listen to.")
        heard = transcription_of(server, cover.cover_source)
        if heard:
            return {"note": "This recording is already transcribed.", **describe_job(server, heard)}
        return describe_job(server, server.create_job(JobRequest(kind="transcribe", project=cover, source=cover.cover_source)))
    if name == "create_take":
        cover = load_cover(server, args["cover_id"])
        if any(job["status"] in server.ACTIVE for job in jobs_of(server, cover.id)):
            raise ValueError("This cover is already being worked on. Follow its job with get_job.")
        score, origin, score_job = score_for(server, cover)
        if cover.cover_source and not score.strip():
            raise ValueError("This cover has no score yet. Call transcribe, wait for it to complete, then try again.")
        cover.abc, cover.cover_job = score, score_job
        # A new seed, so the same settings give a new performance.
        cover.seed = random.randrange(1, 2_000_000_000)
        saved = server.save_project(cover)
        return describe_job(server, server.create_job(JobRequest(kind="generate", project=saved)))
    if name == "get_job":
        return describe_job(server, server.read_job(args["job_id"]))
    if name == "cancel_job":
        return describe_job(server, server.cancel_job(args["job_id"]))
    if name == "delete_take":
        return server.delete_job(args["job_id"])
    raise ValueError(f"Unknown tool: {name}")


@router.post("/mcp")
async def endpoint(request: Request):
    from . import server
    try:
        message = await request.json()
    except ValueError:
        return JSONResponse({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, status_code=400)
    if not isinstance(message, dict):
        return JSONResponse({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Send one request at a time."}}, status_code=400)
    method, identifier = message.get("method"), message.get("id")
    if identifier is None:
        # A notification: acknowledged, never answered.
        return Response(status_code=202)

    def reply(result=None, error=None):
        body = {"jsonrpc": "2.0", "id": identifier}
        body.update({"error": error} if error else {"result": result})
        return JSONResponse(body)

    if method == "initialize":
        asked = (message.get("params") or {}).get("protocolVersion")
        return reply({"protocolVersion": asked if asked in {"2024-11-05", "2025-03-26", PROTOCOL} else PROTOCOL,
                      "capabilities": {"tools": {}}, "serverInfo": {"name": "moonshift", "title": "Moonshift", "version": "1.1.0"},
                      "instructions": INSTRUCTIONS})
    if method == "ping":
        return reply({})
    if method == "tools/list":
        return reply({"tools": TOOLS})
    if method == "tools/call":
        params = message.get("params") or {}
        try:
            with server.LOCK:
                return reply(text(call(server, params.get("name"), params.get("arguments") or {})))
        except HTTPException as problem:
            return reply({**text(str(problem.detail)), "isError": True})
        except (ValueError, KeyError, TypeError) as problem:
            # Tool failures go back as results, so the agent can read them and adjust.
            reason = f"Missing argument: {problem.args[0]}" if isinstance(problem, KeyError) else str(problem)
            return reply({**text(reason), "isError": True})
    return reply(error={"code": -32601, "message": f"Method not found: {method}"})


@router.get("/mcp")
def no_stream():
    # This server answers each request directly and opens no event stream.
    return Response(status_code=405, headers={"Allow": "POST"})
