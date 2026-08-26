import AppKit
import Carbon

// MARK: - Window

/// Borderless, transparent, above everything (including full-screen apps and the menu bar).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
}

// MARK: - View

final class OverlayView: NSView {
    weak var controller: OverlayController?

    /// Selection in global Cocoa coordinates; nil until the drag starts.
    var globalSelection: CGRect? { didSet { needsDisplay = true } }
    /// Pointer in global Cocoa coordinates, used for the crosshair guides.
    var globalPointer: CGPoint? { didSet { if globalSelection == nil { needsDisplay = true } } }
    var hintText: String = "" { didSet { needsDisplay = true } }

    private let accent = NSColor(srgbRed: 0.949, green: 0.702, blue: 0.239, alpha: 1)

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Coordinate conversion

    private func toLocal(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return convert(window.convertPoint(fromScreen: point), from: nil)
    }

    private func toLocal(_ rect: CGRect) -> CGRect {
        let a = toLocal(rect.origin)
        let b = toLocal(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let selection = globalSelection.map(toLocal)

        // Dim everything except the selection.
        let dim = NSBezierPath(rect: bounds)
        if let selection, selection.width > 0, selection.height > 0 {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor(white: 0, alpha: 0.42).setFill()
        dim.fill()

        if let selection, selection.width > 0, selection.height > 0 {
            drawSelection(selection)
        } else if let pointer = globalPointer {
            drawGuides(at: toLocal(pointer))
        }

        drawHintBar()
    }

    private func drawSelection(_ rect: CGRect) {
        accent.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        // Corner ticks.
        let arm: CGFloat = min(14, min(rect.width, rect.height) / 3)
        if arm > 3 {
            let ticks = NSBezierPath()
            ticks.lineWidth = 2.5
            let corners: [(CGPoint, CGFloat, CGFloat)] = [
                (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
                (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
                (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
            ]
            for (corner, dx, dy) in corners {
                ticks.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                ticks.line(to: corner)
                ticks.line(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            }
            ticks.stroke()
        }

        drawBadge("\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))",
                  near: rect)
    }

    private func drawGuides(at point: CGPoint) {
        NSColor(white: 1, alpha: 0.35).setStroke()
        let guides = NSBezierPath()
        guides.lineWidth = 1
        guides.move(to: CGPoint(x: bounds.minX, y: point.y.rounded() + 0.5))
        guides.line(to: CGPoint(x: bounds.maxX, y: point.y.rounded() + 0.5))
        guides.move(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.minY))
        guides.line(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.maxY))
        guides.stroke()
    }

    private func drawBadge(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height + padding * 2 > bounds.maxY {
            origin.y = rect.minY - size.height - padding * 2 - 6
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - padding * 2 - 4)

        let box = CGRect(x: origin.x, y: origin.y,
                         width: size.width + padding * 2,
                         height: size.height + padding)
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2),
                                withAttributes: attributes)
    }

    private func drawHintBar() {
        guard !hintText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.92)
        ]
        let size = (hintText as NSString).size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 14,
                         y: bounds.minY + 48,
                         width: size.width + 28,
                         height: size.height + 14)
        NSColor(white: 0.05, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (hintText as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7),
                                    withAttributes: attributes)
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) { controller?.dragBegan() }
    override func mouseDragged(with event: NSEvent) { controller?.dragMoved() }
    override func mouseUp(with event: NSEvent) { controller?.dragEnded() }
    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved()
        NSCursor.crosshair.set()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            controller?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    /// ⌘L / ⌘H / ⌘S flip options mid-capture, matching the in-capture toggles.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        switch key {
        case "l": controller?.toggle(.lineBreaks);   return true
        case "h": controller?.toggle(.additive);     return true
        case "s": controller?.toggle(.speech);       return true
        case "t": controller?.toggle(.translation);  return true
        case ".": controller?.cancel();              return true
        default:  return false
        }
    }
}

// MARK: - Controller

@MainActor
final class OverlayController {

    enum Toggle { case lineBreaks, additive, speech, translation }

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var anchor: CGPoint?
    private var completion: (@MainActor (CGRect?) -> Void)?
    private var previousApp: NSRunningApplication?
    private var isActive = false

    private let settings = AppSettings.shared

    /// Presents the overlay. `completion` receives the selection in global Cocoa
    /// coordinates, or nil if the user cancelled.
    func begin(completion: @escaping @MainActor (CGRect?) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.completion = completion
        self.anchor = nil
        previousApp = NSWorkspace.shared.frontmostApplication

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.controller = self
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)

        // The window under the pointer takes key status, and its view becomes first
        // responder so Escape and the mouse-moved events actually arrive.
        let pointer = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(pointer) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.contentView)

        refreshHint()
        pointerMoved()
    }

    // MARK: Drag

    func dragBegan() {
        anchor = NSEvent.mouseLocation
        publish(selection: .zero)
    }

    func dragMoved() {
        guard let anchor else { return }
        publish(selection: rect(from: anchor, to: NSEvent.mouseLocation))
    }

    func pointerMoved() {
        let location = NSEvent.mouseLocation
        for view in views { view.globalPointer = location }
    }

    func dragEnded() {
        guard let anchor else { finish(nil); return }
        let selection = rect(from: anchor, to: NSEvent.mouseLocation)
        // A stray click, not a drag.
        guard selection.width >= 4, selection.height >= 4 else { finish(nil); return }
        finish(selection)
    }

    func cancel() { finish(nil) }

    // MARK: Toggles

    func toggle(_ option: Toggle) {
        switch option {
        case .lineBreaks:  settings.keepLineBreaks.toggle()
        case .additive:    settings.additiveClipboard.toggle()
        case .speech:      settings.textToSpeech.toggle()
        case .translation: settings.translateCapturedText.toggle()
        }
        refreshHint()
    }

    private func refreshHint() {
        func mark(_ on: Bool) -> String { on ? "on" : "off" }
        let hint = [
            "drag to select",
            "\u{2318}L line breaks \(mark(settings.keepLineBreaks))",
            "\u{2318}H additive \(mark(settings.additiveClipboard))",
            "\u{2318}S speak \(mark(settings.textToSpeech))",
            "\u{2318}T translate \(mark(settings.translateCapturedText))",
            "esc cancel"
        ].joined(separator: "   \u{00B7}   ")
        for view in views { view.hintText = hint }
    }

    // MARK: Plumbing

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func publish(selection: CGRect) {
        for view in views { view.globalSelection = selection }
    }

    private func finish(_ selection: CGRect?) {
        guard isActive else { return }
        isActive = false

        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        anchor = nil
        NSCursor.arrow.set()

        // Hand focus back so the user's paste target is still frontmost.
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            _ = previousApp.activate(options: [])
        } else {
            NSApp.hide(nil)
        }
        previousApp = nil

        let callback = completion
        completion = nil
        // Let the compositor drop the overlay before the screen is read.
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            callback?(selection)
        }
    }
}
