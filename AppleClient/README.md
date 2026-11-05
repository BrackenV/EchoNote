# EchoNote iPhone client

This folder contains the SwiftUI client source. It records microphone audio, converts it to mono 16 kHz signed 16-bit little-endian PCM, streams binary WebSocket messages to the EchoNote server, and displays each returned transcript segment.

## Add to an iOS app target

Create an iOS App project named **EchoNote** in Xcode (SwiftUI, iOS 17 or later), then add the five Swift files in `EchoNote/` to the app target. Set the bundle identifier and signing team for your device.

Use `EchoNote/Info.plist` as the app target's Info.plist (set **Generate Info.plist File** to No if Xcode generated one). It includes the microphone permission text and App Transport Security setting needed by the current plain WebSocket server. ATS arbitrary loads is broad; keep the server restricted to the tailnet. A later WSS server setup can remove this requirement.

## Connect

Start the server as described in `../SERVER_RUN.md`. In the app, enter `ws://<PC-Tailscale-IP>:8765` and paste the same token used by the server. The token is stored in the iOS Keychain. The iPhone must be signed into the same tailnet, and the PC must be awake with the server running.

The current protocol is version 1: `start`, binary PCM messages, `stop`; server responses are `started`, `transcript_segment`, `error`, and `final`.
