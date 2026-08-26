import AppKit
import Carbon
import Combine

/// A recorded global shortcut. `modifiers` stores `NSEvent.ModifierFlags.rawValue`.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask)
    }

    var displayString: String {
        KeyCodes.modifierString(flags) + KeyCodes.name(for: keyCode)
    }
}

enum HotKeyAction: String, CaseIterable, Codable {
    case captureText
    case captureKeepingLineBreaks
    case captureStrippingLineBreaks
    case captureWithSpeech
    case captureBarcode
    case capturePreviousSelection
    case toggleAdditiveClipboard
    case clearAdditiveClipboard
    case toggleTranslation
    case stopSpeaking

    var title: String {
        switch self {
        case .captureText:                return "Capture Text"
        case .captureKeepingLineBreaks:   return "Capture Text (keep line breaks)"
        case .captureStrippingLineBreaks: return "Capture Text (as paragraph)"
        case .captureWithSpeech:          return "Capture Text and Speak"
        case .captureBarcode:             return "Capture QR / Barcode"
        case .capturePreviousSelection:   return "Capture Previous Selection"
        case .toggleAdditiveClipboard:    return "Toggle Additive Clipboard"
        case .clearAdditiveClipboard:     return "Clear Additive Clipboard"
        case .toggleTranslation:          return "Toggle Translation"
        case .stopSpeaking:               return "Stop Speaking"
        }
    }
}

/// Single source of truth for preferences. Observable so the SwiftUI settings window stays in sync.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let store = UserDefaults.standard

    // MARK: Recognition

    @Published var keepLineBreaks: Bool { didSet { store.set(keepLineBreaks, forKey: "keepLineBreaks") } }
    @Published var autoDetectLanguage: Bool { didSet { store.set(autoDetectLanguage, forKey: "autoDetectLanguage") } }
    @Published var primaryLanguage: String { didSet { store.set(primaryLanguage, forKey: "primaryLanguage") } }
    @Published var customWords: [String] { didSet { store.set(customWords, forKey: "customWords") } }
    @Published var upscaleSmallSelections: Bool { didSet { store.set(upscaleSmallSelections, forKey: "upscaleSmallSelections") } }
    @Published var preserveIndentation: Bool { didSet { store.set(preserveIndentation, forKey: "preserveIndentation") } }

    // MARK: Behavior

    @Published var additiveClipboard: Bool { didSet { store.set(additiveClipboard, forKey: "additiveClipboard") } }
    @Published var clearAdditiveOnPaste: Bool { didSet { store.set(clearAdditiveOnPaste, forKey: "clearAdditiveOnPaste") } }
    @Published var textToSpeech: Bool { didSet { store.set(textToSpeech, forKey: "textToSpeech") } }
    @Published var speechRate: Double { didSet { store.set(speechRate, forKey: "speechRate") } }
    @Published var openCapturedLinks: Bool { didSet { store.set(openCapturedLinks, forKey: "openCapturedLinks") } }

    // MARK: Translation

    @Published var translateCapturedText: Bool { didSet { store.set(translateCapturedText, forKey: "translateCapturedText") } }
    @Published var translationTargetLanguage: String { didSet { store.set(translationTargetLanguage, forKey: "translationTargetLanguage") } }

    // MARK: Feedback

    @Published var playSound: Bool { didSet { store.set(playSound, forKey: "playSound") } }
    @Published var soundName: String { didSet { store.set(soundName, forKey: "soundName") } }
    @Published var showSuccessPopup: Bool { didSet { store.set(showSuccessPopup, forKey: "showSuccessPopup") } }
    @Published var showMenuBarIcon: Bool {
        didSet {
            store.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
        }
    }

    // MARK: Shortcuts

    @Published private(set) var shortcuts: [HotKeyAction: KeyCombo] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(raw) { store.set(data, forKey: "shortcuts") }
        }
    }

    static let defaultShortcuts: [HotKeyAction: KeyCombo] = [
        .captureText: KeyCombo(keyCode: UInt16(kVK_ANSI_K),
                               modifiers: NSEvent.ModifierFlags([.command]).rawValue),
        .captureBarcode: KeyCombo(keyCode: UInt16(kVK_ANSI_3),
                                  modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    ]

    private init() {
        store.register(defaults: [
            "keepLineBreaks": true,
            "autoDetectLanguage": true,
            "primaryLanguage": "en-US",
            "upscaleSmallSelections": true,
            "preserveIndentation": false,
            "additiveClipboard": false,
            "clearAdditiveOnPaste": false,
            "textToSpeech": false,
            "speechRate": 0.5,
            "openCapturedLinks": false,
            "translateCapturedText": false,
            "translationTargetLanguage": "en",
            "playSound": true,
            "soundName": "Pop",
            "showSuccessPopup": true,
            "showMenuBarIcon": true
        ])

        keepLineBreaks = store.bool(forKey: "keepLineBreaks")
        autoDetectLanguage = store.bool(forKey: "autoDetectLanguage")
        primaryLanguage = store.string(forKey: "primaryLanguage") ?? "en-US"
        customWords = store.stringArray(forKey: "customWords") ?? []
        upscaleSmallSelections = store.bool(forKey: "upscaleSmallSelections")
        preserveIndentation = store.bool(forKey: "preserveIndentation")

        additiveClipboard = store.bool(forKey: "additiveClipboard")
        clearAdditiveOnPaste = store.bool(forKey: "clearAdditiveOnPaste")
        textToSpeech = store.bool(forKey: "textToSpeech")
        speechRate = store.double(forKey: "speechRate")
        openCapturedLinks = store.bool(forKey: "openCapturedLinks")

        translateCapturedText = store.bool(forKey: "translateCapturedText")
        translationTargetLanguage = store.string(forKey: "translationTargetLanguage") ?? "en"

        playSound = store.bool(forKey: "playSound")
        soundName = store.string(forKey: "soundName") ?? "Pop"
        showSuccessPopup = store.bool(forKey: "showSuccessPopup")
        showMenuBarIcon = store.bool(forKey: "showMenuBarIcon")

        if let data = store.data(forKey: "shortcuts"),
           let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            var parsed: [HotKeyAction: KeyCombo] = [:]
            for (key, combo) in raw {
                if let action = HotKeyAction(rawValue: key) { parsed[action] = combo }
            }
            shortcuts = parsed
        } else {
            shortcuts = Self.defaultShortcuts
        }
    }

    // MARK: Shortcut mutation

    func setShortcut(_ combo: KeyCombo?, for action: HotKeyAction) {
        var next = shortcuts
        if let combo {
            // A combo can only drive one action at a time.
            for (other, existing) in next where other != action && existing == combo {
                next[other] = nil
            }
            next[action] = combo
        } else {
            next[action] = nil
        }
        shortcuts = next
        HotKeyCenter.shared.reload(from: next)
    }

    func resetShortcuts() {
        shortcuts = Self.defaultShortcuts
        HotKeyCenter.shared.reload(from: shortcuts)
    }
}

extension Notification.Name {
    static let menuBarVisibilityChanged = Notification.Name("TextSnap.menuBarVisibilityChanged")
    static let additiveClipboardChanged = Notification.Name("TextSnap.additiveClipboardChanged")
}
