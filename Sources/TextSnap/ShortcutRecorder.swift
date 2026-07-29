import AppKit
import Carbon
import SwiftUI

/// Click to record, then press a combination. Escape cancels, Delete clears.
@MainActor
final class ShortcutRecorderView: NSView {

    var onChange: (@MainActor (KeyCombo?) -> Void)?

    var combo: KeyCombo? {
        didSet { needsDisplay = true }
    }

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    private var pendingModifiers: NSEvent.ModifierFlags = [] {
        didSet { if isRecording { needsDisplay = true } }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 24) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        pendingModifiers = []
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        pendingModifiers = []
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: Key capture

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        pendingModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        if !handle(event) { NSSound.beep() }
    }

    /// Modifier combinations arrive here before `keyDown`, so intercept them too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return handle(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch Int(event.keyCode) {
        case kVK_Escape:
            window?.makeFirstResponder(nil)
            return true
        case kVK_Delete, kVK_ForwardDelete:
            combo = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return true
        default:
            break
        }

        guard KeyCodes.isAcceptable(keyCode: event.keyCode, flags: flags) else { return false }

        let recorded = KeyCombo(keyCode: event.keyCode, modifiers: flags.rawValue)
        combo = recorded
        onChange?(recorded)
        window?.makeFirstResponder(nil)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor
                     : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor

        if isRecording {
            let modifiers = KeyCodes.modifierString(pendingModifiers)
            text = modifiers.isEmpty ? "Press keys\u{2026}" : modifiers
            color = .controlAccentColor
        } else if let combo {
            text = combo.displayString
            color = .labelColor
        } else {
            text = "Not set"
            color = .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                            y: bounds.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

// MARK: - SwiftUI bridge

struct ShortcutRecorder: NSViewRepresentable {
    let action: HotKeyAction
    @ObservedObject var settings: AppSettings

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.combo = settings.shortcuts[action]
        view.onChange = { combo in
            settings.setShortcut(combo, for: action)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        let current = settings.shortcuts[action]
        if nsView.combo != current { nsView.combo = current }
    }
}
