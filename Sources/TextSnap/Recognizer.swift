import AppKit
import Vision

enum RecognitionError: LocalizedError {
    case nothingFound

    var errorDescription: String? {
        switch self {
        case .nothingFound: return "No text found in that selection."
        }
    }
}

/// An immutable snapshot of the preferences a single recognition pass needs.
/// Snapshotting keeps `Recognizer` free of actor isolation so OCR can run off
/// the main thread without freezing the UI on large or multi-page inputs.
struct RecognitionOptions: Sendable {
    var autoDetectLanguage: Bool
    var primaryLanguage: String
    var customWords: [String]
    var keepLineBreaks: Bool
    var preserveIndentation: Bool

    @MainActor
    init(lineBreaks: LineBreakMode) {
        let settings = AppSettings.shared
        autoDetectLanguage = settings.autoDetectLanguage
        primaryLanguage = settings.primaryLanguage
        customWords = settings.customWords
        keepLineBreaks = lineBreaks.resolved()
        preserveIndentation = settings.preserveIndentation
    }
}

enum Recognizer {

    // MARK: Text

    /// OCR plus reading-order reconstruction. Returns assembled text so only a
    /// `String` crosses back to the caller.
    static func readText(in image: CapturedImage, options: RecognitionOptions) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0

        if !options.customWords.isEmpty {
            request.customWords = options.customWords
        }

        if options.autoDetectLanguage {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            // Vision reads the array as a priority order.
            var languages = [options.primaryLanguage]
            if options.primaryLanguage != "en-US" { languages.append("en-US") }
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: image.cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        return TextAssembler.assemble(request.results ?? [],
                                      keepLineBreaks: options.keepLineBreaks,
                                      preserveIndentation: options.preserveIndentation)
    }

    // MARK: Barcodes

    /// Every decodable payload, ordered top-left to bottom-right.
    static func readBarcodes(in image: CapturedImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image.cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.05 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        return observations
            .compactMap { $0.payloadStringValue }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: Language list

    /// The languages Vision supports on this machine. The list grows with each
    /// macOS release, so it is queried rather than hard-coded.
    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let languages = try? request.supportedRecognitionLanguages(), !languages.isEmpty {
            return languages
        }
        return ["en-US"]
    }

    static func displayName(forLanguage identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale.current.localizedString(forLanguageCode: identifier)
            ?? identifier
    }
}
