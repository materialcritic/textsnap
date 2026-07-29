import AppKit
import AVFoundation
import NaturalLanguage

// MARK: - Success HUD

/// A small floating confirmation. Used instead of a system notification so it works
/// without notification authorization and stays out of Notification Centre history.
@MainActor
final class SuccessHUD {
    static let shared = SuccessHUD()

    private var window: NSWindow?
    /// Bumped on every show so a stale dismissal cannot close a newer HUD.
    private var generation = 0

    private init() {}

    /// `force` shows the HUD even when success popups are switched off, so failures
    /// never fail silently.
    func show(title: String, subtitle: String?, force: Bool = false) {
        guard force || AppSettings.shared.showSuccessPopup else { return }
        generation += 1
        let token = generation
        window?.orderOut(nil)

        let content = buildContent(title: title, subtitle: subtitle)
        let size = content.frame.size

        // Show it where the user is looking: the display under the pointer.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.visibleFrame.minY + 96,
                           width: size.width,
                           height: size.height)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        window = panel
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, self.generation == token else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
        self.window = nil
    }

    private func buildContent(title: String, subtitle: String?) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center

        var labels: [NSView] = [titleLabel]
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.alignment = .center
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.maximumNumberOfLines = 1
            subtitleLabel.preferredMaxLayoutWidth = 320
            labels.append(subtitleLabel)
        }

        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)

        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        let fitted = stack.fittingSize
        effect.frame = NSRect(origin: .zero,
                              size: NSSize(width: max(fitted.width, 190),
                                           height: max(fitted.height, 44)))
        return effect
    }
}

// MARK: - Sound

@MainActor
enum CaptureSound {
    /// Alert sounds shipped with macOS, offered in Settings.
    static let available = ["Pop", "Tink", "Glass", "Morse", "Purr", "Submarine", "Bottle", "Frog"]

    static func play() {
        guard AppSettings.shared.playSound else { return }
        NSSound(named: NSSound.Name(AppSettings.shared.soundName))?.play()
    }

    static func preview(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}

// MARK: - Speech

@MainActor
final class Speaker: NSObject {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()

        let utterance = AVSpeechUtterance(string: trimmed)
        // Map the 0...1 preference onto AVSpeechUtterance's min...max range.
        let range = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + range * Float(AppSettings.shared.speechRate)

        if let language = detectLanguage(of: trimmed),
           let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func detectLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

// MARK: - Links

@MainActor
enum LinkOpener {
    /// Opens the payload when it is a single URL and the preference is on.
    static func openIfSingleURL(_ text: String) {
        guard AppSettings.shared.openCapturedLinks else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { return }

        var candidate = trimmed
        if !candidate.lowercased().hasPrefix("http"),
           candidate.lowercased().hasPrefix("www.") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme),
              url.host != nil || scheme == "mailto"
        else { return }

        NSWorkspace.shared.open(url)
    }
}
