import Foundation
import CGVirtualDisplayPrivate
import CoreGraphics

/// Creates a genuine extra macOS display (not a mirror) that shows up in
/// System Settings > Displays, so windows can be dragged onto it like any
/// other monitor. Backed by Apple's undocumented `CGVirtualDisplay` classes
/// — see CGVirtualDisplayPrivate.h for caveats. If this ever fails to
/// create a display (e.g. a macOS update removes the private API), fall
/// back to `ScreenCaptureSource` against the real display instead (plain
/// mirroring), which only relies on public ScreenCaptureKit APIs.
final class VirtualDisplayManager {
    private(set) var virtualDisplay: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID?

    enum VirtualDisplayError: Error {
        case creationFailed
        case settingsRejected
    }

    /// Creates a new virtual display sized to match a Quest 2 "extended screen" panel.
    /// 1920x1080 @ 60Hz is a reasonable default: sharp enough to read, low enough
    /// resolution to keep WebRTC encode/decode latency low over Wi-Fi.
    @discardableResult
    func createDisplay(width: Int = 1920, height: Int = 1080, refreshRate: Double = 60) throws -> CGDirectDisplayID {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "Quest Mirror"
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        descriptor.sizeInMillimeters = CGSize(width: 520, height: 320) // ~24" diagonal, arbitrary but plausible
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x5051 // 'QM' - unofficial, avoids colliding with a real vendor ID
        descriptor.serialNum = UInt32(Date().timeIntervalSince1970)
        descriptor.queue = DispatchQueue(label: "com.questmirror.virtualdisplay")

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.creationFailed
        }

        let mode = CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: refreshRate)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [mode]

        guard display.applySettings(settings) else {
            throw VirtualDisplayError.settingsRejected
        }

        self.virtualDisplay = display
        self.displayID = display.displayID
        return display.displayID
    }

    /// Releasing the `CGVirtualDisplay` instance removes the monitor from macOS.
    func destroyDisplay() {
        virtualDisplay = nil
        displayID = nil
    }
}
