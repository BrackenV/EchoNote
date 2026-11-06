"""EchoNote's local, single-session Parakeet WebSocket server.

This implementation uses only Python's standard library for networking. It
loads the existing Lecture Transcriber engine from its current checkout and
uses that engine's cached Parakeet model; it never installs or downloads model
weights itself. See SERVER_DESIGN_BRIEF.md before changing the protocol.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import struct
import sys
import time
import uuid
from array import array
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
RUNTIME_ROOT = Path(os.environ.get("ECHONOTE_RUNTIME_ROOT", str(ROOT / ".echonote-runtime")))
METRICS_DB = Path(os.environ.get("ECHONOTE_METRICS_DB", str(RUNTIME_ROOT / "logs" / "session_metrics.sqlite3")))
TRANSCRIPT_DIR = Path(os.environ.get("ECHONOTE_TRANSCRIPT_DIR", str(RUNTIME_ROOT / "transcripts")))
DEFAULT_LECTURE_TRANSCRIBER = Path(
    r"C:\Users\ellih\Desktop\Personal\University Work Y1\Lecture Transcriber"
)
LECTURE_TRANSCRIBER = Path(
    os.environ.get("ECHONOTE_LECTURE_TRANSCRIBER", str(DEFAULT_LECTURE_TRANSCRIBER))
).expanduser()
MODEL_ID = "nvidia/parakeet-tdt-0.6b-v2"

HOST = os.environ.get("ECHONOTE_HOST", "127.0.0.1")
PORT = int(os.environ.get("ECHONOTE_PORT", "8765"))
SAMPLE_RATE = 16_000
CHANNELS = 1
SAMPLE_WIDTH = 2
DEFAULT_SEGMENT_SECONDS = 10
ALLOWED_SEGMENT_SECONDS = {5, 10, 15, 30}
MAX_FRAME_BYTES = 256 * 1024
MAX_MESSAGE_BYTES = MAX_FRAME_BYTES
TRANSCRIPTION_QUEUE_SIZE = 3
PROTOCOL_VERSION = 1
WEBSOCKET_IDLE_TIMEOUT_SECONDS = 10

logging.basicConfig(level=os.environ.get("ECHONOTE_LOG_LEVEL", "INFO"))
log = logging.getLogger("echonote.server")
ACTIVE_SESSION = asyncio.Lock()


class ProtocolError(Exception):
    def __init__(self, code: str, message: str, close_code: int = 1008) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.close_code = close_code


@dataclass(frozen=True)
class AudioSegment:
    index: int
    pcm: bytes


def _load_lecture_engine() -> Any:
    """Import the existing engine after setting its model cache environment."""
    if not LECTURE_TRANSCRIBER.is_dir():
        raise RuntimeError(f"Lecture Transcriber folder is missing: {LECTURE_TRANSCRIBER}")
    storage_override = os.environ.get("ECHONOTE_MODEL_STORAGE_ROOT")
    storage_pointer = LECTURE_TRANSCRIBER / "model_storage_path.txt"
    if storage_override:
        model_root = Path(storage_override).expanduser().resolve()
    elif storage_pointer.is_file():
        model_root = Path(storage_pointer.read_text(encoding="utf-8").strip()).expanduser()
    else:
        raise RuntimeError(f"Lecture Transcriber's model storage pointer is missing: {storage_pointer}")
    model_cache = model_root / "huggingface" / "hub" / "models--nvidia--parakeet-tdt-0.6b-v2"
    if not model_cache.is_dir():
        raise RuntimeError(f"The shared Parakeet cache folder is missing: {model_cache}")

    os.environ["HF_HOME"] = str(model_root / "huggingface")
    os.environ["HUGGINGFACE_HUB_CACHE"] = str(model_root / "huggingface" / "hub")
    os.environ["HF_HUB_CACHE"] = str(model_root / "huggingface" / "hub")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["NEMO_CACHE_DIR"] = str(model_root / "nemo")
    os.environ["TORCH_HOME"] = str(model_root / "torch")
    os.environ["XDG_CACHE_HOME"] = str(model_root / "cache")

    sys.path.insert(0, str(LECTURE_TRANSCRIBER))
    import transcribe_engine  # type: ignore[import-not-found]

    if transcribe_engine.MODEL_ID != MODEL_ID:
        raise RuntimeError("Lecture Transcriber is configured for a different model.")
    runtime_override = os.environ.get("ECHONOTE_RUNTIME_ROOT")
    if runtime_override:
        from storage import StoragePaths  # type: ignore[import-not-found]

        root = Path(runtime_override).expanduser().resolve()

        def prepare_isolated_storage() -> Any:
            paths = StoragePaths(
                root=root,
                huggingface=model_root / "huggingface",
                torch_home=root / "torch",
                temp=root / "temp",
                logs=root / "logs",
            )
            for folder in (paths.torch_home, paths.temp, paths.logs, root / "nemo", root / "cache"):
                folder.mkdir(parents=True, exist_ok=True)
            os.environ["NEMO_CACHE_DIR"] = str(root / "nemo")
            os.environ["TORCH_HOME"] = str(paths.torch_home)
            os.environ["XDG_CACHE_HOME"] = str(root / "cache")
            return paths

        transcribe_engine.prepare_storage = prepare_isolated_storage
    return transcribe_engine


def _load_cached_model(engine: Any) -> tuple[Any, str]:
    """Restore the verified local .nemo artifact without Hub requests."""
    paths = engine.prepare_storage()
    repo_cache = Path(paths.huggingface) / "hub" / "models--nvidia--parakeet-tdt-0.6b-v2"
    ref_path = repo_cache / "refs" / "main"
    if ref_path.is_file():
        revision = ref_path.read_text(encoding="utf-8").strip()
        if not revision or any(character not in "0123456789abcdef" for character in revision.lower()):
            raise RuntimeError("Parakeet cache contains an invalid revision pointer.")
        candidates = [repo_cache / "snapshots" / revision / "parakeet-tdt-0.6b-v2.nemo"]
    else:
        # Downloads pinned to an immutable commit need not create refs/main.
        candidates = list((repo_cache / "snapshots").glob("*/parakeet-tdt-0.6b-v2.nemo"))
    matching_files = [path for path in candidates if path.is_file() and path.stat().st_size == 2_472_222_720]
    if len(matching_files) != 1:
        expected_file = candidates[0] if candidates else repo_cache / "snapshots"
        raise RuntimeError(f"The shared Parakeet model file is missing or incomplete: {expected_file}")
    model_file = matching_files[0]
    if not model_file.is_file():
        raise RuntimeError(f"The shared Parakeet model file is missing or incomplete: {model_file}")

    try:
        import torch
        import nemo.collections.asr as nemo_asr
    except ImportError as exc:
        raise RuntimeError("The Lecture Transcriber Python environment is missing NeMo or PyTorch.") from exc

    for logger_name in ("nemo", "nemo_logger", "nemo.collections"):
        logging.getLogger(logger_name).setLevel(logging.ERROR)
    torch.set_float32_matmul_precision("high")
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True

    # restore_from reads the cached .nemo path directly. Keep HF offline mode
    # enabled so this path cannot fall back to fetching weights from the Hub.
    model = nemo_asr.models.ASRModel.restore_from(str(model_file), map_location="cpu")
    if torch.cuda.is_available():
        model = model.to("cuda")
        if engine._bfloat16_available():
            model = model.to(dtype=torch.bfloat16)
            precision = "bfloat16"
        else:
            precision = "float32"
        gpu_name = torch.cuda.get_device_name(0)
        memory_gb = torch.cuda.get_device_properties(0).total_memory / (1024**3)
        device = f"{gpu_name} ({memory_gb:.0f} GB, {precision})"
    else:
        device = "CPU"
        log.warning("CUDA is not available. Transcription will use the CPU.")
    model.eval()
    log.info("Loaded %s from the shared cache on %s", MODEL_ID, device)
    return model, device


def _transcribe_pcm(engine: Any, model: Any, pcm: bytes) -> str:
    """Transcribe one segment with the existing engine's Parakeet helpers.

    The engine currently accepts WAV paths, so each segment is written to its
    designated temporary folder and deleted immediately after inference.
    """
    paths = engine.prepare_storage()
    work = paths.temp / f"echonote-{uuid.uuid4().hex}"
    work.mkdir(parents=True, exist_ok=False)
    samples = array("h")
    samples.frombytes(pcm)
    if sys.byteorder != "little":
        samples.byteswap()
    try:
        segments, _words = engine._transcribe_piece(model, samples, 0.0, work, depth=0)
        return " ".join(part.text.strip() for part in segments if part.text.strip()).strip()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _count_words(text: str) -> int:
    """Count recognized word-like tokens without retaining transcript text."""
    return len(re.findall(r"\b[\w']+\b", text, flags=re.UNICODE))


def _create_transcript_file(session_id: str) -> Path:
    created_at = datetime.now().astimezone()
    safe_session_id = re.sub(r"[^A-Za-z0-9_-]+", "_", session_id).strip("_")[:48] or "session"
    filename_time = created_at.strftime("%Y-%m-%d_%H-%M-%S_%f")
    transcript_path = TRANSCRIPT_DIR / f"EchoNote_{filename_time}_{safe_session_id}.txt"
    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    with transcript_path.open("x", encoding="utf-8", newline="\n") as transcript:
        transcript.write("EchoNote transcript\n")
        transcript.write(f"Date and time created: {created_at.strftime('%Y-%m-%d %H:%M:%S %Z (%z)')}\n\n")
    return transcript_path


def _append_transcript_chunk(transcript_path: Path, text: str) -> None:
    cleaned = text.strip()
    if cleaned:
        with transcript_path.open("a", encoding="utf-8", newline="\n") as transcript:
            transcript.write(cleaned + "\n")


def _initialize_metrics_store() -> None:
    METRICS_DB.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(METRICS_DB) as connection:
        connection.execute(
            """CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY,
                started_at_utc TEXT NOT NULL,
                duration_seconds REAL NOT NULL,
                word_count INTEGER NOT NULL,
                audio_frame_count INTEGER NOT NULL,
                audio_seconds REAL NOT NULL,
                inference_segments INTEGER NOT NULL,
                completed_segments INTEGER NOT NULL,
                failed_segments INTEGER NOT NULL,
                avg_processing_seconds REAL,
                status TEXT NOT NULL
            )"""
        )
        columns = {row[1] for row in connection.execute("PRAGMA table_info(sessions)")}
        if "completed_segments" not in columns:
            connection.execute(
                "ALTER TABLE sessions ADD COLUMN completed_segments INTEGER NOT NULL DEFAULT 0"
            )


def _store_session_metrics(metrics: dict[str, Any]) -> tuple[int, float]:
    with sqlite3.connect(METRICS_DB, timeout=10) as connection:
        connection.execute(
            """INSERT INTO sessions (
                started_at_utc, duration_seconds, word_count, audio_frame_count,
                audio_seconds, inference_segments, completed_segments, failed_segments,
                avg_processing_seconds, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                metrics["started_at_utc"], metrics["duration_seconds"], metrics["word_count"],
                metrics["audio_frame_count"], metrics["audio_seconds"],
                metrics["inference_segments"], metrics["completed_segments"], metrics["failed_segments"],
                metrics["avg_processing_seconds"], metrics["status"],
            ),
        )
        count, average = connection.execute(
            "SELECT COUNT(*), COALESCE(AVG(word_count), 0) FROM sessions WHERE status = 'complete'"
        ).fetchone()
        return int(count), float(average)


