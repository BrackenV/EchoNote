# EchoNote Server Design Brief

**Version:** 1.0  
**Status:** Proposed server-first implementation  
**Related brief:** `EchoNote_Technical_Design_v1.docx`

## Goal

Build a local Python server that accepts one live iPhone audio session over a WebSocket, feeds speech to the already installed Parakeet model, and returns transcript segments in order. Audio intake must continue while transcription runs. Do not retain recordings. By explicit product decision, save each session's transcribed text in a separate local text file.

## Existing Parakeet installation

Reuse the existing Lecture Transcriber installation. Do not download the model again or run its setup installer for EchoNote.

- Lecture Transcriber project: `C:\Users\ellih\Desktop\Personal\University Work Y1\Lecture Transcriber`
- Model storage root recorded by that project: `C:\LectureTranscriberModel`
- Model identifier: `nvidia/parakeet-tdt-0.6b-v2`
- Existing Python environment/runtime pointer: `D:\LectureTranscriber`
- Model cache subfolders prepared by its `storage.py`: `huggingface`, `torch`, `nemo`, and `cache` under the model storage root.
- Shared location is controlled by Lecture Transcriber's `model_storage_path.txt`; EchoNote reads the same pointer rather than keeping an independent cache path.

The project uses NeMo `ASRModel.from_pretrained` with the identifier above. EchoNote imports the existing `transcribe_engine.py`, restores the `.nemo` artifact directly from the shared local Hugging Face snapshot with NeMo `restore_from`, and calls the engine's single-piece inference helper. Direct restore avoids a Hub metadata lookup or model download during server startup. The helper writes a temporary WAV under the Lecture Transcriber runtime's temp directory and deletes it after inference; EchoNote does not write persistent audio or transcript files. Do not copy the model files.

## MVP responsibilities

1. Accept a WebSocket connection and validate protocol version, session identifier, and a `start` message describing the audio format.
2. Validate that audio is mono PCM, signed 16-bit little-endian, at a negotiated sample rate (target 16 kHz); reject unsupported formats with a clear error.
3. Receive bounded binary frames continuously while segmentation and inference work proceed independently.
4. Assemble incoming frames into configurable 10-second inference segments. This lowers inference-call frequency but delays interim transcript updates; Stop still flushes any shorter final segment. Boundary-overlap handling remains a later improvement.
5. Submit complete segments to a bounded queue. Run one Parakeet inference worker initially, off the asyncio event loop, because safe concurrent model inference is not established.
6. Return transcript results with session ID and monotonically increasing segment index. The client can then render them in order; the server should emit in order as a simpler default.
7. On `stop`, stop accepting audio, flush the partial segment, finish queued inference, send a `final` message, and close cleanly.
8. Report connection, format, overload, inference, and shutdown failures without silently losing audio. Bound queues and define backpressure (pause/limit intake or fail the session clearly).

## Suggested components

- **FastAPI WebSocket endpoint:** session lifecycle, protocol validation, sends and receives.
- **Session state:** session ID, negotiated format, receive sequence/timing, next segment index, and shutdown state.
- **Audio receiver:** promptly reads WebSocket frames and places PCM into a bounded input queue.
- **Segmenter:** converts frames to fixed-duration audio windows, retaining overlap as configured.
- **Transcription worker:** a single worker thread/process calls the existing Parakeet adapter; it never blocks the event loop.
- **Result sender:** serializes JSON results and final/error events for the active session.
- **Metrics/logging:** durations, queue depth, frame counts, and error categories only; never log audio or transcript text.

## Proposed wire messages

Control messages are JSON. Audio is binary PCM. Exact framing/sequence metadata needs to be settled with the iPhone client before implementation.

