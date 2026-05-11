import Foundation

#if os(macOS)
import AppKit
import ScreenCaptureKit

/// One-shot screen capture using ScreenCaptureKit's `SCScreenshotManager`.
/// Returns a PNG on disk that the caller owns (delete when done). Main display
/// only for v1.
///
/// Requires macOS 14+ (SCScreenshotManager.captureImage is macOS 14+). First
/// use triggers the system's screen-recording TCC prompt; Info.plist already
/// carries `NSScreenCaptureUsageDescription`.
actor ScreenCaptureService {
    static let shared = ScreenCaptureService()

    enum CaptureError: LocalizedError {
        case noDisplay
        case encodingFailed
        case unavailable

        var errorDescription: String? {
            switch self {
            case .noDisplay:       return "No display available to capture."
            case .encodingFailed:  return "Screenshot encoding failed."
            case .unavailable:     return "Screen capture requires macOS 14 or later."
            }
        }
    }

    /// Capture the primary (first-listed) display to a PNG in the temp dir.
    /// Returns the file URL; caller moves/deletes as needed.
    func captureMainDisplay() async throws -> URL {
        guard #available(macOS 14.0, *) else { throw CaptureError.unavailable }

        // `SCShareableContent.current` is the async API that also triggers the
        // TCC permission check. On denial it throws — propagate the error.
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        // Don't show the camera / screen-recording indicator dot unnecessarily.
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-screenshot-\(UUID().uuidString).png")
        try pngData.write(to: url)
        return url
    }
}
#endif
