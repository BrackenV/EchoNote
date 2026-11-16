# EchoNote

EchoNote is a SwiftUI iPhone app for live lecture transcription. It records from the iPhone microphone and streams audio to a local server running on your Windows PC. The server transcribes speech with the NVIDIA Parakeet model already used by Lecture Transcriber, then sends transcript segments back to the phone as they are recognized.

EchoNote is designed for use over a private Tailscale network. The PC must be awake, the server must be running, and the iPhone must be signed into the same tailnet.

## Features

- Live microphone recording with transcript segments displayed in the app
- Local transcription on the PC using the existing cached `nvidia/parakeet-tdt-0.6b-v2` model
- Voice activity detection (VAD) that sends speech with a short pre-roll and closes segments after pauses
- Optional fixed-duration transcription segments (5, 10, 15, or 30 seconds)
- Copy and clear transcript controls
- A server status indicator and periodic health checks
- Per-session UTF-8 transcript files and aggregate session metadata saved on the PC

## How it works

```text
iPhone microphone
    -> 16 kHz mono, signed 16-bit PCM over WebSocket
    -> Windows PC running EchoNote server
    -> existing Lecture Transcriber Parakeet model
    -> transcript segments streamed back to the iPhone
```

The iPhone client is in `AppleClient/`. The Python server is `server.py`. The server uses the existing Lecture Transcriber installation and model cache; it does not download model weights or install the model itself.

## Requirements

- iPhone with the EchoNote app installed
- Windows PC with the Lecture Transcriber project, its Python environment, and the Parakeet model cache already set up
- Tailscale installed and signed in on both devices, on the same tailnet
- PC kept awake with the EchoNote server running during a recording
- Xcode and an Apple Developer signing team to build and install the iPhone app

## Build and install the iPhone app

1. Open `AppleClient/EchoNote.xcodeproj` in Xcode.
2. Select the **EchoNote** app target and configure **Signing & Capabilities** with your Apple Account and an available bundle identifier.
3. Build for a connected iPhone and install from Xcode.

See [AppleClient/BUILDING_IOS.md](AppleClient/BUILDING_IOS.md) for detailed signing, command-line build, and device installation steps.

## Start the server

On the Windows PC, open PowerShell in this repository and run:

```powershell
.\Start-EchoNoteServer.ps1
```

The launcher checks the Tailscale address, Python environment, Lecture Transcriber source, and local Parakeet cache before starting. Initial startup may take time while the model loads into memory. Keep the server running between sessions to avoid reloading it.

See [SERVER_RUN.md](SERVER_RUN.md) for configuration, protocol details, transcript and metrics locations, and troubleshooting guidance.

## Connect and record

1. Start the EchoNote server on the PC.
2. Confirm the iPhone and PC are connected to the same Tailscale network.
3. Open EchoNote on the iPhone and wait for the status indicator to show the PC is ready.
4. Tap the recording control to start, then tap it again to stop.
5. View, copy, or clear the transcript in the app.

With VAD enabled, the app sends voiced audio with a short pre-roll and trailing audio, and uses pauses to end transcript segments. Turn VAD off to send fixed-duration segments; choose the duration in the app before recording. Stop flushes any remaining audio for transcription.

## Data and privacy

- Raw audio is streamed to the PC and processed in memory. The server does not retain a complete audio recording.
- For inference, the existing Lecture Transcriber helper briefly writes each segment as a temporary WAV and removes it after processing.
- Transcript text is written to a separate local text file for each session under `.echonote-runtime/transcripts/`. Partial sessions keep any chunks that completed before disconnect.
- Session metadata is stored in `.echonote-runtime/logs/session_metrics.sqlite3`. It includes times, durations, frame and segment counts, recognized word counts, and processing timings; it does not contain transcript text.
- The server logs timing and count metrics, not raw audio or transcript text.
- The WebSocket server uses plain `ws://` and is intended only for private Tailscale access. Do not expose its port to the public internet.

## Current limitations

- One active recording session is supported at a time.
- The PC must remain awake and the server must remain available throughout recording.
- WSS, automatic reconnects, transcript overlap reconciliation, and client-side sequence metadata are not implemented yet.
- A transcription segment failure is reported; the server continues with later accepted segments and reports failed segment indices in the final status.

## Repository layout

- `AppleClient/` — SwiftUI iPhone app and Xcode project
- `server.py` — local WebSocket server and Parakeet integration
- `Start-EchoNoteServer.ps1` — Windows server launcher
- `SERVER_RUN.md` — server setup, operation, and protocol reference
- `SERVER_DESIGN_BRIEF.md` — server architecture and design decisions
- `MODEL_PATH.md` — shared model cache notes