async def _read_exact(reader: asyncio.StreamReader, size: int) -> bytes:
    try:
        return await reader.readexactly(size)
    except asyncio.IncompleteReadError as exc:
        raise ProtocolError("connection_closed", "The client disconnected.", 1001) from exc


async def _read_http_headers(reader: asyncio.StreamReader) -> bytes:
    try:
        raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=10)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, TimeoutError) as exc:
        raise ProtocolError("bad_handshake", "Could not read the WebSocket handshake.", 1002) from exc
    if len(raw) > 16 * 1024:
        raise ProtocolError("bad_handshake", "Handshake headers are too large.", 1002)
    return raw


async def _websocket_handshake(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    raw = await _read_http_headers(reader)
    try:
        lines = raw.decode("latin-1").split("\r\n")
        request = lines[0].split()
        headers = {
            name.strip().lower(): value.strip()
            for line in lines[1:]
            if ":" in line
            for name, value in [line.split(":", 1)]
        }
    except (UnicodeError, ValueError, IndexError) as exc:
        raise ProtocolError("bad_handshake", "Malformed WebSocket handshake.", 1002) from exc
    if len(request) != 3 or request[0] != "GET" or request[2] != "HTTP/1.1":
        raise ProtocolError("bad_handshake", "Expected an HTTP/1.1 WebSocket upgrade.", 1002)
    if headers.get("upgrade", "").lower() != "websocket" or "upgrade" not in headers.get("connection", "").lower():
        raise ProtocolError("bad_handshake", "Missing WebSocket upgrade headers.", 1002)
    key = headers.get("sec-websocket-key")
    if not key or headers.get("sec-websocket-version") != "13":
        raise ProtocolError("bad_handshake", "Unsupported WebSocket handshake.", 1002)
    accept = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    ).decode("ascii")
    writer.write(
        ("HTTP/1.1 101 Switching Protocols\r\n"
         "Upgrade: websocket\r\nConnection: Upgrade\r\n"
         f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode("ascii")
    )
    await writer.drain()


async def _read_frame(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    first, second = await _read_exact(reader, 2)
    final = bool(first & 0x80)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if not final or not masked:
        raise ProtocolError("bad_frame", "Frames must be final and client-masked.", 1002)
    if length == 126:
        length = struct.unpack("!H", await _read_exact(reader, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", await _read_exact(reader, 8))[0]
    if length > MAX_MESSAGE_BYTES:
        raise ProtocolError("message_too_large", "The client frame exceeds the size limit.", 1009)
    if opcode >= 0x8 and length > 125:
        raise ProtocolError("bad_frame", "Control frames cannot exceed 125 bytes.", 1002)
    mask = await _read_exact(reader, 4)
    payload = bytearray(await _read_exact(reader, length))
    for index in range(length):
        payload[index] ^= mask[index & 3]
    return opcode, bytes(payload)


async def _send_frame(writer: asyncio.StreamWriter, opcode: int, payload: bytes) -> None:
    length = len(payload)
    if length < 126:
        header = bytes((0x80 | opcode, length))
    elif length <= 0xFFFF:
        header = bytes((0x80 | opcode, 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x80 | opcode, 127)) + struct.pack("!Q", length)
    writer.write(header + payload)
    await writer.drain()


async def _send_json(writer: asyncio.StreamWriter, message: dict[str, Any]) -> None:
    await _send_frame(writer, 0x1, json.dumps(message, separators=(",", ":")).encode("utf-8"))


async def _receive_json(reader: asyncio.StreamReader) -> dict[str, Any]:
    while True:
        opcode, payload = await _read_frame(reader)
        if opcode == 0x9:
            return {"_ping": payload}
        if opcode == 0x8:
            raise ProtocolError("client_closed", "The client closed the connection.", 1000)
        if opcode != 0x1:
            raise ProtocolError("expected_control", "Expected a JSON control message.", 1003)
        try:
            value = json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise ProtocolError("bad_json", "Control message must be valid JSON.") from exc
        if not isinstance(value, dict):
            raise ProtocolError("bad_json", "Control message must be a JSON object.")
        return value


async def _serve_session(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    engine: Any,
    model: Any,
    first: dict[str, Any],
) -> None:
    if first.get("type") != "start":
        raise ProtocolError("expected_start", "The first message must be start.")
    if first.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError("version_mismatch", "Unsupported EchoNote protocol version.")
    session_id = first.get("session_id")
    if not isinstance(session_id, str) or not 1 <= len(session_id) <= 128:
        raise ProtocolError("bad_session", "A session_id of 1 to 128 characters is required.")
    if (first.get("sample_rate") != SAMPLE_RATE or first.get("channels") != CHANNELS
            or first.get("sample_format") != "s16le"):
        raise ProtocolError("unsupported_audio", "Audio must be mono 16 kHz signed 16-bit little-endian PCM.")
    segment_seconds = first.get("segment_seconds", DEFAULT_SEGMENT_SECONDS)
    if (isinstance(segment_seconds, bool) or not isinstance(segment_seconds, int)
            or segment_seconds not in ALLOWED_SEGMENT_SECONDS):
        raise ProtocolError("bad_segment_duration", "Segment duration must be 5, 10, 15, or 30 seconds.")
    vad_enabled = first.get("vad_enabled", False)
    if not isinstance(vad_enabled, bool):
        raise ProtocolError("bad_vad_setting", "vad_enabled must be a boolean.")
    segment_bytes = SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH * segment_seconds

    try:
        transcript_path = _create_transcript_file(session_id)
    except OSError as exc:
        log.exception("transcript_create_failed session=%s", session_id)
        raise ProtocolError("transcript_storage_error", "The server could not create a transcript file.", 1011) from exc
    log.info("session_transcript_created session=%s path=%s", session_id, transcript_path)

    started_at_utc = datetime.now(timezone.utc).isoformat(timespec="seconds")
    started_monotonic = time.monotonic()
    session_word_count = 0
    audio_frame_count = 0
    audio_byte_count = 0
    processing_times: list[float] = []
    session_status = "interrupted"

    await _send_json(writer, {
        "type": "started", "protocol_version": PROTOCOL_VERSION,
        "session_id": session_id, "sample_rate": SAMPLE_RATE,
        "channels": CHANNELS, "sample_format": "s16le",
        "segment_seconds": segment_seconds, "vad_enabled": vad_enabled,
    })
    work_queue: asyncio.Queue[AudioSegment | None] = asyncio.Queue(maxsize=TRANSCRIPTION_QUEUE_SIZE)
    outgoing: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
    pending = bytearray()
    next_segment_index = 0
    failed_segments: list[int] = []

    async def transcriber() -> None:
        nonlocal session_word_count
        while True:
            segment = await work_queue.get()
            if segment is None:
                return
            started = time.monotonic()
            try:
                text = await asyncio.to_thread(_transcribe_pcm, engine, model, segment.pcm)
                elapsed = time.monotonic() - started
                processing_times.append(elapsed)
                try:
                    _append_transcript_chunk(transcript_path, text)
                except OSError:
                    log.exception("transcript_append_failed session=%s index=%d", session_id, segment.index)
                session_word_count += _count_words(text)
                await outgoing.put({
                    "type": "transcript_segment", "session_id": session_id,
                    "segment_index": segment.index, "text": text,
                })
                log.info(
                    "segment_complete session=%s index=%d elapsed=%.2fs words_so_far=%d",
                    session_id, segment.index, elapsed, session_word_count,
                )
            except Exception as exc:
                processing_times.append(time.monotonic() - started)
                log.exception("transcription_failed session=%s index=%d", session_id, segment.index)
                failed_segments.append(segment.index)
                await outgoing.put({
                    "type": "error", "session_id": session_id,
                    "code": "transcription_failed", "message": "A segment could not be transcribed.",
                    "segment_index": segment.index,
                })

    worker = asyncio.create_task(transcriber(), name="echonote-transcriber")

    async def send_results() -> None:
        while True:
            message = await outgoing.get()
            if message is None:
                return
            await _send_json(writer, message)

    sender = asyncio.create_task(send_results(), name="echonote-result-sender")
    try:
        while True:
            try:
                opcode, payload = await asyncio.wait_for(
                    _read_frame(reader), timeout=WEBSOCKET_IDLE_TIMEOUT_SECONDS
                )
            except TimeoutError as exc:
                log.info(
                    "session_idle_timeout session=%s seconds=%d",
                    session_id, WEBSOCKET_IDLE_TIMEOUT_SECONDS,
                )
                raise ProtocolError(
                    "idle_timeout",
                    f"No WebSocket message received for {WEBSOCKET_IDLE_TIMEOUT_SECONDS} seconds. Reconnect and try again.",
                    1013,
                ) from exc
            if opcode == 0x9:
                await _send_frame(writer, 0xA, payload)
                continue
            if opcode == 0x8:
                raise ProtocolError("client_closed", "The client closed before Stop.", 1001)
            if opcode == 0x2:
                if not payload or len(payload) % SAMPLE_WIDTH:
                    raise ProtocolError("bad_audio_frame", "PCM frames must contain complete 16-bit samples.", 1003)
                audio_frame_count += 1
                audio_byte_count += len(payload)
                pending.extend(payload)
                while len(pending) >= segment_bytes:
                    chunk = bytes(pending[:segment_bytes])
                    del pending[:segment_bytes]
                    await work_queue.put(AudioSegment(next_segment_index, chunk))
                    next_segment_index += 1
                continue
            if opcode != 0x1:
                raise ProtocolError("unexpected_frame", "Only binary PCM frames and JSON controls are accepted.", 1003)
            try:
                control = json.loads(payload.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as exc:
                raise ProtocolError("bad_json", "Control message must be valid JSON.") from exc
            if not isinstance(control, dict):
                raise ProtocolError("unexpected_control", "Control messages must be JSON objects.")
            if control.get("session_id") != session_id:
                raise ProtocolError("bad_session", "Control session_id does not match start.")
            if control.get("type") == "keepalive":
                continue
            if control.get("type") == "segment_end":
                if pending:
                    await work_queue.put(AudioSegment(next_segment_index, bytes(pending)))
                    pending.clear()
                    next_segment_index += 1
                continue
            if control.get("type") != "stop":
                raise ProtocolError("unexpected_control", "Only keepalive, segment_end, and stop are valid after start.")
            if pending:
                await work_queue.put(AudioSegment(next_segment_index, bytes(pending)))
                pending.clear()
                next_segment_index += 1
            break

        await work_queue.put(None)
        await worker
        await outgoing.put({
            "type": "final", "session_id": session_id,
            "last_segment_index": next_segment_index - 1,
            "status": "partial" if failed_segments else "complete",
            "failed_segment_indices": failed_segments,
        })
        session_status = "partial" if failed_segments else "complete"
        await outgoing.put(None)
        await sender
    finally:
        if not worker.done():
            worker.cancel()
        if not sender.done():
            sender.cancel()
        await asyncio.gather(worker, sender, return_exceptions=True)
        duration_seconds = time.monotonic() - started_monotonic
        avg_processing_seconds = (
            sum(processing_times) / len(processing_times) if processing_times else None
        )
        metrics = {
            "started_at_utc": started_at_utc,
            "duration_seconds": duration_seconds,
            "word_count": session_word_count,
            "audio_frame_count": audio_frame_count,
            "audio_seconds": audio_byte_count / (SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH),
            "inference_segments": len(processing_times),
            "completed_segments": len(processing_times) - len(failed_segments),
            "failed_segments": len(failed_segments),
            "avg_processing_seconds": avg_processing_seconds,
            "status": session_status,
        }
        try:
            historical_sessions, historical_average_words = await asyncio.to_thread(
                _store_session_metrics, metrics
            )
            log.info(
                "session_metrics started_at_utc=%s duration_seconds=%.2f words=%d "
                "audio_frames=%d audio_seconds=%.2f inference_segments=%d completed_segments=%d "
                "failed_segments=%d avg_processing_seconds=%s historical_complete_sessions=%d "
                "historical_average_words=%.1f status=%s",
                started_at_utc, duration_seconds, session_word_count, audio_frame_count,
                metrics["audio_seconds"], len(processing_times), metrics["completed_segments"],
                len(failed_segments),
                f"{avg_processing_seconds:.2f}" if avg_processing_seconds is not None else "n/a",
                historical_sessions, historical_average_words, session_status,
            )
        except Exception:
            log.exception("session_metrics_persist_failed")


async def _handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    engine: Any,
    model: Any,
 ) -> None:
    peer = writer.get_extra_info("peername")
    claimed_session = False
    try:
        await _websocket_handshake(reader, writer)
        first = await _receive_json(reader)
        while "_ping" in first:
            await _send_frame(writer, 0xA, first["_ping"])
            first = await _receive_json(reader)
        if first.get("type") == "health":
            await _send_json(writer, {"type": "health", "status": "ready"})
            return
        if ACTIVE_SESSION.locked():
            raise ProtocolError("server_busy", "Another recording session is already active.", 1013)
        await ACTIVE_SESSION.acquire()
        claimed_session = True
        await _serve_session(reader, writer, engine, model, first)
    except ProtocolError as exc:
        log.info("session_rejected peer=%s code=%s", peer, exc.code)
        try:
            await _send_json(writer, {"type": "error", "code": exc.code, "message": exc.message})
            await _send_frame(writer, 0x8, struct.pack("!H", exc.close_code))
        except OSError:
            pass
    except OSError as exc:
        log.info("client_disconnected peer=%s error=%s", peer, exc)
    except Exception:
        log.exception("session_failed peer=%s", peer)
        try:
            await _send_json(writer, {"type": "error", "code": "server_error", "message": "The server could not finish this session."})
        except OSError:
            pass
    finally:
        if claimed_session:
            ACTIVE_SESSION.release()
        writer.close()
        try:
            await writer.wait_closed()
        except OSError as exc:
            log.debug("websocket_close_failed peer=%s error=%s", peer, exc)


async def run_server() -> None:
    engine = _load_lecture_engine()
    log.info("Loading the existing cached Parakeet model; downloads are disabled.")
    model, device = await asyncio.to_thread(_load_cached_model, engine)
    log.info("Parakeet ready device=%s", device)
    await asyncio.to_thread(_initialize_metrics_store)

    server = await asyncio.start_server(
        lambda reader, writer: _handle_client(reader, writer, engine, model),
        host=HOST,
        port=PORT,
        limit=MAX_MESSAGE_BYTES + 1024,
    )
    addresses = ", ".join(str(sock.getsockname()) for sock in (server.sockets or []))
    log.info("EchoNote server ready address=%s protocol=%d", addresses, PROTOCOL_VERSION)
    async with server:
        await server.serve_forever()


def main() -> None:
    try:
        asyncio.run(run_server())
    except KeyboardInterrupt:
        log.info("EchoNote server stopped")


if __name__ == "__main__":
    main()
