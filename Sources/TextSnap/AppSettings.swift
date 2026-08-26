import AppKit
import Carbon
import Combine
import Security

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

enum TranslationProvider: String, CaseIterable, Hashable {
    case myMemory
    case deepL

    var title: String {
        switch self {
        case .myMemory: return "MyMemory (free, no signup)"
        case .deepL:    return "DeepL (higher limits, needs an API key)"
        }
    }
}

/// Minimal Keychain wrapper. Used only for the DeepL API key, which is a real credential
/// unlike the rest of AppSettings' preferences — those are fine in plain UserDefaults,
/// but a plist on disk is not where a secret belongs.
enum KeychainStore {
    private static let service = "com.textsnap.deepl"
    private static let account = "apiKey"

    static func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
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
    @Published var translationProvider: TranslationProvider {
        didSet {
            store.set(translationProvider.rawValue, forKey: "translationProvider")
            let validTargets = TranslationLanguages.targets(for: translationProvider)
            if !validTargets.contains(translationTargetLanguage) {
                translationTargetLanguage = validTargets.first ?? "en"
            }
        }
    }
    @Published var translationTargetLanguage: String { didSet { store.set(translationTargetLanguage, forKey: "translationTargetLanguage") } }
    /// Optional; passed to MyMemory's API to raise the free daily quota. Never required.
    @Published var myMemoryContactEmail: String { didSet { store.set(myMemoryContactEmail, forKey: "myMemoryContactEmail") } }
    /// Stored in the Keychain, not UserDefaults — see `KeychainStore`.
    @Published var deepLAPIKey: String { didSet { KeychainStore.save(deepLAPIKey) } }

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
            "translationProvider": TranslationProvider.myMemory.rawValue,
            "translationTargetLanguage": "en",
            "myMemoryContactEmail": "",
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
        translationProvider = TranslationProvider(rawValue: store.string(forKey: "translationProvider") ?? "") ?? .myMemory
        translationTargetLanguage = store.string(forKey: "translationTargetLanguage") ?? "en"
        myMemoryContactEmail = store.string(forKey: "myMemoryContactEmail") ?? ""
        deepLAPIKey = KeychainStore.load()

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
