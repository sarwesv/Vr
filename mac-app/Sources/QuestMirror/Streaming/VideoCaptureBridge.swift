import Foundation
import CoreMedia
import CoreVideo
import WebRTC

/// Minimal `RTCVideoCapturer` subclass that exists only so WebRTC has a
/// capturer object to attribute frames to; the actual frames are pushed in
/// from `ScreenCaptureSource` via `deliver(pixelBuffer:timestamp:)` rather
/// than pulled by WebRTC itself.
final class VideoCaptureBridge: RTCVideoCapturer {
    private let source: RTCVideoSource
    private var firstFrameTimeNs: Int64?

    init(source: RTCVideoSource) {
        self.source = source
        super.init()
    }

    func deliver(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // WebRTC adapts/crops via this call; passing the actual size keeps it a no-op.
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 60)

        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: timeStampNs)

        source.capturer(self, didCapture: frame)
    }
}
