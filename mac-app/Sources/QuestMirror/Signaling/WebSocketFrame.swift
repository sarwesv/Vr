import Foundation

/// Minimal RFC 6455 frame encode/decode — just enough for short text (JSON)
/// messages between this app and the WebXR page: single-frame (no
/// continuation), text/close/ping/pong opcodes only.
enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WebSocketFrame {
    let opcode: WebSocketOpcode
    let payload: Data

    /// Server-to-client frames must NOT be masked (RFC 6455 §5.1).
    func encoded() -> Data {
        var bytes = Data()
        bytes.append(0x80 | opcode.rawValue) // FIN=1, opcode

        let length = payload.count
        if length <= 125 {
            bytes.append(UInt8(length))
        } else if length <= 0xFFFF {
            bytes.append(126)
            bytes.append(UInt8((length >> 8) & 0xFF))
            bytes.append(UInt8(length & 0xFF))
        } else {
            bytes.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((UInt64(length) >> shift) & 0xFF))
            }
        }
        bytes.append(payload)
        return bytes
    }

    /// Parses one frame from the front of `buffer`. Returns nil if the buffer
    /// doesn't yet contain a complete frame. On success, also returns how
    /// many bytes were consumed so the caller can trim its buffer.
    static func parse(from buffer: Data) -> (frame: WebSocketFrame, consumed: Int)? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer)

        let opcodeRaw = bytes[0] & 0x0F
        guard let opcode = WebSocketOpcode(rawValue: opcodeRaw) else { return nil }

        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2

        if length == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            var extended: UInt64 = 0
            for i in 0..<8 { extended = (extended << 8) | UInt64(bytes[offset + i]) }
            length = Int(extended)
            offset += 8
        }

        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<offset + 4])
            offset += 4
        }

        guard bytes.count >= offset + length else { return nil }
        var payloadBytes = Array(bytes[offset..<offset + length])
        if masked {
            for i in 0..<payloadBytes.count {
                payloadBytes[i] ^= maskKey[i % 4]
            }
        }

        let frame = WebSocketFrame(opcode: opcode, payload: Data(payloadBytes))
        return (frame, offset + length)
    }
}
