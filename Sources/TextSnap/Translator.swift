import AppKit
import SwiftUI
import NaturalLanguage

// MARK: - Supported languages

enum TranslationLanguages {
    /// A broad, fixed set of MyMemory-supported languages. MyMemory covers far more than
    /// this, but a curated list keeps the Settings picker short and each entry usable.
    static let myMemoryTargets = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ru", "ja", "ko", "zh", "ar", "hi",
        "tr", "pl", "sv", "da", "no", "fi", "cs", "el", "he", "hu", "id", "th", "vi",
        "uk", "ro", "bg", "sk", "hr", "sr", "lt", "lv", "et", "fa", "ur"
    ].sorted { Recognizer.displayName(forLanguage: $0) < Recognizer.displayName(forLanguage: $1) }

    /// DeepL's supported *target* languages, as of its documented language list. A few
    /// languages MyMemory covers (Arabic, Hindi, Thai, Vietnamese, Persian, Urdu, Hebrew,
    /// Serbian) aren't here because DeepL doesn't support them as translation targets.
    static let deepLTargets = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ru", "ja", "ko", "zh",
        "tr", "pl", "sv", "da", "no", "fi", "cs", "el", "hu", "id",
        "uk", "ro", "bg", "sk", "lt", "lv", "et", "sl"
    ].sorted { Recognizer.displayName(forLanguage: $0) < Recognizer.displayName(forLanguage: $1) }

    static func targets(for provider: TranslationProvider) -> [String] {
        switch provider {
        case .myMemory: return myMemoryTargets
        case .deepL:    return deepLTargets
        }
    }

    /// DeepL wants uppercase codes, and for a couple of languages a specific regional
    /// variant rather than the bare code MyMemory and the rest of the app use.
    static func deepLCode(for code: String) -> String {
        switch code {
        case "en": return "EN-US"
        case "pt": return "PT-PT"
        default:   return code.uppercased()
        }
    }
}

// MARK: - Translation errors

enum TranslationError: LocalizedError {
    case noConnection
    case rateLimited
    case tooLong(limit: Int)
    case missingAPIKey
    case invalidAPIKey
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .noConnection:
            return "Couldn't reach the translation service. Check your connection."
        case .rateLimited:
            return "The free translation quota is used up for today. Add a contact email in Settings to raise the limit, or try again tomorrow."
        case .tooLong(let limit):
            return "That capture is \(limit)+ characters, longer than the free translation service allows in one request. Try a smaller selection."
        case .missingAPIKey:
            return "Add a DeepL API key in Settings → Recognition to use DeepL, or switch the provider back to MyMemory."
        case .invalidAPIKey:
            return "DeepL rejected that API key. Check it in Settings → Recognition."
        case .serverError(let m):
            return m
        }
    }
}

// MARK: - MyMemory client

/// Talks to MyMemory's free translation API (mymemory.translated.net). No API key is
/// required; an optional contact email (Settings → Recognition) raises the free daily
/// quota from ~5,000 to ~50,000 words. Sending text here means it leaves the machine,
/// unlike every other recognition feature in the app, which runs entirely on-device.
enum MyMemoryClient {
    /// MyMemory rejects anonymous requests over this length outright.
    static let maxQueryLength = 500

    private struct Envelope: Decodable {
        struct Data: Decodable { let translatedText: String }
        let responseData: Data
        /// MyMemory sends this as a number on success but sometimes as a string
        /// (e.g. `"403"`) on failure, so decode either shape.
        let responseStatus: Int

        enum CodingKeys: String, CodingKey { case responseData, responseStatus }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            responseData = try container.decode(Data.self, forKey: .responseData)
            if let intValue = try? container.decode(Int.self, forKey: .responseStatus) {
                responseStatus = intValue
            } else {
                let stringValue = try container.decode(String.self, forKey: .responseStatus)
                responseStatus = Int(stringValue) ?? -1
            }
        }
    }

    static func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard text.count <= maxQueryLength else { throw TranslationError.tooLong(limit: maxQueryLength) }

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

// MARK: - DeepL client

/// Talks to DeepL's API using the key stored in the Keychain (Settings → Recognition).
/// A free-tier key (ending `:fx`) is billed against the `api-free.deepl.com` host; a
/// paid key uses `api.deepl.com` instead.
enum DeepLClient {
    private struct Envelope: Decodable {
        struct Translation: Decodable {
            let text: String
            let detected_source_language: String?
        }
        let translations: [Translation]
    }

    private struct ErrorEnvelope: Decodable { let message: String }

    static func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let apiKey = await AppSettings.shared.deepLAPIKey
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw TranslationError.missingAPIKey }

        let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var request = URLRequest(url: URL(string: "https://\(host)/v2/translate")!)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "source_lang", value: source.uppercased()),
            URLQueryItem(name: "target_lang", value: TranslationLanguages.deepLCode(for: target))
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.noConnection
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.serverError("The translation service returned an error.")
        }

        switch http.statusCode {
        case 200:
            break
        case 403:
            throw TranslationError.invalidAPIKey
        case 429, 456:
            throw TranslationError.rateLimited
        default:
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.message
            throw TranslationError.serverError(message ?? "Translation failed (status \(http.statusCode)).")
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let translation = envelope.translations.first
        else {
            throw TranslationError.serverError("The translation service sent back something unexpected.")
        }
        return translation.text
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
            let result: String
            switch AppSettings.shared.translationProvider {
            case .myMemory:
                result = try await MyMemoryClient.translate(originalText, from: sourceCode, to: targetLanguageCode)
            case .deepL:
                result = try await DeepLClient.translate(originalText, from: sourceCode, to: targetLanguageCode)
            }
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
