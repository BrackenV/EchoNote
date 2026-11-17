# EchoNote

EchoNote transcribes lecture audio on a Windows PC using the NVIDIA Parakeet model already installed for Lecture Transcriber. Clients send mono 16 kHz signed 16-bit PCM over a WebSocket on the private Tailscale network. Transcript segments return over that same connection.

## Repository layout

- `iPhoneClient/` — SwiftUI iPhone app and Xcode project.
- `MacClient/` — native macOS lecture recorder, EchoNote streaming client, and Rust audio backend.
- `server.py` — Windows WebSocket server and Parakeet integration.
- `Start-EchoNoteServer.ps1` — Windows launcher; binds the server to the PC's Tailscale IPv4 address.
- `SERVER_RUN.md` — server setup, operation, protocol, and troubleshooting.
- `SERVER_DESIGN_BRIEF.md` — server architecture and design decisions.
- `MODEL_PATH.md` — shared model cache notes.

## How the clients connect

The PC server listens on the PC's Tailscale address. Each client initiates its own WebSocket connection to that address. The server sends transcript results back through the open connection; it does not need to know a client's Tailscale address or open a connection back to a client.

```text
iPhone or Mac microphone
    -> 16 kHz mono PCM over WebSocket
    -> Windows PC on Tailscale
    -> cached Parakeet model
    -> transcript segments over the same WebSocket
```

The Mac recorder always saves the full WAV locally. Its optional transcription toggle streams audio to the PC and saves received transcript segments beside the WAV as a text file. The iPhone streams audio to the PC and displays the transcript in the app.

## Start the server

On the Windows PC, open PowerShell in this repository and run:

```powershell
.\Start-EchoNoteServer.ps1
```

The launcher checks the Tailscale address, Python environment, Lecture Transcriber source, and local Parakeet cache before starting. It prints the PC address and port clients should use. Initial startup may take time while the model loads into memory.

See [SERVER_RUN.md](SERVER_RUN.md) for configuration, transcript and metrics locations, and troubleshooting.

## Build the iPhone client

Open `iPhoneClient/EchoNote.xcodeproj` in Xcode, configure signing for your Apple Account, then build and install to an iPhone. The server address is configured in `iPhoneClient/EchoNote/EchoNoteTransport.swift`. See [iPhoneClient/BUILDING_IOS.md](iPhoneClient/BUILDING_IOS.md) for detailed steps.

## Build the Mac client

On macOS with Rust and Apple's command-line tools installed, run:

```sh
cd MacClient
zsh build.sh
```

The build creates `MacClient/dist/Lecture Recorder.app`. Launch it, enable **Send audio to PC for transcription**, and enter the PC address printed by the server launcher (for example, `100.x.x.x:8765`). The Mac and PC must be signed into the same Tailscale network.

The recorder saves WAV files under `Lecture_Modules/<Module>/Week <number>` beside the app bundle. Transcript text is saved beside its WAV file when EchoNote transcription is enabled.

## Server requirements and privacy

- Windows PC with the Lecture Transcriber Python environment and Parakeet model cache already set up.
- Tailscale running on the PC and clients, all on the same tailnet.
- Keep the PC awake and the EchoNote server running during transcription.
- The server accepts one active recording session at a time.
- The server uses plain `ws://`; keep port `8765` on the private Tailscale network and do not expose it publicly.
- Raw audio is processed on the PC in segments. The server writes transcript files and session metadata under `.echonote-runtime/`.

See [SERVER_RUN.md](SERVER_RUN.md) for complete setup and protocol details.
