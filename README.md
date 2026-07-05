# Quest Mirror

Wirelessly mirror (or extend) your Mac's screen onto a Meta Quest 2, over
your local Wi-Fi. No app to install on the headset — you just open a URL in
the built-in Quest Browser.

## How it works

```
 macOS app (Swift)                         Quest Browser (WebXR page)
 ─────────────────                         ──────────────────────────
 ScreenCaptureKit  ──capture frames──▶  RTCPeerConnection ──WebRTC/UDP──▶  RTCPeerConnection
 (real display, or a                    (offerer, sends                  (answerer, ontrack
  private-API virtual                    video track)                    → video texture on
  display for "extend")                                                   a floating panel)
                    │
                    └── HTTP + WebSocket server (signaling + serves the
                        WebXR page itself) on port 8843
```

- **Mac side** (`mac-app/`): a Swift menu bar app that captures a display
  with `ScreenCaptureKit`, feeds frames into WebRTC (`stasel/WebRTC`), and
  runs a small hand-rolled HTTP/WebSocket server for signaling and for
  serving the web client — no external web server needed.
- **Quest side**: nothing to install. Open `http://<your-mac-ip>:8843` in
  the Quest's Browser app. The page is a plain WebXR + WebGL client (no
  Three.js/CDN dependency) that receives the WebRTC video track and renders
  it as a floating panel once you tap "Enter VR".

## Two modes

- **Mirror** (default, always works): captures your existing main display
  via the public `ScreenCaptureKit` API. What you see on the Quest is a
  duplicate of your Mac's screen.
- **Extend** (experimental): creates a genuine *extra* macOS display —
  drag windows onto it like any other monitor — using Apple's undocumented
  `CGVirtualDisplay` classes (the same private API tools like
  [BetterDisplay](https://github.com/waydabber/BetterDisplay) use). This is
  **not a public/supported API**: the class and selector names could change
  or disappear in a future macOS release. If display creation fails, the
  app falls back to Mirror mode.

Toggle between them from the menu bar icon.

## Building

Requires Xcode 15+ / macOS 13+ on a real Mac (this can't be built or tested
in a Linux container — there's no Swift/AppKit/ScreenCaptureKit toolchain
here, and no physical Quest 2 to verify against).

```bash
cd mac-app
swift build -c release
swift run   # or: .build/release/QuestMirror
```

On first launch, macOS will prompt for **Screen Recording** permission
(System Settings → Privacy & Security → Screen Recording) — grant it and
relaunch. Because `swift run`/`swift build` produces a plain executable
(not a code-signed `.app` bundle), macOS may ask again after each rebuild;
if that gets annoying, wrap it in an Xcode app target and it'll persist
normally.

## Using it

1. Launch the Mac app. Click its menu bar icon to see the URL to open
   (e.g. `http://192.168.1.23:8843`) and to pick Mirror vs. Extend mode.
2. On the Quest 2, open that URL in the **Browser** app (same Wi-Fi
   network as the Mac — no internet access required for either device).
3. The page shows a 2D preview once the stream connects. Put on the
   headset and tap **Enter VR**.
4. Your Mac's screen appears as a floating panel about 2m in front of you.

## Known limitations / next steps

- Single client at a time — a new browser connection replaces the
  previous one.
- No audio.
- The floating panel is fixed in place (not grabbable/repositionable yet);
  moving that would mean handling controller input in `app.js`.
- `stasel/WebRTC`'s pinned version in `Package.swift` may need bumping to
  whatever the latest tag is when you build.
- Extend mode's virtual display resolution/refresh rate is hardcoded
  (1920×1080@60) in `VirtualDisplayManager.swift`; adjust to taste.

## Project layout

```
mac-app/
  Package.swift
  Sources/
    QuestMirror/                  the app
      main.swift, AppDelegate.swift
      Capture/ScreenCaptureSource.swift
      Display/VirtualDisplayManager.swift
      Streaming/WebRTCStreamer.swift, VideoCaptureBridge.swift
      Signaling/SignalingServer.swift, WebSocketFrame.swift
      Resources/web/              served to the Quest Browser
        index.html, app.js, style.css
    CGVirtualDisplayPrivate/       ObjC header declaring Apple's private
                                   virtual-display classes (see caveats above)
```
