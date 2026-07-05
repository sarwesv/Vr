import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures frames from a given macOS display (real or virtual) using ScreenCaptureKit
/// and hands each decoded `CVPixelBuffer` to a frame handler.
final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias FrameHandler = (CVPixelBuffer, CMTime) -> Void

    private var stream: SCStream?
    private let frameHandler: FrameHandler
    private let queue = DispatchQueue(label: "com.questmirror.capture")

    init(frameHandler: @escaping FrameHandler) {
        self.frameHandler = frameHandler
    }

    /// Starts capturing the given display at the requested pixel dimensions and frame rate.
    /// Pass the display created by `VirtualDisplayManager` for "extend" mode, or the physical
    /// display for plain mirroring.
    func start(display: SCDisplay, width: Int, height: Int, fps: Int) async throws {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 5

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        self.stream = newStream
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Only forward frames that represent a real content update (SCK also emits
        // "idle"/attachment-only buffers when nothing changed on screen).
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRawValue = attachmentsArray.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRawValue),
           status != .complete {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameHandler(pixelBuffer, pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("QuestMirror: capture stream stopped with error: \(error.localizedDescription)")
    }
}

enum ScreenCaptureError: Error {
    case noDisplayFound
}

enum DisplayLookup {
    /// Finds the `SCDisplay` matching a given `CGDirectDisplayID` (used to locate either the
    /// physical main display or a freshly created virtual display).
    static func find(displayID: CGDirectDisplayID) async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let match = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.noDisplayFound
        }
        return match
    }

    static func mainDisplay() async throws -> SCDisplay {
        try await find(displayID: CGMainDisplayID())
    }
}
