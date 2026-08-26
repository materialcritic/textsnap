import AppKit
import SwiftUI
import Translation

// MARK: - Supported languages

@MainActor
enum TranslationLanguages {
    /// Languages this Mac has (or can download) translation resources for.
    static func supportedTargets() async -> [String] {
        let languages = await LanguageAvailability().supportedLanguages
        let codes = Set(languages.compactMap { $0.languageCode?.identifier })
        return codes.sorted { Recognizer.displayName(forLanguage: $0) < Recognizer.displayName(forLanguage: $1) }
    }
}

// MARK: - Popup window

/// Shows a captured text's on-device translation. Detection of the source language and
/// the translation itself both happen through Apple's Translation framework, driven by
/// the `translationTask` modifier on `TranslationPopupView` below.
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

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.midY - size.height / 2,
                           width: size.width,
                           height: size.height)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered,
                            defer: false)
        panel.title = "Translation"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

    @State private var configuration: TranslationSession.Configuration?
    @State private var translatedText: String?
    @State private var detectedLanguageName: String?
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
        .frame(width: 420, height: 280)
        .task {
            configuration = TranslationSession.Configuration(
                target: Locale.Language(identifier: targetLanguageCode))
        }
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(originalText)
                let code = response.sourceLanguage.languageCode?.identifier ?? response.sourceLanguage.minimalIdentifier
                detectedLanguageName = Recognizer.displayName(forLanguage: code)
                translatedText = response.targetText
                onTranslated(response.targetText)
            } catch {
                errorMessage = error.localizedDescription
            }
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
                .frame(maxHeight: 84)
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
            .frame(maxHeight: 84)
        }
    }
}
