import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case captureFailed
    case cropFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:        return "No display matched that selection."
        case .captureFailed:    return "The screen capture failed."
        case .cropFailed:       return "The selection fell outside the captured image."
        case .permissionDenied: return "TextSnap needs Screen Recording access to read the screen."
        }
    }
}

/// CGImage is a CoreFoundation type with no Sendable conformance. Capture and OCR
/// hand images between actors on a strict main-thread-produces / background-consumes
/// basis, so the wrapper documents that the crossing is deliberate.
struct CapturedImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Everything the capture needs to know about a display, snapshotted on the main
/// actor so the capture itself can run without touching AppKit.
struct DisplayTarget: Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect       // global Cocoa coordinates, origin bottom-left
    let scale: CGFloat
    let primaryHeight: CGFloat
}

enum ScreenCapture {

    // MARK: Main-actor setup

    /// Picks the display holding the largest slice of the selection.
    @MainActor
    static func target(for rect: CGRect) -> DisplayTarget? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let screen = screens.max { a, b in
            let ia = a.frame.intersection(rect)
            let ib = b.frame.intersection(rect)
            return ia.width * ia.height < ib.width * ib.height
        }
        guard let screen, let displayID = screen.displayID else { return nil }

        let primary = screens.first { $0.frame.origin == .zero } ?? screens[0]
        return DisplayTarget(displayID: displayID,
                             frame: screen.frame,
                             scale: screen.backingScaleFactor,
                             primaryHeight: primary.frame.height)
    }

    // MARK: Capture

    /// Captures `globalRect` (Cocoa coordinates), clamped to `target`.
    static func image(in globalRect: CGRect, target: DisplayTarget) async throws -> CapturedImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        let rect = globalRect.intersection(target.frame).integral
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.cropFailed }

        if #available(macOS 14.0, *) {
            return CapturedImage(cgImage: try await captureViaScreenCaptureKit(rect: rect, target: target))
        } else {
            return CapturedImage(cgImage: try captureViaWindowList(rect: rect, target: target))
        }
    }

    /// Captures the whole display then crops locally. Cropping ourselves sidesteps the
    /// `SCStreamConfiguration.sourceRect` inconsistencies seen on multi-display setups.
    @available(macOS 14.0, *)
    private static func captureViaScreenCaptureKit(rect: CGRect, target: DisplayTarget) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw CaptureError.noDisplay
        }

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * target.scale)
        config.height = Int(CGFloat(display.height) * target.scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return try crop(full, to: rect, target: target)
    }

    /// Ventura fallback. CGWindowList measures from the top-left of the primary display.
    private static func captureViaWindowList(rect: CGRect, target: DisplayTarget) throws -> CGImage {
        let flipped = CGRect(x: rect.minX,
                             y: target.primaryHeight - rect.maxY,
                             width: rect.width,
                             height: rect.height)
        guard let image = CGWindowListCreateImage(flipped,
                                                 .optionOnScreenOnly,
                                                 kCGNullWindowID,
                                                 [.bestResolution, .boundsIgnoreFraming]) else {
            throw CaptureError.captureFailed
        }
        return image
    }

    // MARK: Cropping

    private static func crop(_ image: CGImage, to rect: CGRect, target: DisplayTarget) throws -> CGImage {
        // Derive scale from the returned image rather than trusting backingScaleFactor,
        // which disagrees on mirrored and scaled displays.
        guard target.frame.width > 0 else { throw CaptureError.cropFailed }
        let scale = CGFloat(image.width) / target.frame.width

        let local = CGRect(x: rect.minX - target.frame.minX,
                           y: target.frame.maxY - rect.maxY,
                           width: rect.width,
                           height: rect.height)

        let pixels = CGRect(x: local.minX * scale,
                            y: local.minY * scale,
                            width: local.width * scale,
                            height: local.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard pixels.width >= 1, pixels.height >= 1, let cropped = image.cropping(to: pixels) else {
            throw CaptureError.cropFailed
        }
        return cropped
    }

    // MARK: Upscaling

    /// Vision reads small type poorly, so gently enlarge thin selections before OCR.
    static func upscaled(_ image: CapturedImage, minimumHeight: CGFloat = 160) -> CapturedImage {
        let height = CGFloat(image.cgImage.height)
        guard height > 0, height < minimumHeight else { return image }
        let factor = min(4.0, minimumHeight / height)

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image.cgImage)
        filter.scale = Float(factor)
        filter.aspectRatio = 1

        guard let output = filter.outputImage,
              let result = CIContext(options: [.useSoftwareRenderer: false])
                  .createCGImage(output, from: output.extent) else { return image }
        return CapturedImage(cgImage: result)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
