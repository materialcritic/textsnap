import AppKit
import SwiftUI
import NaturalLanguage

// MARK: - Supported languages

enum TranslationLanguages {
    /// A broad, fixed set of MyMemory-supported languages. MyMemory covers far more than
    /// this, but a curated list keeps the Settings picker short and each entry usable.
    static let targets = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ru", "ja", "ko", "zh", "ar", "hi",
        "tr", "pl", "sv", "da", "no", "fi", "cs", "el", "he", "hu", "id", "th", "vi",
        "uk", "ro", "bg", "sk", "hr", "sr", "lt", "lv", "et", "fa", "ur"
    ].sorted { Recognizer.displayName(forLanguage: $0) < Recognizer.displayName(forLanguage: $1) }
}

// MARK: - Translation errors

enum TranslationError: LocalizedError {
    case noConnection
    case rateLimited
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .noConnection:      return "Couldn't reach the translation service. Check your connection."
        case .rateLimited:       return "The free translation quota is used up for today. Add a contact email in Settings to raise the limit, or try again tomorrow."
        case .serverError(let m): return m
        }
    }
}

// MARK: - MyMemory client

/// Talks to MyMemory's free translation API (mymemory.translated.net). No API key is
/// required; an optional contact email (Settings → Recognition) raises the free daily
/// quota from ~5,000 to ~50,000 words. Sending text here means it leaves the machine,
/// unlike every other recognition feature in the app, which runs entirely on-device.
enum MyMemoryClient {
    private struct Envelope: Decodable {
        struct Data: Decodable { let translatedText: String }
        let responseData: Data
        let responseStatus: Int
    }

    static func translate(_ text: String, from source: String, to target: String) async throws -> String {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        var items = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(source)|\(target)")
        ]
        let email = await AppSettings.shared.myMemoryContactEmail
        if !email.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "de", value: email))
        }
        components.queryItems = items

        guard let url = components.url else { throw TranslationError.serverError("Couldn't build a request for that text.") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw TranslationError.noConnection
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranslationError.serverError("The translation service returned an error.")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw TranslationError.serverError("The translation service sent back something unexpected.")
        }

        guard envelope.responseStatus == 200 else {
            if envelope.responseStatus == 403 { throw TranslationError.rateLimited }
            throw TranslationError.serverError("Translation failed (status \(envelope.responseStatus)).")
        }

        let translated = envelope.responseData.translatedText
        guard !translated.contains("MYMEMORY WARNING") else { throw TranslationError.rateLimited }
        return translated
    }
}

// MARK: - On-device language detection

enum LanguageDetector {
    /// Falls back to English when the text is too short or ambiguous to classify.
    static func detect(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }
}

// MARK: - Popup window

/// Shows a captured text's translation: detects the source language on-device, sends the
/// text to MyMemory for translation, and displays both alongside each other.
@MainActor
final class TranslationPopupController {
    static let shared = TranslationPopupController()

    private var panel: NSPanel?

    private init() {}

    /// `onTranslated` fires once, the first time a translation succeeds, with the result.
    func show(originalText: String, onTranslated: @escaping (String) -> Void) {
        panel?.orderOut(nil)

        var delivered = false
        let view = TranslationPopupView(
            originalText: originalText,
            targetLanguageCode: AppSettings.shared.translationTargetLanguage,
            onTranslated: { translated in
                guard !delivered else { return }
                delivered = true
                onTranslated(translated)
            },
            onClose: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 420, height: 280)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.midY - size.height / 2,
                           width: size.width,
                           height: size.height)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered,
                            defer: false)
        panel.title = "Translation"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 220)
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Popup content

private struct TranslationPopupView: View {
    let originalText: String
    let targetLanguageCode: String
    let onTranslated: (String) -> Void
    let onClose: () -> Void

    @State private var detectedLanguageName: String?
    @State private var translatedText: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Translation").font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }

            block(title: detectedLanguageName.map { "Original \u{00B7} \($0)" } ?? "Original",
                 text: originalText)

            Divider()

            translatedBlock
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .task { await translate() }
    }

    @MainActor
    private func translate() async {
        let sourceCode = LanguageDetector.detect(originalText)
        detectedLanguageName = Recognizer.displayName(forLanguage: sourceCode)

        guard sourceCode != targetLanguageCode else {
            translatedText = originalText
            onTranslated(originalText)
            return
        }

        do {
            let result = try await MyMemoryClient.translate(originalText, from: sourceCode, to: targetLanguageCode)
            translatedText = result
            onTranslated(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var translatedBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Translated \u{00B7} \(Recognizer.displayName(forLanguage: targetLanguageCode))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let translatedText {
                ScrollView {
                    Text(translatedText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 60, maxHeight: .infinity)
                .layoutPriority(1)
                Text("Copied to the clipboard")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating\u{2026}").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: .infinity)
            .layoutPriority(1)
        }
    }
}
