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
import shutil
import struct
import sys
import time
import uuid
from array import array
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
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
SEGMENT_SECONDS = 4
SEGMENT_BYTES = SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH * SEGMENT_SECONDS
MAX_FRAME_BYTES = 256 * 1024
MAX_MESSAGE_BYTES = MAX_FRAME_BYTES
TRANSCRIPTION_QUEUE_SIZE = 3
PROTOCOL_VERSION = 1

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

    await _send_json(writer, {
        "type": "started", "protocol_version": PROTOCOL_VERSION,
        "session_id": session_id, "sample_rate": SAMPLE_RATE,
        "channels": CHANNELS, "sample_format": "s16le",
    })
    work_queue: asyncio.Queue[AudioSegment | None] = asyncio.Queue(maxsize=TRANSCRIPTION_QUEUE_SIZE)
    outgoing: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
    pending = bytearray()
    next_segment_index = 0
    failed_segments: list[int] = []

    async def transcriber() -> None:
        while True:
            segment = await work_queue.get()
            if segment is None:
                return
            started = time.monotonic()
            try:
                text = await asyncio.to_thread(_transcribe_pcm, engine, model, segment.pcm)
                await outgoing.put({
                    "type": "transcript_segment", "session_id": session_id,
                    "segment_index": segment.index, "text": text,
                })
                log.info("segment_complete session=%s index=%d elapsed=%.2fs", session_id, segment.index, time.monotonic() - started)
            except Exception as exc:
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
            opcode, payload = await _read_frame(reader)
            if opcode == 0x9:
                await _send_frame(writer, 0xA, payload)
                continue
            if opcode == 0x8:
                raise ProtocolError("client_closed", "The client closed before Stop.", 1001)
            if opcode == 0x2:
                if not payload or len(payload) % SAMPLE_WIDTH:
                    raise ProtocolError("bad_audio_frame", "PCM frames must contain complete 16-bit samples.", 1003)
                pending.extend(payload)
                while len(pending) >= SEGMENT_BYTES:
                    chunk = bytes(pending[:SEGMENT_BYTES])
                    del pending[:SEGMENT_BYTES]
                    await work_queue.put(AudioSegment(next_segment_index, chunk))
                    next_segment_index += 1
                continue
            if opcode != 0x1:
                raise ProtocolError("unexpected_frame", "Only binary PCM frames and JSON controls are accepted.", 1003)
            try:
                control = json.loads(payload.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as exc:
                raise ProtocolError("bad_json", "Control message must be valid JSON.") from exc
            if not isinstance(control, dict) or control.get("type") != "stop":
                raise ProtocolError("unexpected_control", "Only stop is valid after start.")
            if control.get("session_id") != session_id:
                raise ProtocolError("bad_session", "Stop session_id does not match start.")
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
        await outgoing.put(None)
        await sender
    finally:
        if not worker.done():
            worker.cancel()
        if not sender.done():
            sender.cancel()
        await asyncio.gather(worker, sender, return_exceptions=True)


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
        except (ConnectionError, BrokenPipeError):
            pass
    except (ConnectionError, BrokenPipeError):
        log.info("client_disconnected peer=%s", peer)
    except Exception:
        log.exception("session_failed peer=%s", peer)
        try:
            await _send_json(writer, {"type": "error", "code": "server_error", "message": "The server could not finish this session."})
        except (ConnectionError, BrokenPipeError):
            pass
    finally:
        if claimed_session:
            ACTIVE_SESSION.release()
        writer.close()
        try:
            await writer.wait_closed()
        except ConnectionError:
            pass


async def run_server() -> None:
    engine = _load_lecture_engine()
    log.info("Loading the existing cached Parakeet model; downloads are disabled.")
    model, device = await asyncio.to_thread(_load_cached_model, engine)
    log.info("Parakeet ready device=%s", device)

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
