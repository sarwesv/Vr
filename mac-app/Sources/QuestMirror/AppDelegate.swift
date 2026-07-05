import Cocoa
import ScreenCaptureKit
import WebRTC

enum MirrorMode {
    case mirror   // duplicate the physical main display (always works, public APIs only)
    case extend   // create a separate virtual display (experimental, private API)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let port: UInt16 = 8843

    private var statusItem: NSStatusItem!
    private var mode: MirrorMode = .mirror

    private let signalingServer: SignalingServer
    private let streamer = WebRTCStreamer()
    private let virtualDisplayManager = VirtualDisplayManager()
    private var captureSource: ScreenCaptureSource?

    override init() {
        // SwiftPM's `.copy("Resources/web")` places the directory at the top
        // level of the resource bundle, named after its last path component.
        let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)
            ?? Bundle.module.bundleURL.appendingPathComponent("web")
        self.signalingServer = SignalingServer(webRoot: webRoot)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMenuBar()
        wireSignaling()

        do {
            try signalingServer.start(port: port)
            NSLog("QuestMirror: serving on http://\(Self.localIPAddress() ?? "<mac-ip>"):\(port)")
        } catch {
            NSLog("QuestMirror: failed to start signaling server: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        signalingServer.stop()
        streamer.close()
        virtualDisplayManager.destroyDisplay()
    }

    // MARK: - Menu bar UI

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusBar.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "visionpro", accessibilityDescription: "Quest Mirror")

        let menu = NSMenu()
        let addressItem = NSMenuItem(title: addressMenuTitle(), action: nil, keyEquivalent: "")
        addressItem.isEnabled = false
        menu.addItem(addressItem)
        menu.addItem(.separator())

        let mirrorItem = NSMenuItem(title: "Mirror main display", action: #selector(selectMirrorMode), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.state = mode == .mirror ? .on : .off
        menu.addItem(mirrorItem)

        let extendItem = NSMenuItem(title: "Extend as new display (experimental)", action: #selector(selectExtendMode), keyEquivalent: "")
        extendItem.target = self
        extendItem.state = mode == .extend ? .on : .off
        menu.addItem(extendItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Quest Mirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func addressMenuTitle() -> String {
        "Open on Quest Browser: http://\(Self.localIPAddress() ?? "?"):\(port)"
    }

    @objc private func selectMirrorMode() {
        guard mode != .mirror else { return }
        mode = .mirror
        virtualDisplayManager.destroyDisplay()
        setUpMenuBar()
    }

    @objc private func selectExtendMode() {
        guard mode != .extend else { return }
        do {
            try virtualDisplayManager.createDisplay()
            mode = .extend
        } catch {
            NSLog("QuestMirror: could not create virtual display (\(error)); staying in mirror mode")
            mode = .mirror
        }
        setUpMenuBar()
    }

    // MARK: - Signaling <-> WebRTC <-> capture wiring

    private func wireSignaling() {
        signalingServer.onClientConnected = { [weak self] in
            self?.beginStreamingToNewClient()
        }
        signalingServer.onMessage = { [weak self] message in
            self?.handleSignalingMessage(message)
        }
        streamer.onLocalSessionDescription = { [weak self] sdp in
            self?.signalingServer.send(SignalingMessage(type: "offer", sdp: sdp.sdp))
        }
        streamer.onLocalIceCandidate = { [weak self] candidate in
            self?.signalingServer.send(SignalingMessage(
                type: "ice",
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            ))
        }
    }

    private func beginStreamingToNewClient() {
        streamer.startNewConnection()

        Task {
            do {
                let displayID: CGDirectDisplayID
                if mode == .extend, let virtualID = virtualDisplayManager.displayID {
                    displayID = virtualID
                } else {
                    displayID = CGMainDisplayID()
                }
                let display = try await DisplayLookup.find(displayID: displayID)

                let source = ScreenCaptureSource { [weak self] pixelBuffer, timestamp in
                    self?.streamer.captureBridge?.deliver(pixelBuffer: pixelBuffer, timestamp: timestamp)
                }
                try await source.start(display: display, width: display.width, height: display.height, fps: 60)
                self.captureSource = source
            } catch {
                NSLog("QuestMirror: failed to start capture: \(error)")
            }
        }
    }

    private func handleSignalingMessage(_ message: SignalingMessage) {
        switch message.type {
        case "answer":
            guard let sdp = message.sdp else { return }
            streamer.setRemoteAnswer(RTCSessionDescription(type: .answer, sdp: sdp))
        case "ice":
            guard let candidateSdp = message.candidate else { return }
            let candidate = RTCIceCandidate(sdp: candidateSdp, sdpMLineIndex: message.sdpMLineIndex ?? 0, sdpMid: message.sdpMid)
            streamer.addRemoteIceCandidate(candidate)
        default:
            break
        }
    }

    // MARK: - Utilities

    static func localIPAddress() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostBuffer)
            if name == "en0" { break }
        }
        return address
    }
}
