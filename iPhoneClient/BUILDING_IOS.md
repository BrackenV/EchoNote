# Building EchoNote for iPhone

This repository now includes an Xcode project at `EchoNote.xcodeproj`. The SwiftUI sources are already added to its app target; do not create a second project or add those files again.

## One-time Xcode setup

1. Open `iPhoneClient/EchoNote.xcodeproj` in Xcode.
2. Sign in under **Xcode → Settings → Apple Accounts** with the Apple Account used on the iPhone.
3. Select the **EchoNote** project, then the **EchoNote** app target, then **Signing & Capabilities**.
4. Leave **Automatically manage signing** enabled and select the account's **Personal Team** (or the intended paid team).
5. Use an app identifier that is available to that team. This setup uses `com.elliotthull.echonote`; the original `com.brackenv.EchoNote` was already registered and could not be used.

Xcode may show an existing Apple Development certificate as **Not in Keychain** when its private key was created on another Mac. With the team selected and an available bundle identifier, Xcode successfully updated signing for this project and showed an Apple Development signing certificate plus an Xcode managed provisioning profile. If Xcode cannot update signing, import the matching certificate and private key from a `.p12` export or resolve the account/team error shown in Signing & Capabilities.

The app uses the checked-in `EchoNote/Info.plist`. Keep `CFBundleName`, `CFBundleDisplayName`, and `CFBundleExecutable` in it: without these, Xcode can build the `.app` but iOS rejects it as an invalid bundle during installation. The plist also includes the microphone permission, bundle identifier, version, and package type.

The iPhone app connects to the PC at `ws://100.118.165.117:8765`. It needs no password. A small WebSocket health check runs every five seconds; the status light is green when the PC server responds, orange while checking, and red when the server cannot be reached. The check does not start a recording session.

## Build

Build a signed iPhone app bundle with automatic signing:

```sh
xcodebuild \
  -project iPhoneClient/EchoNote.xcodeproj \
  -scheme EchoNote \
  -sdk iphoneos \
  -configuration Debug \
  -derivedDataPath /tmp/EchoNoteSignedBuild \
  -destination 'generic/platform=iOS' \
  build
```

The resulting app is:

```text
/tmp/EchoNoteSignedBuild/Build/Products/Debug-iphoneos/EchoNote.app
```

For an unsigned simulator build, use:

```sh
xcodebuild \
  -project iPhoneClient/EchoNote.xcodeproj \
  -scheme EchoNote \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath /tmp/EchoNoteDerived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Install on a connected iPhone

1. Connect and trust the iPhone, then get its device identifier with `xcrun devicectl list devices`.
2. If installation reports that the developer disk image could not be mounted because Developer Mode is off, enable **Settings → Privacy & Security → Developer Mode** on the iPhone, restart it, and confirm the prompt on the device.
3. Install the signed app, replacing `<DEVICE_UDID>` with the identifier from `devicectl`:

```sh
xcrun devicectl device install app \
  --device <DEVICE_UDID> \
  /tmp/EchoNoteSignedBuild/Build/Products/Debug-iphoneos/EchoNote.app
```

If iOS installs the app but refuses its first launch because the developer profile has not been trusted, open **Settings → General → VPN & Device Management → Developer App**, select the Apple Development identity for the Personal Team, and tap **Trust**. Then open EchoNote from the Home Screen or App Library.

## What succeeded in the initial setup

- Xcode 27.2 built the app for both iOS Simulator and generic iPhone hardware.
- Automatic signing produced a signed device build using the Personal Team and an Xcode managed provisioning profile.
- The initial install failed because the custom plist lacked `CFBundleName`, `CFBundleDisplayName`, and `CFBundleExecutable`. Those entries were added; the signed app then installed successfully.
- The first install attempt also confirmed Developer Mode must be enabled before Xcode can mount its developer disk image.
- The app is installed on the connected iPhone. Its first launch still requires trusting the Personal Team under **VPN & Device Management**.
- The build emits non-fatal warnings about the deprecated Bluetooth audio session option and missing launch-screen/orientation settings.

## Connect to the transcription server

Start the server as described in `../SERVER_RUN.md`. The iPhone must be signed into the same tailnet, and the PC must be awake with the server running.
