import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private let settings = AppSettings.shared

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyCenter.shared.handler = { action in
            CaptureCoordinator.shared.perform(action)
        }
        HotKeyCenter.shared.start()

        AdditiveClipboard.shared.updatePasteMonitor()
        rebuildStatusItem()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(rebuildStatusItem),
                                               name: .menuBarVisibilityChanged,
                                               object: nil)

        runFirstLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.stop()
    }

    /// Reopening the app from Finder brings up Settings rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            CaptureCoordinator.shared.recognize(fileAt: url)
        }
    }

    private func runFirstLaunchIfNeeded() {
        let key = "hasCompletedFirstLaunch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        SystemServices.requestScreenRecordingAccess()

        let alert = NSAlert()
        alert.messageText = "TextSnap is running in the menu bar"
        let shortcut = settings.shortcuts[.captureText]?.displayString ?? "a shortcut you set"
        alert.informativeText = """
        Press \(shortcut) and drag over any text on screen. It is recognized and copied \
        to the clipboard, ready to paste.

        If nothing gets captured, grant Screen Recording access in Privacy & Security, \
        then reopen TextSnap.
        """
        alert.addButton(withTitle: "Got it")
        alert.addButton(withTitle: "Open Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { showSettings() }
    }

    // MARK: Status item

    @objc private func rebuildStatusItem() {
        guard settings.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "text.viewfinder",
                                accessibilityDescription: "TextSnap")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "TextSnap \u{2014} capture text from the screen"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Left click opens the menu; right click fires a capture straight away.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isSecondary = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)

        if isSecondary {
            CaptureCoordinator.shared.beginCapture(kind: .text, lineBreaks: .followPreference)
        } else {
            let menu = buildMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String,
                 _ action: Selector?,
                 key: HotKeyAction? = nil,
                 state: Bool? = nil,
                 enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && action != nil
            if let state { item.state = state ? .on : .off }
            if let key, let combo = settings.shortcuts[key] {
                item.keyEquivalent = keyEquivalentString(for: combo)
                item.keyEquivalentModifierMask = combo.flags
            }
            menu.addItem(item)
        }

        add("Capture Text", #selector(captureText), key: .captureText)
        add("Capture QR / Barcode", #selector(captureBarcode), key: .captureBarcode)
        add("Capture Previous Selection", #selector(capturePrevious),
            key: .capturePreviousSelection,
            enabled: CaptureCoordinator.shared.canRepeatLastSelection)

        menu.addItem(.separator())

        add("Read Text from File\u{2026}", #selector(recognizeFile))
        add("Read Text from Clipboard Image", #selector(recognizeClipboard))

        menu.addItem(.separator())

        add("Keep Line Breaks", #selector(toggleLineBreaks), state: settings.keepLineBreaks)
        add("Additive Clipboard", #selector(toggleAdditive),
            key: .toggleAdditiveClipboard, state: settings.additiveClipboard)
        add("Text to Speech", #selector(toggleSpeech), state: settings.textToSpeech)
        add("Translate Captured Text", #selector(toggleTranslation),
            key: .toggleTranslation, state: settings.translateCapturedText)
        add("Play Capture Sound", #selector(toggleSound), state: settings.playSound)

        let count = AdditiveClipboard.shared.entries.count
        add(count > 0 ? "Clear Additive Clipboard (\(count))" : "Clear Additive Clipboard",
            #selector(clearAdditive),
            key: .clearAdditiveClipboard,
            enabled: count > 0)

        if Speaker.shared.isSpeaking {
            add("Stop Speaking", #selector(stopSpeaking), key: .stopSpeaking)
        }

        menu.addItem(.separator())

        add("Settings\u{2026}", #selector(showSettings))
        add("Quit TextSnap", #selector(quit))

        // Give the last two items their conventional shortcuts.
        if let settingsItem = menu.items.first(where: { $0.title.hasPrefix("Settings") }) {
            settingsItem.keyEquivalent = ","
            settingsItem.keyEquivalentModifierMask = .command
        }
        if let quitItem = menu.items.last {
            quitItem.keyEquivalent = "q"
            quitItem.keyEquivalentModifierMask = .command
        }

        return menu
    }

    /// NSMenuItem wants the literal character, not a virtual key code.
    private func keyEquivalentString(for combo: KeyCombo) -> String {
        let name = KeyCodes.name(for: combo.keyCode)
        guard name.count == 1 else { return "" }
        return name.lowercased()
    }

    // MARK: Actions

    @objc private func captureText() {
        CaptureCoordinator.shared.beginCapture(kind: .text, lineBreaks: .followPreference)
    }

    @objc private func captureBarcode() {
        CaptureCoordinator.shared.beginCapture(kind: .barcode, lineBreaks: .keep)
    }

    @objc private func capturePrevious() {
        CaptureCoordinator.shared.repeatLastSelection()
    }

    @objc private func recognizeFile() {
        CaptureCoordinator.shared.recognizeFromFilePicker()
    }

    @objc private func recognizeClipboard() {
        CaptureCoordinator.shared.recognizeFromClipboard()
    }

    @objc private func toggleLineBreaks() { settings.keepLineBreaks.toggle() }
    @objc private func toggleSpeech() { settings.textToSpeech.toggle() }
    @objc private func toggleSound() { settings.playSound.toggle() }

    @objc private func toggleAdditive() {
        CaptureCoordinator.shared.toggleAdditiveClipboard()
    }

    @objc private func toggleTranslation() {
        CaptureCoordinator.shared.toggleTranslation()
    }

    @objc private func clearAdditive() {
        AdditiveClipboard.shared.clear()
        SuccessHUD.shared.show(title: "Additive clipboard cleared", subtitle: nil, force: true)
    }

    @objc private func stopSpeaking() { Speaker.shared.stop() }

    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.present()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
