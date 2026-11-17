# Running the EchoNote server

The server uses the Python environment and Parakeet cache already used by Lecture Transcriber. It does not install Python packages or download model weights. Its first startup can still take time while NeMo loads the model into memory.

NeMo and OneLogger console chatter is hidden by default. The launcher prints
each recognized segment as one concise line; recognized speech is therefore
visible in the terminal and should be treated as private. Set
`$env:ECHONOTE_LOG_TRANSCRIPT_TEXT = "0"` before launching to hide it. For
model troubleshooting, set `$env:ECHONOTE_VERBOSE_FRAMEWORK_LOGS = "1"` before
launching to show NeMo's framework messages.

## Start it on the PC

Open PowerShell in this EchoNote folder and run the launcher:

```powershell
.\Start-EchoNoteServer.ps1
```

The launcher finds the **PC's** current Tailscale IPv4 address, binds the server to that address, and checks the Python environment, Lecture Transcriber source, and local model cache before starting. It prints the address and port to use in a client, for example `100.x.x.x:8765`. This avoids retrying startup with a stale path. The model still needs to load into GPU memory after a full server restart; keep the server running between recording sessions to avoid that wait.

The server listens on port `8765`; set `ECHONOTE_PORT` to change it. The server defaults to `127.0.0.1` if no host is selected, so it will not be reachable from clients by default.

The Mac and iPhone connect outward to the PC's printed Tailscale address. The PC does not connect to either client, so their Tailscale addresses do not need to be entered in the server or opened for inbound connections. Transcript segments are returned over the same WebSocket connection that carries audio; there is no separate callback connection. The iPhone checks the PC with a `health` WebSocket message; this confirms that the PC is reachable over Tailscale, without starting a recording session. In the Mac recorder, enter the PC address shown by the launcher in **Send audio to PC for transcription**.

The server requires one active session, protocol version `1`, mono 16 kHz signed 16-bit little-endian PCM, and a JSON `start` control message containing `session_id`, `sample_rate`, `channels`, `sample_format`, `segment_seconds`, and `vad_enabled`. Send each audio chunk as a WebSocket binary message. With VAD enabled, use `segment_end` after a speech pause and `keepalive` while quiet. Send JSON `{"type":"stop","session_id":"..."}` to flush the last partial segment and receive the final status.

Without voice activity detection, audio is grouped into the selected 5, 10, 15, or 30-second transcription segments. With voice activity detection enabled, the iPhone sends voiced audio with a short pre-roll and trailing tail, and closes a segment after a pause; long speech is still split into 10-second maximum segments. Stop flushes and transcribes any remaining audio immediately.

After a recording starts, the server closes the WebSocket if it receives no inbound WebSocket message for 10 seconds. It sends an `idle_timeout` error and closes with code `1013`, then releases the single-session slot. The iPhone client stops capture, preserves text already received, and returns to Start recording so a fresh session can reconnect.

The server is plain WebSocket and should be used only over the private Tailscale network; do not expose its port publicly. It can print recognized transcript text in the console. The existing Lecture Transcriber helper creates and removes a temporary WAV for each inference segment in `D:\LectureTranscriber\temp`.

## Local session metrics

The server records one metadata row for each valid recording session in `.echonote-runtime\logs\session_metrics.sqlite3`. Metrics include the UTC session start time, connection duration, recognized word count, number and duration of received audio frames, inference chunk counts, failed chunks, and average processing time per inference chunk. The server log also reports cumulative recognized words as chunks finish and the average word count across completed sessions. Word counts reflect recognized text and can differ from the words actually spoken.

The database stays on this PC and is ignored by Git. It contains no transcript text. Remove the database file to clear the collected session metrics.

## Transcript files

The server creates a new UTF-8 `.txt` file for each accepted recording in `.echonote-runtime\transcripts`, named `EchoNote Transcript - YYYY-MM-DD HH.MM.SS.txt` using local time. The file starts with its local creation date and time, then receives each completed transcript chunk. Files stay on this PC and are ignored by Git. If a session disconnects early, the file retains the chunks completed up to that point.

## Current limitations

- WSS certificate handling, reconnects, overlap reconciliation, and client-side sequence metadata are future protocol decisions.
- A segment failure is reported and included in `final.failed_segment_indices`; the server continues processing later accepted segments.
