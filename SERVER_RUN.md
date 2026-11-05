# Running the EchoNote server

The server uses the Python environment and Parakeet cache already used by Lecture Transcriber. It does not install Python packages or download model weights. Its first startup can still take time while NeMo loads the model into memory.

## Start it on the PC

Open PowerShell in this EchoNote folder and run the launcher:

```powershell
.\Start-EchoNoteServer.ps1
```

The launcher finds the current Tailscale address and checks the Python environment, Lecture Transcriber source, and local model cache before starting. This avoids retrying startup with a stale path. The model still needs to load into GPU memory after a full server restart; keep the server running between recording sessions to avoid that wait.

The server listens on port `8765`; set `ECHONOTE_PORT` to change it. The server defaults to `127.0.0.1` if no host is selected, so it will not be reachable from the phone by default.

The app connects outward to the PC, so the phone address is not entered in the app or required by the server. The app checks the PC with a `health` WebSocket message; this confirms that the PC is reachable over Tailscale, without starting a recording session.

The server requires one active session, protocol version `1`, mono 16 kHz signed 16-bit little-endian PCM, and a JSON `start` control message containing `session_id`, `sample_rate`, `channels`, and `sample_format`. Send each audio chunk as a WebSocket binary message. Send JSON `{"type":"stop","session_id":"..."}` to flush the last partial segment and receive the final status.

The server is plain WebSocket and should be used only over the private Tailscale network; do not expose its port publicly. It logs timing and count metrics, not audio or transcript text. The existing Lecture Transcriber helper creates and removes a temporary WAV for each inference segment in `D:\LectureTranscriber\temp`.

## Local session metrics

The server records one metadata row for each valid recording session in `.echonote-smoke-runtime\logs\session_metrics.sqlite3`. Metrics include the UTC session start time, connection duration, recognized word count, number and duration of received audio frames, inference chunk counts, failed chunks, and average processing time per inference chunk. The server log also reports cumulative recognized words as chunks finish and the average word count across completed sessions. Word counts reflect recognized text and can differ from the words actually spoken.

The database stays on this PC and is ignored by Git. It does not contain audio or transcript text. Remove the database file to clear the collected session metrics.

## Current limitations

- The iPhone message format has not yet been implemented or integration-tested against this server.
- WSS certificate handling, reconnects, silence-aware segment boundaries, overlap reconciliation, and client-side sequence metadata are future protocol decisions.
- A segment failure is reported and included in `final.failed_segment_indices`; the server continues processing later accepted segments.
