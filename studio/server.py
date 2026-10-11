"""Loopback-only job service for the native app. All writes live in ROOT."""
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

import psutil
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from .models import JobRequest, Project
from .paths import CODE, HOME
from .resources import estimate, memory_snapshot, process_tree_footprint, stop_process_group, installed, covers_installed

# Bump when the native client needs a newer service than one already running.
API_VERSION = 3
ROOT = HOME
DATA = ROOT / "data"
for name in ("projects", "jobs", "imports", "exports"):
    (DATA / name).mkdir(parents=True, exist_ok=True)
LOCK = threading.RLock()
TASKS = queue.Queue()
PROCESSES = {}
CLIENTS = {}
WORKING = threading.Event()
# Parsed job and cover files, keyed by path and reused until the file changes.
CACHE = {}
ACTIVE = {"queued", "running"}


def now():
    return datetime.now(timezone.utc).isoformat()


def managed():
    """True when the native app launched this service and owns its lifetime."""
    return os.environ.get("MOONSHIFT_MANAGED") == "1"


def write_json(path, value):
    with LOCK:
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(value, ensure_ascii=False, indent=2))
        temp.replace(path)


def job_path(job_id):
    try:
        uuid.UUID(job_id)
    except ValueError:
        raise HTTPException(404, "Unknown job")
    return DATA / "jobs" / job_id


def read_job(job_id):
    path = job_path(job_id) / "job.json"
    if not path.exists():
        raise HTTPException(404, "Unknown job")
    with LOCK:
        return json.loads(path.read_text())


def update_job(job_id, **changes):
    with LOCK:
        job = read_job(job_id)
        # Cancellation wins over a worker that is finishing concurrently.
        if job["status"] in {"cancelled", "failed"} and changes.get("status") != job["status"]:
            return
        job.update(changes)
        write_json(job_path(job_id) / "job.json", job)


def resolve_data_file(relative):
    path = (DATA / relative).resolve()
    if not path.is_relative_to(DATA.resolve()) or not path.is_file():
        raise HTTPException(404, "Audio file not found")
    return path


def scan(directory, pattern):
    """Current files with a change signature; reading them is deferred to load()."""
    found = []
    for path in directory.glob(pattern):
        try:
            stat = path.stat()
        except FileNotFoundError:
            continue
        found.append((path, (stat.st_mtime_ns, stat.st_size, stat.st_ino)))
    return found


def load(entries):
    """Parse only files that changed since the last poll."""
    values = []
    for path, signature in entries:
        cached = CACHE.get(path)
        if cached is None or cached[0] != signature:
            try:
                value = json.loads(path.read_text())
            except (FileNotFoundError, ValueError):
                continue
            if path.name == "job.json":
                request = value.get("request") or {}
                # A stopped render can continue from its saved song tokens.
                value["resumable"] = (value.get("status") in {"failed", "cancelled"} and request.get("kind") == "generate"
                                      and (path.parent / "take-1/semantic-prefix.json").is_file())
            cached = CACHE[path] = (signature, value)
        values.append(cached[1])
    return values


def list_jobs(entries=None):
    values = [job for job in load(scan(DATA / "jobs", "*/job.json") if entries is None else entries) if "created_at" in job]
    return sorted(values, key=lambda job: job["created_at"], reverse=True)


def list_projects(entries=None):
    values = load(scan(DATA / "projects", "*.json") if entries is None else entries)
    return sorted(values, key=lambda project: project.get("updated_at", ""), reverse=True)


def queued_estimate(project, kind="generate"):
    forecast = estimate(project, kind)
    with LOCK:
        released = sum(read_job(key).get("memory_gib", 0) for key in PROCESSES)
    if released:
        future = dict(forecast["memory"])
        future["available_gib"] = min(future["total_gib"], future["available_gib"] + released)
        result = estimate(project, kind, memory=future)
        result["memory"] = forecast["memory"]
    else:
        result = forecast
    result["queued_reclaim_gib"] = round(released, 1)
    return result


