import AppKit
import Combine
import SwiftUI

// MARK: - Window

@MainActor
final class SettingsWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "TextSnap Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(settings: AppSettings.shared))
        self.init(window: window)
    }

    func present() {
        // An accessory app must activate explicitly or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            RecognitionPane(settings: settings)
                .tabItem { Label("Recognition", systemImage: "text.viewfinder") }
            ShortcutsPane(settings: settings)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            ClipboardPane(settings: settings)
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(width: 520, height: 440)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = false
    @State private var hasScreenRecording = true

    var body: some View {
        Form {
            Section {
                Toggle("Launch TextSnap at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        SystemServices.setLaunchesAtLogin(newValue)
                    }
                Toggle("Show icon in the menu bar", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("With the icon hidden, use your shortcuts to capture. Reopen TextSnap from Finder to get back here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Feedback") {
                Toggle("Play a sound on capture", isOn: $settings.playSound)
                Picker("Sound", selection: $settings.soundName) {
                    ForEach(CaptureSound.available, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(!settings.playSound)
                .onChange(of: settings.soundName) { name in
                    CaptureSound.preview(name)
                }
                Toggle("Show a confirmation after each capture", isOn: $settings.showSuccessPopup)
            }

            Section("Speech") {
                Toggle("Speak captured text", isOn: $settings.textToSpeech)
                HStack {
                    Text("Rate")
                    Slider(value: $settings.speechRate, in: 0...1)
                    Text(rateLabel).font(.caption).monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!settings.textToSpeech)
            }

            Section("Links") {
                Toggle("Open a captured link automatically", isOn: $settings.openCapturedLinks)
                Text("Applies when the capture is a single URL, including one decoded from a QR code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !hasScreenRecording {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Recording access is off").font(.callout.weight(.medium))
                            Text("Captures will come back empty until it is granted.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Fix\u{2026}") { SystemServices.presentScreenRecordingAlert() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SystemServices.launchesAtLogin
            hasScreenRecording = SystemServices.hasScreenRecordingAccess()
        }
    }

    private var rateLabel: String {
        String(format: "%.0f%%", settings.speechRate * 100)
    }
}

// MARK: - Recognition

private struct RecognitionPane: View {
    @ObservedObject var settings: AppSettings
    @State private var languages: [String] = []
    @State private var newWord = ""

    var body: some View {
        Form {
            Section("Language") {
                Toggle("Detect the language automatically", isOn: $settings.autoDetectLanguage)
                Picker("Primary language", selection: $settings.primaryLanguage) {
                    ForEach(languages, id: \.self) { code in
                        Text(Recognizer.displayName(forLanguage: code)).tag(code)
                    }
                }
                .disabled(settings.autoDetectLanguage)
                Text("Set Japanese, Chinese or Korean as the primary language to read vertical text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Layout") {
                Toggle("Keep line breaks", isOn: $settings.keepLineBreaks)
                Toggle("Keep indentation", isOn: $settings.preserveIndentation)
                    .disabled(!settings.keepLineBreaks)
                Toggle("Sharpen small selections before reading", isOn: $settings.upscaleSmallSelections)
                Text("Turning off line breaks reflows each paragraph into one line and rejoins words split by a hyphen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom words") {
                Text("Words listed here win over the standard lexicon. Useful for jargon, product names and medical or technical terms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Add a word", text: $newWord)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if settings.customWords.isEmpty {
                    Text("No custom words yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    List {
                        ForEach(settings.customWords, id: \.self) { word in
                            HStack {
                                Text(word)
                                Spacer()
                                Button {
                                    settings.customWords.removeAll { $0 == word }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(height: 110)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            languages = Recognizer.supportedLanguages()
            if !languages.contains(settings.primaryLanguage), let first = languages.first {
                settings.primaryLanguage = first
            }
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !settings.customWords.contains(word) else { return }
        settings.customWords.append(word)
        newWord = ""
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(HotKeyAction.allCases.enumerated()), id: \.element) { index, action in
                        HStack {
                            Text(action.title)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            ShortcutRecorder(action: action, settings: settings)
                                .frame(width: 132, height: 24)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .background(index.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color.primary.opacity(0.035))
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1))

            HStack {
                Text("Click a field, press the keys. Delete clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { settings.resetShortcuts() }
            }
            .padding(.top, 10)

            Text("While a capture is active: \u{2318}L line breaks, \u{2318}H additive clipboard, \u{2318}S speech, esc to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }
}

// MARK: - Clipboard

private struct ClipboardPane: View {
    @ObservedObject var settings: AppSettings
    @State private var entries: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Additive clipboard", isOn: $settings.additiveClipboard)
                .onChange(of: settings.additiveClipboard) { _ in
                    AdditiveClipboard.shared.updatePasteMonitor()
                }
            Text("Each capture is appended instead of replacing the last one, so a single paste gives you everything collected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Clear it after you paste", isOn: $settings.clearAdditiveOnPaste)
                .disabled(!settings.additiveClipboard)
                .onChange(of: settings.clearAdditiveOnPaste) { newValue in
                    if newValue && !SystemServices.hasAccessibilityAccess() {
                        SystemServices.requestAccessibilityAccess()
                    }
                    AdditiveClipboard.shared.updatePasteMonitor()
                }
            if settings.clearAdditiveOnPaste && !SystemServices.hasAccessibilityAccess() {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Detecting \u{2318}V needs Accessibility access.")
                        .font(.caption)
                    Button("Open Settings") { SystemServices.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Text("Collected captures").font(.headline)
                Spacer()
                Text("\(entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if entries.isEmpty {
                VStack {
                    Spacer()
                    Text("Nothing collected yet.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(entry)
                                .font(.callout)
                                .lineLimit(3)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Clear") { AdditiveClipboard.shared.clear() }
                    .disabled(entries.isEmpty)
            }
        }
        .onAppear { entries = AdditiveClipboard.shared.entries }
        .onReceive(NotificationCenter.default.publisher(for: .additiveClipboardChanged)) { _ in
            entries = AdditiveClipboard.shared.entries
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "text.viewfinder")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("TextSnap").font(.title2.weight(.semibold))
            Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
            Text("Select any part of the screen and the text inside it lands on your clipboard. Recognition runs on-device through Apple's Vision framework; nothing leaves the Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
