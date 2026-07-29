import AppKit
import PDFKit
import UniformTypeIdentifiers

enum CaptureKind: Sendable {
    case text
    case barcode
}

/// Lets a dedicated shortcut override the standing line-break preference.
enum LineBreakMode: Sendable {
    case followPreference
    case keep
    case strip

    @MainActor
    func resolved() -> Bool {
        switch self {
        case .followPreference: return AppSettings.shared.keepLineBreaks
        case .keep:             return true
        case .strip:            return false
        }
    }
}

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let overlay = OverlayController()
    private var lastSelection: CGRect?
    private var isBusy = false

    private init() {}

    var canRepeatLastSelection: Bool { lastSelection != nil }

    // MARK: Hotkey entry point

    func perform(_ action: HotKeyAction) {
        switch action {
        case .captureText:
            beginCapture(kind: .text, lineBreaks: .followPreference)
        case .captureKeepingLineBreaks:
            beginCapture(kind: .text, lineBreaks: .keep)
        case .captureStrippingLineBreaks:
            beginCapture(kind: .text, lineBreaks: .strip)
        case .captureWithSpeech:
            beginCapture(kind: .text, lineBreaks: .followPreference, speak: true)
        case .captureBarcode:
            beginCapture(kind: .barcode, lineBreaks: .keep)
        case .capturePreviousSelection:
            repeatLastSelection()
        case .toggleAdditiveClipboard:
            toggleAdditiveClipboard()
        case .clearAdditiveClipboard:
            AdditiveClipboard.shared.clear()
            SuccessHUD.shared.show(title: "Additive clipboard cleared", subtitle: nil, force: true)
        case .stopSpeaking:
            Speaker.shared.stop()
        }
    }

    // MARK: Interactive capture

    func beginCapture(kind: CaptureKind, lineBreaks: LineBreakMode, speak: Bool? = nil) {
        guard !isBusy else { return }
        guard SystemServices.hasScreenRecordingAccess() else {
            SystemServices.presentScreenRecordingAlert()
            return
        }

        isBusy = true
        overlay.begin { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.isBusy = false
                return
            }
            self.lastSelection = selection
            self.run(selection: selection, kind: kind, lineBreaks: lineBreaks, speak: speak)
        }
    }

    func repeatLastSelection() {
        guard !isBusy else { return }
        guard let selection = lastSelection else {
            SuccessHUD.shared.show(title: "No previous selection",
                                   subtitle: "Capture something first.",
                                   force: true)
            return
        }
        isBusy = true
        run(selection: selection, kind: .text, lineBreaks: .followPreference, speak: nil)
    }

    private func run(selection: CGRect, kind: CaptureKind, lineBreaks: LineBreakMode, speak: Bool?) {
        guard let target = ScreenCapture.target(for: selection) else {
            isBusy = false
            report(CaptureError.noDisplay)
            return
        }
        let options = RecognitionOptions(lineBreaks: lineBreaks)
        let shouldUpscale = AppSettings.shared.upscaleSmallSelections

        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                var image = try await ScreenCapture.image(in: selection, target: target)
                if shouldUpscale { image = ScreenCapture.upscaled(image) }

                switch kind {
                case .text:
                    let text = try await Self.readText(image, options: options)
                    finishText(text, speak: speak)
                case .barcode:
                    let payloads = try await Self.readBarcodes(image)
                    finishBarcodes(payloads, speak: speak)
                }
            } catch {
                report(error)
            }
        }
    }

    // MARK: Off-main recognition

    private static func readText(_ image: CapturedImage, options: RecognitionOptions) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Recognizer.readText(in: image, options: options)
        }.value
    }

    private static func readBarcodes(_ image: CapturedImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            try Recognizer.readBarcodes(in: image)
        }.value
    }

    // MARK: Results

    private func finishText(_ text: String, speak: Bool?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SuccessHUD.shared.show(title: "No text found",
                                   subtitle: "Try a tighter selection or a larger area.",
                                   force: true)
            return
        }
        deliver(text, speak: speak)
    }

    private func finishBarcodes(_ payloads: [String], speak: Bool?) {
        guard !payloads.isEmpty else {
            SuccessHUD.shared.show(title: "No code found",
                                   subtitle: "Nothing scannable in that selection.",
                                   force: true)
            return
        }
        deliver(payloads.joined(separator: "\n"), speak: speak)
    }

    // MARK: Delivery

    private func deliver(_ text: String, speak: Bool?) {
        let settings = AppSettings.shared
        let payload = settings.additiveClipboard ? AdditiveClipboard.shared.append(text) : text

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        CaptureSound.play()

        let count = text.count
        let title = settings.additiveClipboard
            ? "Added \u{00B7} \(AdditiveClipboard.shared.entries.count) captures on the clipboard"
            : "Copied \(count) character\(count == 1 ? "" : "s")"
        SuccessHUD.shared.show(title: title, subtitle: preview(of: text))

        if speak ?? settings.textToSpeech {
            Speaker.shared.speak(text)
        }
        LinkOpener.openIfSingleURL(text)
    }

    private func preview(of text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "\u{2026}" : trimmed
    }

    private func report(_ error: Error) {
        if let captureError = error as? CaptureError, case .permissionDenied = captureError {
            SystemServices.presentScreenRecordingAlert()
            return
        }
        SuccessHUD.shared.show(title: "Capture failed",
                               subtitle: error.localizedDescription,
                               force: true)
    }

    // MARK: Additive clipboard

    func toggleAdditiveClipboard() {
        let settings = AppSettings.shared
        settings.additiveClipboard.toggle()
        AdditiveClipboard.shared.updatePasteMonitor()
        SuccessHUD.shared.show(title: settings.additiveClipboard
                                 ? "Additive clipboard on"
                                 : "Additive clipboard off",
                               subtitle: settings.additiveClipboard
                                 ? "Captures stack up until you clear them."
                                 : nil,
                               force: true)
    }

    // MARK: Files and pasted images

    func recognizeFromFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose an image or PDF to read text from."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recognize(fileAt: url)
    }

    func recognize(fileAt url: URL) {
        let isPDF = (UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) ?? false)
            || url.pathExtension.lowercased() == "pdf"

        if isPDF {
            recognizePDF(at: url)
            return
        }

        guard let cgImage = NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            report(CaptureError.captureFailed)
            return
        }
        recognize(image: CapturedImage(cgImage: cgImage))
    }

    private func recognize(image: CapturedImage) {
        let options = RecognitionOptions(lineBreaks: .followPreference)
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await Self.readText(image, options: options)
                finishText(text, speak: nil)
            } catch {
                report(error)
            }
        }
    }

    /// Renders each page at 2x and reads it, so scanned PDFs work as well as text ones.
    private func recognizePDF(at url: URL) {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            report(CaptureError.captureFailed)
            return
        }

        // Rendering needs PDFKit on the main thread; OCR is dispatched per page.
        var images: [CapturedImage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
            guard let cgImage = page.thumbnail(of: size, for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            images.append(CapturedImage(cgImage: cgImage))
        }

        guard !images.isEmpty else {
            report(CaptureError.captureFailed)
            return
        }

        let options = RecognitionOptions(lineBreaks: .followPreference)
        let name = url.lastPathComponent

        Task { [weak self] in
            guard let self else { return }
            var pages: [String] = []
            do {
                for image in images {
                    let text = try await Self.readText(image, options: options)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pages.append(text)
                    }
                }
            } catch {
                report(error)
                return
            }

            guard !pages.isEmpty else {
                SuccessHUD.shared.show(title: "No text found", subtitle: name, force: true)
                return
            }
            deliver(pages.joined(separator: "\n\n"), speak: nil)
        }
    }

    func recognizeFromClipboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, url.isFileURL {
            recognize(fileAt: url)
            return
        }

        guard let cgImage = NSImage(pasteboard: pasteboard)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            SuccessHUD.shared.show(title: "No image on the clipboard",
                                   subtitle: "Copy an image, then try again.",
                                   force: true)
            return
        }
        recognize(image: CapturedImage(cgImage: cgImage))
    }
}
