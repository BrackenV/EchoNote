# EchoNote Mac Client

This is the native macOS lecture recorder and EchoNote streaming client. It keeps the existing local WAV recorder and can optionally stream microphone audio to the EchoNote PC server over Tailscale. Completed transcript segments appear in a small plain-text window and are appended to a `.txt` file beside the WAV recording.

## Build

Requirements: macOS, Rust, and Apple's command-line developer tools.

```sh
zsh build.sh
```

The app bundle is created at `dist/Lecture Recorder.app`. Open it in Finder, choose the lecture folder and microphone, enable **Send audio to PC for transcription**, and enter the Tailscale address and port printed by `Start-EchoNoteServer.ps1` (normally `100.x.x.x:8765`).

The Mac initiates the WebSocket connection to the PC. Transcript messages return over that same connection. If the PC is unavailable when recording starts, the Mac continues saving the local WAV and reports that transcription is unavailable.

Recordings are saved in `Lecture_Modules/<Module>/Week <number>` beside the app bundle. The app stores its microphone, lecture, and server address preferences in macOS user defaults.
