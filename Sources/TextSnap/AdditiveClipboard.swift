import AppKit
import Carbon

/// Accumulates successive captures into one growing clipboard payload.
///
/// When enabled, each capture is appended and the whole buffer is written to the
/// pasteboard, so one paste yields everything collected so far.
@MainActor
final class AdditiveClipboard {
    static let shared = AdditiveClipboard()

    private(set) var entries: [String] = []
    private var pasteMonitor: Any?
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("additive-clipboard.json")
        load()
    }

    var joined: String { entries.joined(separator: "\n") }
    var isEmpty: Bool { entries.isEmpty }

    /// Appends and returns the payload that should go on the pasteboard.
    func append(_ text: String) -> String {
        entries.append(text)
        save()
        NotificationCenter.default.post(name: .additiveClipboardChanged, object: nil)
        return joined
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
        NotificationCenter.default.post(name: .additiveClipboardChanged, object: nil)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Clear on ⌘V

    /// Watching for ⌘V anywhere needs Accessibility access; without it we quietly
    /// skip the feature rather than nagging on every launch.
    func updatePasteMonitor() {
        let wanted = AppSettings.shared.additiveClipboard && AppSettings.shared.clearAdditiveOnPaste

        if !wanted {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
            return
        }

        guard pasteMonitor == nil, SystemServices.hasAccessibilityAccess() else { return }

        pasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == UInt16(kVK_ANSI_V),
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            else { return }
            // Let the paste land before emptying the buffer.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                AdditiveClipboard.shared.clear()
            }
        }
    }
}
