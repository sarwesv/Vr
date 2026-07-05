import Foundation
import Network
import CryptoKit

/// One JSON message exchanged over the signaling WebSocket. The Mac always
/// sends "offer"/"ice" and expects "answer"/"ice"/"hello" back from the
/// Quest browser page.
struct SignalingMessage: Codable {
    var type: String
    var sdp: String?
    var candidate: String?
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

/// Serves the WebXR client (static files) and speaks a tiny hand-rolled
/// WebSocket protocol for SDP/ICE signaling. Deliberately single-client:
/// a new browser connection replaces whatever was previously connected,
/// since only one headset mirrors the Mac at a time.
final class SignalingServer {
    var onClientConnected: (() -> Void)?
    var onMessage: ((SignalingMessage) -> Void)?

    private var listener: NWListener?
    private var currentClient: ClientConnection?
    private let webRoot: URL
    private let queue = DispatchQueue(label: "com.questmirror.signaling")

    init(webRoot: URL) {
        self.webRoot = webRoot
    }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        currentClient?.close()
        currentClient = nil
        listener?.cancel()
        listener = nil
    }

    func send(_ message: SignalingMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        currentClient?.sendText(data)
    }

    private func accept(_ connection: NWConnection) {
        let client = ClientConnection(connection: connection, webRoot: webRoot)
        client.onUpgradedToWebSocket = { [weak self, weak client] in
            guard let self, let client else { return }
            self.currentClient?.close()
            self.currentClient = client
            self.onClientConnected?()
        }
        client.onMessage = { [weak self] message in
            self?.onMessage?(message)
        }
        client.start()
    }
}

/// Handles a single TCP connection through its whole lifecycle: HTTP
/// request -> either a static file response, or a 101 upgrade followed by
/// framed WebSocket messages.
private final class ClientConnection {
    var onUpgradedToWebSocket: (() -> Void)?
    var onMessage: ((SignalingMessage) -> Void)?

    private let connection: NWConnection
    private let webRoot: URL
    private var recvBuffer = Data()
    private var isWebSocket = false

    init(connection: NWConnection, webRoot: URL) {
        self.connection = connection
        self.webRoot = webRoot
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        connection.start(queue: .main)
        receiveMore()
    }

    func close() {
        connection.cancel()
    }

    func sendText(_ payload: Data) {
        guard isWebSocket else { return }
        let frame = WebSocketFrame(opcode: .text, payload: payload)
        connection.send(content: frame.encoded(), completion: .contentProcessed { _ in })
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.recvBuffer.append(data)
                if self.isWebSocket {
                    self.drainWebSocketFrames()
                } else {
                    self.tryHandleHTTPRequest()
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receiveMore()
        }
    }

    // MARK: - HTTP / upgrade handshake

    private func tryHandleHTTPRequest() {
        guard let headerEnd = recvBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = recvBuffer.subdata(in: recvBuffer.startIndex..<headerEnd.lowerBound)
        recvBuffer.removeSubrange(recvBuffer.startIndex..<headerEnd.upperBound)

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            close()
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { close(); return }
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            performWebSocketUpgrade(key: key)
        } else {
            serveStaticFile(path: path)
        }
    }

    private func performWebSocketUpgrade(key: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let acceptRaw = key + magic
        let digest = Insecure.SHA1.hash(data: Data(acceptRaw.utf8))
        let accept = Data(digest).base64EncodedString()

        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "", ""
        ].joined(separator: "\r\n")

        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.isWebSocket = true
            self.onUpgradedToWebSocket?()
        })
    }

    private func serveStaticFile(path: String) {
        let relativePath = (path == "/" || path.isEmpty) ? "index.html" : String(path.dropFirst())
        let fileURL = webRoot.appendingPathComponent(relativePath)

        guard let data = try? Data(contentsOf: fileURL) else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(notFound.utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
            return
        }

        let contentType: String
        switch fileURL.pathExtension {
        case "html": contentType = "text/html; charset=utf-8"
        case "js": contentType = "application/javascript; charset=utf-8"
        case "css": contentType = "text/css; charset=utf-8"
        default: contentType = "application/octet-stream"
        }

        let headerText = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(data.count)",
            "Connection: keep-alive",
            "", ""
        ].joined(separator: "\r\n")

        var responseData = Data(headerText.utf8)
        responseData.append(data)
        connection.send(content: responseData, completion: .contentProcessed { _ in })
    }

    // MARK: - WebSocket frames

    private func drainWebSocketFrames() {
        while let (frame, consumed) = WebSocketFrame.parse(from: recvBuffer) {
            recvBuffer.removeFirst(consumed)
            handle(frame: frame)
        }
    }

    private func handle(frame: WebSocketFrame) {
        switch frame.opcode {
        case .text:
            if let message = try? JSONDecoder().decode(SignalingMessage.self, from: frame.payload) {
                onMessage?(message)
            }
        case .ping:
            let pong = WebSocketFrame(opcode: .pong, payload: frame.payload)
            connection.send(content: pong.encoded(), completion: .contentProcessed { _ in })
        case .close:
            close()
        default:
            break
        }
    }
}