def monitor_worker(job_id, proc, limit, stopped, progress=None):
    peak = 0.0
    pressure_samples = 0
    reported = (None, 0.0)
    while not stopped.wait(.5) and proc.poll() is None:
        guard_stage = "Memory guard"
        try:
            used = process_tree_footprint(proc.pid)
            peak = max(peak, used)
            mem = memory_snapshot()
            # The guard samples twice a second; the job file only needs visible changes.
            if reported[0] is None or abs(used - reported[0]) >= .1 or time.monotonic() - reported[1] > 5:
                update_job(job_id, memory_gib=round(used, 2), peak_memory_gib=round(peak, 2), memory_limit_gib=limit)
                reported = (used, time.monotonic())
            pressure_samples = pressure_samples + 1 if mem["available_gib"] < 3 else 0
            if used > limit or pressure_samples >= 3:
                update_job(job_id, memory_gib=round(used, 2), peak_memory_gib=round(peak, 2), memory_limit_gib=limit)
                raise RuntimeError(f"Memory guard stopped this job at {used:.1f} GB (limit {limit:.1f} GB, {mem['available_gib']:.1f} GB available). Try 4-bit, a shorter length, or close other heavy apps.")
            if progress is not None and time.monotonic() - progress[0] > 180:
                guard_stage = "Progress guard"
                raise RuntimeError("The music engine made no progress for three minutes and was stopped. The song it wrote is saved: resume rendering in sections to finish it.")
        except psutil.NoSuchProcess:
            return
        except Exception as exc:
            update_job(job_id, status="failed", stage=guard_stage, error=str(exc), finished_at=now())
            stop_process_group(proc)
            return


def acquire_engine_lock(job_id):
    """Serialize model workers across Moonwire and Moonshift services."""
    directory = ROOT / ".runtime"
    directory.mkdir(exist_ok=True)
    lease = (directory / "model-job.lock").open("a+")
    waiting = False
    try:
        while read_job(job_id)["status"] != "cancelled":
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return lease
            except BlockingIOError:
                if not waiting:
                    update_job(job_id, stage="Waiting for another local music job")
                    waiting = True
                time.sleep(.5)
    except BaseException:
        lease.close()
        raise
    lease.close()
    return None


def worker_loop():
    cleanup_error = None
    while True:
        job_id = TASKS.get()
        WORKING.set()
        proc = None
        engine_lease = None
        stopped = threading.Event()
        monitor = None
        heartbeat = [time.monotonic()]
        try:
            engine_lease = acquire_engine_lock(job_id)
            if engine_lease is None:
                continue
            with LOCK:
                job = read_job(job_id)
                if job["status"] == "cancelled":
                    continue
                if cleanup_error:
                    raise RuntimeError(cleanup_error)
                kind = job["request"]["kind"]
                forecast = estimate(job["request"]["project"], kind)
                if not forecast["allowed"]:
                    raise RuntimeError(forecast["reason"])
                # Recheck after queueing; another application may have used memory.
                limit = min(forecast["memory"]["limit_gib"], forecast["memory"]["available_gib"] - forecast["memory"]["reserve_gib"])
                job["request"]["project"]["engine"] = forecast["engine"]
                update_job(job_id, request=job["request"], estimate=forecast, memory_limit_gib=round(limit, 2))
                python = ROOT / (".covers-venv" if kind == "transcribe" else ".venv") / "bin/python"
                if not python.exists():
                    raise RuntimeError("The local engines are not installed yet. Install them in Settings.")
                env = dict(os.environ, PYTHONUNBUFFERED="1", HF_HOME=str(ROOT / ".cache/huggingface"),
                           XDG_CACHE_HOME=str(ROOT / ".cache"), TORCH_HOME=str(ROOT / ".cache/torch"),
                           TMPDIR=str(ROOT / ".cache/tmp"), HF_HUB_OFFLINE="1", HF_MODULES_CACHE=str(ROOT / ".cache/huggingface/modules"),
                           TOKENIZERS_PARALLELISM="false")
                # The transcription model looks for FFmpeg on the PATH; setup installs one here.
                env["PATH"] = os.pathsep.join([str(ROOT / ".runtime/bin"), "/opt/homebrew/bin", "/usr/local/bin", env.get("PATH", "")])
                Path(env["TMPDIR"]).mkdir(parents=True, exist_ok=True)
                update_job(job_id, status="running", stage="Loading engine", started_at=now())
                proc = subprocess.Popen([str(python), "-m", "studio.worker", str(job_path(job_id))],
                                        cwd=CODE, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, start_new_session=True)
                PROCESSES[job_id] = proc
            monitor = threading.Thread(target=monitor_worker, args=(job_id, proc, limit, stopped, heartbeat if kind == "generate" else None), daemon=True)
            monitor.start()
            with (job_path(job_id) / "worker.log").open("w") as log:
                for line in proc.stdout:
                    log.write(line)
                    log.flush()
                    if line.startswith("STUDIO_EVENT "):
                        try:
                            event = json.loads(line[len("STUDIO_EVENT "):])
                            heartbeat[0] = time.monotonic()
                            update_job(job_id, **event)
                        except (ValueError, TypeError):
                            pass
                    else:
                        progress = re.search(r"Running (Synthesizing audio|Decoding audio): (\d+)/(\d+) (steps|chunks)", line)
                        if progress:
                            heartbeat[0] = time.monotonic()
                            label, completed, total, _ = progress.groups()
                            decoding = label == "Decoding audio"
                            update_job(job_id, stage="Decoding stereo audio" if decoding else "Rendering acoustic detail",
                                       phase="finish" if decoding else "render", progress=min(1, int(completed) / max(1, int(total))))
            code = proc.wait()
            if read_job(job_id)["status"] not in {"cancelled", "failed"}:
                if code == 0 and (job_path(job_id) / "output.json").exists():
                    output = json.loads((job_path(job_id) / "output.json").read_text())
                    update_job(job_id, status="complete", stage="Complete", result=output, finished_at=now())
                else:
                    error_path = job_path(job_id) / "error.json"
                    error = json.loads(error_path.read_text())["error"] if error_path.exists() else "The engine exited unexpectedly."
                    update_job(job_id, status="failed", stage="Failed", error=error, finished_at=now())
        except Exception as exc:
            update_job(job_id, status="failed", stage="Failed", error=str(exc), finished_at=now())
        finally:
            stopped.set()
            if proc is not None:
                try:
                    stop_process_group(proc)
                except Exception as exc:
                    # Do not load another model if ejection cannot be confirmed.
                    cleanup_error = str(exc)
                    update_job(job_id, status="failed", stage="Engine cleanup failed", error=cleanup_error, finished_at=now())
            if monitor is not None:
                monitor.join(timeout=10)
            with LOCK:
                PROCESSES.pop(job_id, None)
            if engine_lease is not None:
                engine_lease.close()
            WORKING.clear()
            TASKS.task_done()


