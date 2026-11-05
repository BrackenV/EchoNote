# Running the EchoNote server

The server uses the Python environment and Parakeet cache already used by Lecture Transcriber. It does not install Python packages or download model weights. Its first startup can still take time while NeMo loads the model into memory.

## Start it on the PC

Open PowerShell in this EchoNote folder. Set the bind address to the PC's Tailscale IPv4 address (find it with `tailscale ip -4`), create a temporary private session token, then launch with the existing Lecture Transcriber Python executable:

```powershell
$env:ECHONOTE_HOST = '<PC Tailscale IPv4 address>'
$env:ECHONOTE_TOKEN = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
& 'D:\LectureTranscriber\venv\Scripts\python.exe' '.\server.py'
```

The token must be at least 24 characters. Keep it private and provide the same value to the iPhone client. The server defaults to `127.0.0.1` if no host is selected, so it will not be reachable from the phone by default. It listens on port `8765`; set `ECHONOTE_PORT` to change it.

The server requires one active session, protocol version `1`, mono 16 kHz signed 16-bit little-endian PCM, and a JSON `start` control message containing `session_id`, `sample_rate`, `channels`, `sample_format`, and `token`. Send each audio chunk as a WebSocket binary message. Send JSON `{"type":"stop","session_id":"..."}` to flush the last partial segment and receive the final status.

The server is plain WebSocket and should be used only over the private Tailscale network; do not expose its port publicly. It logs session IDs and timing/error metadata, not audio or transcript text. The existing Lecture Transcriber helper creates and removes a temporary WAV for each inference segment in `D:\LectureTranscriber\temp`.

## Current limitations

- The iPhone message format has not yet been implemented or integration-tested against this server.
- WSS certificate handling, reconnects, silence-aware segment boundaries, overlap reconciliation, and client-side sequence metadata are future protocol decisions.
- A segment failure is reported and included in `final.failed_segment_indices`; the server continues processing later accepted segments.