- Client `start`: protocol version, session ID, sample rate, channel count, sample format.
- Server `started`: accepted format and session ID.
- Client binary frame: PCM bytes; sequence number and capture timestamp should be included in an agreed header or envelope.
- Client `stop`: end of audio for this session.
- Server `transcript_segment`: session ID, segment index, text, optional audio time range.
- Server `final`: session ID, last segment index, completion status.
- Server `error`: stable error code and user-readable message.
- Optional `ping` / `pong`: connection health.
- `health` with the session token: an authenticated reachability check that returns `{"type":"health","status":"ready"}` without acquiring the single recording-session lock.

Reject duplicate starts, malformed frames, oversized messages, unexpected control messages, and frames received after stop. Do not allow one client's session to consume unbounded memory or queue capacity.

## Session and concurrency rules

- MVP supports one active recording session at a time.
- Socket receive must remain responsive during model inference.
- Model loads once at server startup and is reused. Startup should expose a clear ready/failed state; do not accept a recording until the model is ready.
- Keep audio in memory. Append each completed transcript chunk to that session's local text file. The reused Parakeet helper briefly writes each current segment as a WAV in the existing runtime temp directory, then deletes it after inference.
- Assign segment indices at segmentation time, not completion time.
- If inference completes out of order in a future implementation, buffer results by index and emit only the next expected index.
- On disconnect, retain transcript chunks already written to the session file, then release audio buffers and cancel or drain pending work according to the session policy.

## Security and privacy

- Bind only to the required private interface; no public unauthenticated endpoint.
- Require an application-level session credential or another explicit client verification mechanism in addition to Tailscale membership.
- Use WSS if required by the iOS networking configuration; document the certificate/trust approach.
- Enforce message-size limits, format limits, one-session policy, and queue limits.
- Do not log speech, transcripts, credentials, or raw frames. Keep diagnostics to timings, counts, and error codes.
- PC sleep, server availability, and tailnet connection failures must result in a clear connection error.

## Failure handling

| Condition | Required behavior |
|---|---|
| Model/cache unavailable | Fail startup clearly; never silently trigger a second model download |
| Bad start metadata or audio format | Reject with actionable protocol error |
| Client disconnects | Stop intake, release buffers, apply the documented pending-work policy |
| No inbound WebSocket message for 10 seconds after start | Send an `idle_timeout` error, close with code 1013, and release the active-session slot so the client can start a new session |
| Queue reaches limit | Apply backpressure or terminate clearly; never silently drop audio |
| Parakeet inference fails | Report segment/session failure and keep already returned text available |
| Stop with partial audio | Transcribe the remainder before `final` |
| Oversized/malformed frame | Reject and close or report according to protocol policy |

## Build sequence

1. Inspect the Lecture Transcriber engine and storage setup; identify the smallest safe import boundary and runtime dependencies.
2. Prove EchoNote can load the existing cached Parakeet model without downloading model files.
3. Implement a local WebSocket server and simulated client for a short PCM sample.
4. Add independent receive, segmentation, bounded queues, single inference worker, ordered results, and stop/flush.
5. Measure capture-to-text latency, real-time factor, queue growth, and memory during a 60-second stream.
6. Add Tailscale/client authentication and agree the iPhone protocol before connecting the phone.

## Acceptance criteria

- Server starts using the existing cached model, without downloading model weights or reinstalling the model.
- A simulated client can stream 60 seconds of 16 kHz mono PCM while inference runs; audio reception does not block on inference.
- Every accepted segment produces one correctly indexed result, in order, with readable text.
- Stop flushes the last partial segment and sends `final` only after all accepted audio is processed.
- Queue limits and overload behavior are observable and never silently discard audio.
- No audio or transcript text is retained in persistent storage or logs; temporary inference WAVs are deleted after each call.
- Offline model, malformed audio, disconnect, and inference failure have clear outcomes.

## Decisions still needed

- Whether to call the Lecture Transcriber engine directly or extract a small shared adapter.
- Exact audio frame header and sequence/timestamp encoding.
- Boundary overlap length and duplicate-text reconciliation approach.
- Authentication token provisioning and WSS certificate approach.
- Whether disconnect drains already accepted audio or cancels it.
- Whether error on a segment ends the session or permits later segments to continue.