def orphan_watchdog():
    """Exit once the app that launched this service is gone and its work is done."""
    attached = False
    idle = 0
    while True:
        time.sleep(10)
        with LOCK:
            clients = live_clients()
        attached = attached or clients > 0
        busy = WORKING.is_set() or not TASKS.empty()
        idle = idle + 1 if attached and not clients and not busy else 0
        if idle >= 3:
            os.kill(os.getpid(), signal.SIGTERM)
            return


@asynccontextmanager
async def lifespan(app):
    for path in (DATA / "jobs").glob("*/job.json"):
        job = json.loads(path.read_text())
        if job.get("status") in ACTIVE:
            job.update(status="failed", stage="Interrupted", error="Moonshift closed during this job. Create it again.", finished_at=now())
            write_json(path, job)
    threading.Thread(target=worker_loop, daemon=True).start()
    if managed():
        threading.Thread(target=orphan_watchdog, daemon=True).start()
    yield
    with LOCK:
        owned = list(PROCESSES.values())
    for proc in owned:
        stop_process_group(proc)


app = FastAPI(title="Moonshift", lifespan=lifespan)


class SongLookupRequest(BaseModel):
    source: str = ""
    name: str = Field(default="", max_length=500)
    title: str = Field(default="", max_length=300)
    artist: str = Field(default="", max_length=300)
    duration: float = Field(default=0, ge=0, le=900, allow_inf_nan=False)


class LyricsImportRequest(BaseModel):
    text: str = Field(max_length=1000000)
    extension: str = ".txt"


@app.middleware("http")
async def local_only(request: Request, call_next):
    # A web page cannot reach the service from another origin, nor by pointing
    # its own hostname at the loopback address.
    origin = request.headers.get("origin")
    host = request.headers.get("host", "").rsplit(":", 1)[0]
    if (origin and not re.fullmatch(r"http://(127\.0\.0\.1|localhost)(:\d+)?", origin)) or host not in {"127.0.0.1", "localhost", "testserver"}:
        return JSONResponse({"detail": "Local requests only"}, status_code=403)
    return await call_next(request)


def live_clients():
    cutoff = time.monotonic() - 30
    for key, heartbeat in list(CLIENTS.items()):
        if heartbeat < cutoff:
            CLIENTS.pop(key, None)
    return len(CLIENTS)


def stop_soon():
    def stop_if_unused():
        with LOCK:
            if not live_clients():
                os.kill(os.getpid(), signal.SIGTERM)
    # Let the final client receive its response before graceful uvicorn exit.
    threading.Timer(.5, stop_if_unused).start()


