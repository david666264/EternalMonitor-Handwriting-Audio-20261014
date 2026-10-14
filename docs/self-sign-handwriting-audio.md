# Handwriting audio build

This personal build is based on EternalMonitor v0.3.0, upstream commit
`a5707e7d3150228793f79892abb8b7f343052200`. Use it with the matching official
Windows v0.3.0 host. The USB/video/input/Opus protocol is unchanged.

Drawing mode still provides native pen input and palm rejection. It no longer
disables audio. Enable **Play PC audio** on the iPad and enable audio on the
Windows host to hear TTS while writing. Switching drawing mode does not override
your audio preference. Muting remains available during a session.

## IPA build

Run the manual **Self-sign IPA** workflow on a macOS runner, or use Mac/Xcode:

```sh
BUILD=1001 bash scripts/testflight-local.sh --dry-run
python3 scripts/package_unsigned_ipa.py \
  --archive build/testflight/EternalMonitor.xcarchive \
  --output build/self-sign/EternalMonitor-v0.3.0-handwriting-audio-unsigned.ipa
```

The IPA contains an arm64 **iOS device** app. It is unsigned and requires your
own local signing certificate and provisioning profile before installation.
No signing credentials are needed by this build workflow, and nothing is
uploaded to App Store Connect. `CFBundleIdentifier` remains
`com.eternal.monitor`; your signing tool/profile must use a compatible identifier
and include your iPad.

The packaging command verifies the app platform, Mach-O executable, release
version and ZIP integrity. It rejects simulator executables and embedded
provisioning profiles. A JSON receipt beside the IPA records version, build
number and SHA-256.

The independent simulator test job runs eight live-stream checks, including
the four added drawing/audio cases for Wi-Fi and the framed USB fixture.
These are not physical iPad tests. After signing and installing, verify your
own Pencil strokes, palm rejection, audible TTS and cable reconnect behavior.

## First USB test

1. Open Apple Devices on Windows, connect a data-capable USB cable, and trust
   the computer on the unlocked iPad.
2. Open matching EternalMonitor apps on Windows and the iPad. Confirm the
   connection badge says **USB**.
3. Enable **Drawing mode** and **Play PC audio**, then reconnect so drawing
   mode applies.
4. Set the Windows host to its extended-display mode if desired. Start a
   saved Amadeus classroom explanation and write on the whiteboard.

The host captures Windows's default playback endpoint. Check that Amadeus is
audible on that endpoint; it should no longer be routed to a disconnected
spacedesk speaker from the earlier Wi-Fi test. Microphone input is independent:
keep **Wireless Mic Rx** selected in Amadeus.

Upstream license: MIT; see `LICENSE`. This modified build is not an upstream
release and has not received the author's TestFlight review.
