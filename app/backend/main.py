#!/usr/bin/env python3
"""
proton-download-box – FastAPI backend.

Serves the React dashboard, reports the Proton VPN tunnel state (read-only via
NetworkManager), and provides a small file manager plus a URL downloader.

Everything runs locally. The only outbound traffic is (a) the download jobs the
user starts and (b) an optional public-IP lookup used to prove the tunnel is up.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import logging
import os
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Request,
    Response,
    UploadFile,
)
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

# --------------------------------------------------------------------------- #
# configuration
# --------------------------------------------------------------------------- #

VERSION = "1.0.0"
APP_NAME = "proton-download-box"

PORT = int(os.environ.get("PDB_PORT", "8080"))
DOWNLOAD_DIR = Path(os.environ.get("PDB_DOWNLOAD_DIR", "/srv/downloads")).resolve()
WEB_DIR = Path(os.environ.get("PDB_WEB_DIR", "/opt/proton-download-box/web")).resolve()
PASSWORD = os.environ.get("PDB_PASSWORD", "")
SECRET = os.environ.get("PDB_SECRET", "") or secrets.token_hex(32)
RDP_USER = os.environ.get("PDB_RDP_USER", "proton")
SMB_SHARE = os.environ.get("PDB_SMB_SHARE", "downloads")
COOKIE_NAME = "pdb_session"
COOKIE_MAX_AGE = 7 * 24 * 3600
USER_AGENT = f"{APP_NAME}/{VERSION} (+local)"
MAX_CONCURRENT_JOBS = 3
START_TS = time.time()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
)
log = logging.getLogger(APP_NAME)

DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

# --------------------------------------------------------------------------- #
# auth helpers (stateless HMAC cookie, no extra dependency)
# --------------------------------------------------------------------------- #


def _sign(value: str) -> str:
    return hmac.new(SECRET.encode(), value.encode(), hashlib.sha256).hexdigest()


def _make_token() -> str:
    expires = str(int(time.time()) + COOKIE_MAX_AGE)
    raw = f"{expires}.{_sign(expires)}"
    return base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")


def _verify_token(token: str) -> bool:
    try:
        padded = token + "=" * (-len(token) % 4)
        raw = base64.urlsafe_b64decode(padded.encode()).decode()
        expires, signature = raw.split(".", 1)
        if not hmac.compare_digest(signature, _sign(expires)):
            return False
        return int(expires) > int(time.time())
    except Exception:  # malformed cookie is simply not authenticated
        return False


def require_auth(request: Request) -> None:
    if not PASSWORD:
        return  # no password configured -> open (installer always sets one)
    token = request.cookies.get(COOKIE_NAME, "")
    if not token or not _verify_token(token):
        raise HTTPException(status_code=401, detail="not authenticated")


# --------------------------------------------------------------------------- #
# path helpers
# --------------------------------------------------------------------------- #


def _resolve(rel: str | None) -> Path:
    """Resolve a user-supplied relative path and keep it inside DOWNLOAD_DIR."""
    rel = (rel or "").strip().lstrip("/")
    target = (DOWNLOAD_DIR / rel).resolve()
    if target != DOWNLOAD_DIR and DOWNLOAD_DIR not in target.parents:
        raise HTTPException(status_code=400, detail="path outside download directory")
    return target


def _relative(path: Path) -> str:
    try:
        return path.relative_to(DOWNLOAD_DIR).as_posix()
    except ValueError:
        return ""


def _safe_name(name: str) -> str:
    name = unicodedata.normalize("NFC", name or "")
    name = name.replace("\\", "/").split("/")[-1]
    name = re.sub(r"[\x00-\x1f\x7f]", "", name).strip().strip(".")
    return name[:180] or "download"


def _unique_path(candidate: Path) -> Path:
    if not candidate.exists():
        return candidate
    stem, suffix = candidate.stem, candidate.suffix
    for index in range(1, 1000):
        alternative = candidate.with_name(f"{stem} ({index}){suffix}")
        if not alternative.exists():
            return alternative
    return candidate.with_name(f"{stem}-{secrets.token_hex(3)}{suffix}")


# --------------------------------------------------------------------------- #
# system probes
# --------------------------------------------------------------------------- #

_probe_cache: dict[str, tuple[float, Any]] = {}
_probe_lock = threading.Lock()


def _cached(key: str, ttl: float, fn):
    now = time.time()
    with _probe_lock:
        hit = _probe_cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    value = fn()
    with _probe_lock:
        _probe_cache[key] = (now, value)
    return value


def _run(cmd: list[str], timeout: float = 5.0) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", f"{cmd[0]}: not found"
    except subprocess.TimeoutExpired:
        return 124, "", f"{cmd[0]}: timeout after {timeout}s"
    except Exception as exc:  # pragma: no cover - defensive
        return 1, "", f"{cmd[0]}: {exc}"


def _split_nmcli(line: str) -> list[str]:
    """Split an nmcli -t line on unescaped colons."""
    fields, current, escaped = [], [], False
    for char in line:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(char)
    fields.append("".join(current))
    return fields


def _vpn_state() -> dict[str, Any]:
    code, out, err = _run(
        ["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active"]
    )
    if code != 0:
        return {
            "available": False,
            "connected": False,
            "connection": None,
            "interface": None,
            "type": None,
            "detail": (err or out or "NetworkManager not reachable").strip(),
        }

    connection = interface = conn_type = None
    for line in out.splitlines():
        parts = _split_nmcli(line)
        if len(parts) < 3:
            continue
        name, kind, device = parts[0], parts[1], parts[2]
        is_proton = "proton" in name.lower()
        is_tunnel = kind.lower() in {"wireguard", "vpn", "tun", "tap"} or device.startswith(
            ("proton", "tun", "wg", "ppp")
        )
        if is_proton or (is_tunnel and device and device != "lo"):
            connection, conn_type, interface = name, kind, device or None
            if is_proton:
                break

    return {
        "available": True,
        "connected": connection is not None,
        "connection": connection,
        "interface": interface,
        "type": conn_type,
        "detail": None,
    }


def _public_ip() -> str | None:
    def probe() -> str | None:
        for url in ("https://api.ipify.org", "https://ifconfig.me/ip"):
            try:
                request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(request, timeout=4) as response:
                    value = response.read(64).decode().strip()
                    if value:
                        return value
            except Exception:
                continue
        return None

    return _cached("public_ip", 60.0, probe)


def _service_active(unit: str) -> bool:
    code, out, _ = _run(["systemctl", "is-active", unit])
    return code == 0 and out.strip() == "active"


def _host_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("1.1.1.1", 53))
            return sock.getsockname()[0]
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "127.0.0.1"


def _uptime() -> float:
    try:
        return time.time() - float(Path("/proc/uptime").read_text().split()[0])
    except Exception:
        return time.time() - START_TS


# --------------------------------------------------------------------------- #
# download jobs
# --------------------------------------------------------------------------- #


class _Canceled(Exception):
    pass


@dataclass
class Job:
    id: str
    url: str
    filename: str | None = None
    status: str = "queued"
    downloaded: int = 0
    total: int = 0
    speed: float = 0.0
    error: str | None = None
    path: str | None = None
    created_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    cancel: threading.Event = field(default_factory=threading.Event)


JOBS: dict[str, Job] = {}
JOBS_LOCK = threading.Lock()


def _job_public(job: Job) -> dict[str, Any]:
    return {
        "id": job.id,
        "url": job.url,
        "filename": job.filename,
        "status": job.status,
        "downloaded": job.downloaded,
        "total": job.total,
        "speed": round(job.speed, 1),
        "error": job.error,
        "path": job.path,
        "created_at": job.created_at,
        "finished_at": job.finished_at,
    }


def _name_from_response(response, url: str) -> str:
    disposition = response.headers.get("Content-Disposition", "")
    match = re.search(r"filename\*\s*=\s*[^']*''([^;]+)", disposition, re.I)
    if match:
        return _safe_name(urllib.parse.unquote(match.group(1).strip().strip('"')))
    match = re.search(r'filename\s*=\s*"?([^";]+)"?', disposition, re.I)
    if match:
        return _safe_name(urllib.parse.unquote(match.group(1).strip()))
    path = urllib.parse.urlparse(url).path
    return _safe_name(urllib.parse.unquote(Path(path).name) or "download")


def _run_download(job: Job) -> None:
    part = DOWNLOAD_DIR / f".pdb-part-{job.id}"
    job.status = "running"
    last_time, last_bytes = time.time(), 0
    try:
        request = urllib.request.Request(
            job.url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"}
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            job.total = int(response.headers.get("Content-Length") or 0)
            name = job.filename or _name_from_response(response, job.url)
            final = _unique_path(DOWNLOAD_DIR / _safe_name(name))
            job.filename = final.name

            with open(part, "wb") as handle:
                while True:
                    if job.cancel.is_set():
                        raise _Canceled()
                    chunk = response.read(262_144)
                    if not chunk:
                        break
                    handle.write(chunk)
                    job.downloaded += len(chunk)

                    now = time.time()
                    if now - last_time >= 0.5:
                        job.speed = (job.downloaded - last_bytes) / (now - last_time)
                        last_time, last_bytes = now, job.downloaded

            os.replace(part, final)
            job.path = _relative(final)
            job.status = "done"
            job.speed = 0.0
            if job.total == 0:
                job.total = job.downloaded
    except _Canceled:
        job.status = "canceled"
        job.error = None
    except Exception as exc:  # keep the full reason for the UI
        job.status = "error"
        job.error = f"{type(exc).__name__}: {exc}"
        log.warning("download failed: %s", job.error)
    finally:
        job.finished_at = time.time()
        try:
            if part.exists():
                part.unlink()
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# API models
# --------------------------------------------------------------------------- #


class LoginBody(BaseModel):
    password: str


class MkdirBody(BaseModel):
    path: str = ""
    name: str = Field(min_length=1, max_length=180)


class DeleteBody(BaseModel):
    path: str
    recursive: bool = False


class RenameBody(BaseModel):
    path: str
    name: str = Field(min_length=1, max_length=180)


class JobBody(BaseModel):
    url: str
    filename: str | None = None


# --------------------------------------------------------------------------- #
# app
# --------------------------------------------------------------------------- #

app = FastAPI(title=APP_NAME, version=VERSION, docs_url=None, redoc_url=None)


@app.get("/api/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "app": APP_NAME,
        "version": VERSION,
        "uptime": round(_uptime(), 1),
    }


@app.post("/api/login")
def login(body: LoginBody, response: Response) -> dict[str, bool]:
    if not PASSWORD:
        return {"ok": True}
    if not secrets.compare_digest(body.password, PASSWORD):
        time.sleep(0.4)  # trivial brute-force brake
        raise HTTPException(status_code=401, detail="wrong password")
    response.set_cookie(
        COOKIE_NAME,
        _make_token(),
        max_age=COOKIE_MAX_AGE,
        httponly=True,
        samesite="lax",
        path="/",
    )
    return {"ok": True}


@app.post("/api/logout")
def logout(response: Response) -> dict[str, bool]:
    response.delete_cookie(COOKIE_NAME, path="/")
    return {"ok": True}


@app.get("/api/session", dependencies=[Depends(require_auth)])
def session() -> dict[str, bool]:
    return {"authenticated": True}


@app.get("/api/status", dependencies=[Depends(require_auth)])
def status() -> dict[str, Any]:
    vpn = _vpn_state()
    try:
        usage = shutil.disk_usage(DOWNLOAD_DIR)
        disk = {
            "total": usage.total,
            "used": usage.used,
            "free": usage.free,
        }
    except OSError as exc:
        disk = {"total": 0, "used": 0, "free": 0, "error": str(exc)}

    return {
        "app": APP_NAME,
        "version": VERSION,
        "hostname": socket.gethostname(),
        "ip": _host_ip(),
        "port": PORT,
        "uptime": round(_uptime(), 1),
        "download_dir": str(DOWNLOAD_DIR),
        "vpn": {**vpn, "public_ip": _public_ip() if vpn["connected"] else None},
        "disk": disk,
        "services": {
            "web": True,
            "xrdp": _service_active("xrdp"),
            "networkmanager": _service_active("NetworkManager"),
            "smbd": _service_active("smbd"),
        },
        "rdp": {"host": _host_ip(), "port": 3389, "user": RDP_USER},
        "samba": {"share": SMB_SHARE, "path": str(DOWNLOAD_DIR)},
    }


@app.get("/api/files", dependencies=[Depends(require_auth)])
def list_files(path: str = "") -> dict[str, Any]:
    target = _resolve(path)
    if not target.is_dir():
        raise HTTPException(status_code=404, detail="directory not found")

    entries = []
    try:
        children = sorted(
            target.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower())
        )
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc

    for child in children:
        try:
            stat = child.stat()
        except OSError:
            continue
        entries.append(
            {
                "name": child.name,
                "path": _relative(child),
                "is_dir": child.is_dir(),
                "size": 0 if child.is_dir() else stat.st_size,
                "mtime": stat.st_mtime,
            }
        )

    parent = _relative(target.parent) if target != DOWNLOAD_DIR else None
    return {
        "path": _relative(target),
        "parent": parent,
        "entries": entries,
        "writable": os.access(target, os.W_OK),
    }


@app.get("/api/files/download", dependencies=[Depends(require_auth)])
def download_file(path: str):
    target = _resolve(path)
    if not target.is_file():
        raise HTTPException(status_code=404, detail="file not found")
    return FileResponse(
        target,
        filename=target.name,
        media_type="application/octet-stream",
        headers={"X-Content-Type-Options": "nosniff"},
    )


@app.post("/api/files/mkdir", dependencies=[Depends(require_auth)])
def make_dir(body: MkdirBody) -> dict[str, str]:
    parent = _resolve(body.path)
    if not parent.is_dir():
        raise HTTPException(status_code=404, detail="directory not found")
    target = parent / _safe_name(body.name)
    if target.exists():
        raise HTTPException(status_code=409, detail="already exists")
    try:
        target.mkdir()
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"path": _relative(target)}


@app.post("/api/files/delete", dependencies=[Depends(require_auth)])
def delete_entry(body: DeleteBody) -> dict[str, bool]:
    target = _resolve(body.path)
    if target == DOWNLOAD_DIR:
        raise HTTPException(status_code=400, detail="refusing to delete the root")
    if not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    try:
        if target.is_dir():
            if body.recursive:
                shutil.rmtree(target)
            else:
                target.rmdir()
        else:
            target.unlink()
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True}


@app.post("/api/files/rename", dependencies=[Depends(require_auth)])
def rename_entry(body: RenameBody) -> dict[str, str]:
    target = _resolve(body.path)
    if target == DOWNLOAD_DIR or not target.exists():
        raise HTTPException(status_code=404, detail="not found")
    destination = target.with_name(_safe_name(body.name))
    if destination.exists():
        raise HTTPException(status_code=409, detail="already exists")
    try:
        target.rename(destination)
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"path": _relative(destination)}


@app.post("/api/files/upload", dependencies=[Depends(require_auth)])
async def upload_file(
    file: UploadFile = File(...), path: str = Form("")
) -> dict[str, Any]:
    directory = _resolve(path)
    if not directory.is_dir():
        raise HTTPException(status_code=404, detail="directory not found")

    destination = _unique_path(directory / _safe_name(file.filename or "upload.bin"))
    size = 0
    try:
        with open(destination, "wb") as handle:
            while chunk := await file.read(1024 * 1024):
                handle.write(chunk)
                size += len(chunk)
    except OSError as exc:
        try:
            destination.unlink()
        except OSError:
            pass
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    finally:
        await file.close()

    return {"path": _relative(destination), "size": size}


@app.get("/api/jobs", dependencies=[Depends(require_auth)])
def list_jobs() -> dict[str, Any]:
    with JOBS_LOCK:
        jobs = sorted(JOBS.values(), key=lambda job: job.created_at, reverse=True)
    return {"jobs": [_job_public(job) for job in jobs[:50]]}


@app.post("/api/jobs", dependencies=[Depends(require_auth)])
def create_job(body: JobBody) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(body.url.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="only http(s) URLs are supported")

    with JOBS_LOCK:
        running = sum(1 for job in JOBS.values() if job.status in {"queued", "running"})
        if running >= MAX_CONCURRENT_JOBS:
            raise HTTPException(
                status_code=429,
                detail=f"at most {MAX_CONCURRENT_JOBS} downloads at a time",
            )
        job = Job(
            id=secrets.token_hex(6),
            url=body.url.strip(),
            filename=_safe_name(body.filename) if body.filename else None,
        )
        JOBS[job.id] = job

    threading.Thread(target=_run_download, args=(job,), daemon=True).start()
    log.info("download started: %s -> %s", job.url, job.filename or "auto")
    return _job_public(job)


@app.post("/api/jobs/{job_id}/cancel", dependencies=[Depends(require_auth)])
def cancel_job(job_id: str) -> dict[str, Any]:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="job not found")
    if job.status in {"queued", "running"}:
        job.cancel.set()
    return _job_public(job)


@app.delete("/api/jobs/{job_id}", dependencies=[Depends(require_auth)])
def remove_job(job_id: str) -> dict[str, bool]:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="job not found")
        if job.status in {"queued", "running"}:
            raise HTTPException(status_code=409, detail="job still running")
        JOBS.pop(job_id, None)
    return {"ok": True}


# --------------------------------------------------------------------------- #
# static SPA
# --------------------------------------------------------------------------- #

if (WEB_DIR / "assets").is_dir():
    app.mount("/assets", StaticFiles(directory=WEB_DIR / "assets"), name="assets")


@app.get("/{full_path:path}", include_in_schema=False)
def spa(full_path: str):
    if full_path.startswith("api/"):
        return JSONResponse({"detail": "not found"}, status_code=404)

    index = WEB_DIR / "index.html"
    if not index.is_file():
        return JSONResponse(
            {
                "detail": "frontend not built",
                "hint": "expected index.html in PDB_WEB_DIR",
                "web_dir": str(WEB_DIR),
            },
            status_code=503,
        )

    if full_path:
        candidate = (WEB_DIR / full_path).resolve()
        if WEB_DIR in candidate.parents and candidate.is_file():
            return FileResponse(candidate)

    return FileResponse(index, headers={"Cache-Control": "no-cache"})


def run() -> None:
    import uvicorn

    log.info("starting %s %s on 0.0.0.0:%s", APP_NAME, VERSION, PORT)
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=PORT,
        log_level=os.environ.get("PDB_LOG_LEVEL", "info"),
        access_log=False,
        proxy_headers=True,
    )


if __name__ == "__main__":
    run()