@app.post("/api/clients/{client_id}")
def attach_client(client_id: str):
    with LOCK:
        CLIENTS[client_id] = time.monotonic()
        return {"remaining": live_clients()}


@app.delete("/api/clients/{client_id}")
def release_client(client_id: str):
    with LOCK:
        CLIENTS.pop(client_id, None)
        remaining = live_clients()
    if not remaining and managed():
        stop_soon()
    return {"remaining": remaining}


@app.post("/api/shutdown")
def shutdown():
    """Lets a newer app replace an idle service left behind by an older build."""
    if not managed():
        raise HTTPException(403, "This service was started by hand.")
    if WORKING.is_set() or not TASKS.empty():
        raise HTTPException(409, "A cover is still being created.")
    with LOCK:
        CLIENTS.clear()
    stop_soon()
    return {"stopping": True}


@app.get("/api/health")
def health():
    from .song_lookup import lookup_installed
    return {"app": "Moonshift", "api": API_VERSION, "root": str(ROOT), "data_path": str(DATA),
            "models": {"covers": covers_installed(), "lookup": lookup_installed(ROOT)},
            "engines": {"metal-q8": installed("metal-q8"), "metal-q4": installed("metal-q4")},
            "memory": memory_snapshot()}


@app.get("/api/state")
def state(request: Request, client: str = ""):
    """Everything the app lists, with an ETag so an idle poll costs a few stats."""
    with LOCK:
        if client:
            CLIENTS[client] = time.monotonic()
        jobs, projects = scan(DATA / "jobs", "*/job.json"), scan(DATA / "projects", "*.json")
        digest = hashlib.blake2s(repr(sorted((str(path), signature) for path, signature in jobs + projects)).encode(), digest_size=12).hexdigest()
        if request.headers.get("if-none-match") == digest:
            return Response(status_code=304, headers={"ETag": digest})
        for path in set(CACHE) - {path for path, _ in jobs + projects}:
            del CACHE[path]
        body = {"revision": digest, "jobs": list_jobs(jobs), "projects": list_projects(projects)}
    return JSONResponse(body, headers={"ETag": digest})


@app.post("/api/estimate")
def render_estimate(project: Project):
    return queued_estimate(project.model_dump())


@app.post("/api/cover/metadata")
def cover_metadata(request: SongLookupRequest):
    from .song_lookup import audio_metadata
    source = resolve_data_file(request.source)
    try:
        return audio_metadata(source, request.name)
    except (ValueError, subprocess.SubprocessError, FileNotFoundError):
        raise HTTPException(400, "This audio could not be read. Choose a playable recording up to 15 minutes long.")


@app.post("/api/cover/identify")
def identify_song(request: SongLookupRequest):
    from .song_lookup import recognize
    source = resolve_data_file(request.source)
    (ROOT / ".cache/tmp").mkdir(parents=True, exist_ok=True)
    try:
        return recognize(source, ROOT)
    except (ValueError, subprocess.SubprocessError, FileNotFoundError):
        raise HTTPException(503, "Song identification is unavailable. Enter the song name and search, or import lyrics.")


@app.post("/api/cover/lyrics/search")
def find_lyrics(request: SongLookupRequest):
    from .song_lookup import search_lyrics
    import httpx
    try:
        return {"candidates": search_lyrics(request.title, request.artist, request.duration)}
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    except httpx.HTTPError:
        raise HTTPException(503, "The lyric service is unavailable. Try later, import a lyric file, or paste the words.")


@app.post("/api/cover/lyrics/import")
def import_lyrics(request: LyricsImportRequest):
    from .song_lookup import parse_lyrics
    if request.extension.lower() not in {".txt", ".srt", ".lrc", ".vtt"}:
        raise HTTPException(400, "Import TXT, SRT, LRC or WebVTT lyrics.")
    try:
        return {"lyrics": parse_lyrics(request.text, request.extension)}
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@app.get("/api/projects")
def projects():
    with LOCK:
        return list_projects()


@app.post("/api/projects")
def save_project(project: Project):
    if project.id:
        try:
            uuid.UUID(project.id)
        except ValueError:
            raise HTTPException(400, "Invalid cover identifier")
    else:
        project.id = str(uuid.uuid4())
    project.updated_at = now()
    write_json(DATA / "projects" / f"{project.id}.json", project.model_dump())
    return project


