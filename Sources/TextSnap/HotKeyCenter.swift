import AppKit
import Carbon

/// Registers system-wide hotkeys through Carbon's `RegisterEventHotKey`.
///
/// This is deliberately not an `NSEvent` global monitor: Carbon hotkeys need no
/// Accessibility permission and are delivered even while another app is frontmost.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Invoked on the main actor when a registered shortcut fires.
    var handler: (@MainActor @Sendable (HotKeyAction) -> Void)?

    private var registered: [UInt32: (ref: EventHotKeyRef, action: HotKeyAction)] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x54534E50 // 'TSNP'

    private init() {}

    @MainActor
    func start() {
        installHandlerIfNeeded()
        reload(from: AppSettings.shared.shortcuts)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.dispatch(id: id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    private func dispatch(id: UInt32) {
        guard let entry = registered[id] else { return }
        let action = entry.action
        let handler = self.handler
        Task { @MainActor in handler?(action) }
    }

    /// Tears down every registration and re-registers from the given map.
    func reload(from shortcuts: [HotKeyAction: KeyCombo]) {
        installHandlerIfNeeded()
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
        for (action, combo) in shortcuts { register(combo, for: action) }
    }

    @discardableResult
    private func register(_ combo: KeyCombo, for action: HotKeyAction) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(UInt32(combo.keyCode),
                                        KeyCodes.carbonModifiers(combo.flags),
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &ref)
        guard status == noErr, let ref else {
            NSLog("TextSnap: could not register \(combo.displayString) for \(action.rawValue) (status \(status)); it is probably taken by another app")
            return false
        }
        registered[id] = (ref, action)
        return true
    }

    func stop() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
