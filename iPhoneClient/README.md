# EchoNote iPhone client

This folder contains the SwiftUI client and the `EchoNote.xcodeproj` Xcode project. It records microphone audio, converts it to mono 16 kHz signed 16-bit little-endian PCM, streams binary WebSocket messages to the EchoNote server, and displays each returned transcript segment.

Open `EchoNote.xcodeproj` in Xcode to build the app. See [BUILDING_IOS.md](BUILDING_IOS.md) for the working signing, build, and device-install steps.

`EchoNote/Info.plist` includes the microphone permission text and App Transport Security setting needed by the current plain WebSocket server. ATS arbitrary loads is broad; keep the server restricted to the tailnet. A later WSS server setup can remove this requirement.

## Connect

Start the server as described in `../SERVER_RUN.md`. The iPhone must be signed into the same tailnet, and the PC must be awake with the server running. The PC address in `EchoNote/EchoNoteTransport.swift` must match the address printed by the server launcher. The status light checks whether the server responds.

The current protocol is version 1: an `health` check, then `start`, binary PCM messages, and `stop`; server responses are `health`, `started`, `transcript_segment`, `error`, and `final`.