@app.delete("/api/projects/{project_id}")
def delete_project(project_id: str):
    """Remove a cover, its takes, and its recording when no other cover uses it."""
    try:
        uuid.UUID(project_id)
    except ValueError:
        raise HTTPException(404, "Unknown cover")
    path = DATA / "projects" / f"{project_id}.json"
    with LOCK:
        if not path.is_file():
            raise HTTPException(404, "Unknown cover")
        project = json.loads(path.read_text())
        owned = [job for job in list_jobs() if (job.get("request") or {}).get("project", {}).get("id") == project_id]
        if any(job["status"] in ACTIVE for job in owned):
            raise HTTPException(409, "Cancel this cover's job before deleting it.")
        for job in owned:
            shutil.rmtree(job_path(job["id"]), ignore_errors=True)
        path.unlink()
        source = project.get("cover_source") or ""
        if source.startswith("imports/") and not any(other.get("cover_source") == source for other in list_projects()):
            (DATA / source).unlink(missing_ok=True)
    return {"deleted": project_id, "jobs": len(owned)}


@app.get("/api/jobs")
def jobs():
    with LOCK:
        return list_jobs()


@app.post("/api/jobs")
def create_job(request: JobRequest):
    # Store the exact cover snapshot; edits during generation never alter a job.
    if request.kind == "transcribe":
        resolve_data_file(request.source)
    if request.project.cover_source:
        resolve_data_file(request.project.cover_source)
    if request.resume_from:
        prior = read_job(request.resume_from)
        if not (job_path(request.resume_from) / "take-1/semantic-prefix.json").is_file():
            raise HTTPException(409, "This job has no saved song to resume.")
        for field in ("lyrics", "style", "abc", "tempo", "cot", "language", "vocal_prompt", "seed", "cfg_scale", "temperature"):
            if prior["request"]["project"].get(field, Project.model_fields[field].default) != getattr(request.project, field):
                raise HTTPException(409, "Resume preserves the saved song. Keep lyrics, style, score, voice, seed, and sampling unchanged.")
    forecast = queued_estimate(request.project.model_dump(), request.kind)
    if not forecast["allowed"]:
        raise HTTPException(409, forecast["reason"])
    job_id = str(uuid.uuid4())
    path = job_path(job_id)
    path.mkdir()
    job = {"id": job_id, "status": "queued", "stage": "Queued", "created_at": now(),
           "request": request.model_dump(), "result": {}, "error": "", "tokens": 0, "take": 1, "estimate": forecast}
    write_json(path / "job.json", job)
    TASKS.put(job_id)
    return job


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str):
    return read_job(job_id)


@app.post("/api/jobs/{job_id}/cancel")
def cancel_job(job_id: str):
    with LOCK:
        job = read_job(job_id)
        if job["status"] in ACTIVE:
            update_job(job_id, status="cancelled", stage="Cancelled", finished_at=now())
            proc = PROCESSES.get(job_id)
            if proc:
                threading.Thread(target=stop_process_group, args=(proc,), daemon=True).start()
    return read_job(job_id)


@app.delete("/api/jobs/{job_id}")
def delete_job(job_id: str):
    with LOCK:
        if read_job(job_id).get("status") in ACTIVE:
            raise HTTPException(409, "Cancel this job before deleting it.")
        shutil.rmtree(job_path(job_id))
    return {"deleted": job_id}


@app.post("/api/import")
async def import_audio(request: Request):
    # Native client sends the audio body directly, avoiding multipart copies.
    suffix = Path(request.headers.get("x-filename", "audio.wav")).suffix.lower()
    if suffix not in {".wav", ".flac", ".mp3", ".aiff", ".aif", ".m4a"}:
        raise HTTPException(400, "Import WAV, FLAC, MP3, AIFF or M4A audio")
    relative = f"imports/{uuid.uuid4()}{suffix}"
    path = DATA / relative
    size = 0
    try:
        with path.open("wb") as output:
            async for block in request.stream():
                size += len(block)
                if size > 512 * 1024 * 1024:
                    raise HTTPException(413, "Maximum audio import size is 512 MB")
                output.write(block)
    except Exception:
        path.unlink(missing_ok=True)
        raise
    return {"source": relative}


@app.get("/api/files/{relative:path}")
def audio_file(relative: str):
    path = resolve_data_file(relative)
    return FileResponse(path, filename=path.name)


# Agents reach the same covers through the Model Context Protocol.
from .mcp import router as mcp_router  # noqa: E402

app.include_router(mcp_router)
