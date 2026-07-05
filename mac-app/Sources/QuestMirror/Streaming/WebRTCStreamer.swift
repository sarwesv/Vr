import Foundation
import WebRTC

/// Owns one WebRTC peer connection that streams the captured screen to a
/// single Quest browser tab. The Mac is always the offerer, since it's the
/// side that has the media to send; the browser just answers.
final class WebRTCStreamer: NSObject {
    var onLocalSessionDescription: ((RTCSessionDescription) -> Void)?
    var onLocalIceCandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionStateChange: ((RTCPeerConnectionState) -> Void)?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private(set) var captureBridge: VideoCaptureBridge?

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    deinit {
        RTCShutdownSSL()
    }

    /// Tears down any existing connection and starts a fresh one, adding a
    /// video track fed by the screen/virtual-display capture pipeline.
    func startNewConnection() {
        close()

        let config = RTCConfiguration()
        // LAN-only by design (Mac and Quest on the same Wi-Fi); no STUN/TURN needed
        // for host candidates to work, but a public STUN server is kept as a
        // harmless fallback in case of an unusual local network setup.
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let source = factory.videoSource()
        let bridge = VideoCaptureBridge(source: source)
        let track = factory.videoTrack(with: source, trackId: "quest-mirror-video")
        pc.add(track, streamIds: ["quest-mirror-stream"])

        self.peerConnection = pc
        self.videoSource = source
        self.captureBridge = bridge

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo": "false", "OfferToReceiveAudio": "false"],
            optionalConstraints: nil
        )
        pc.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self, let sdp else {
                if let error { NSLog("QuestMirror: failed to create offer: \(error)") }
                return
            }
            pc.setLocalDescription(sdp) { error in
                if let error {
                    NSLog("QuestMirror: failed to set local description: \(error)")
                    return
                }
                self.onLocalSessionDescription?(sdp)
            }
        }
    }

    func setRemoteAnswer(_ sdp: RTCSessionDescription) {
        peerConnection?.setRemoteDescription(sdp) { error in
            if let error {
                NSLog("QuestMirror: failed to set remote description: \(error)")
            }
        }
    }

    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { error in
            if let error {
                NSLog("QuestMirror: failed to add ICE candidate: \(error)")
            }
        }
    }

    func close() {
        peerConnection?.close()
        peerConnection = nil
        videoSource = nil
        captureBridge = nil
    }
}

extension WebRTCStreamer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalIceCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onConnectionStateChange?(newState)
    }

    // Unused delegate callbacks required by the protocol.
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
