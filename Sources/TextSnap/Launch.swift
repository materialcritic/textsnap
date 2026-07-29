import AppKit

/// `@main` with a main-actor entry point, so the delegate and every AppKit object
/// below it are created with the isolation the SDK expects.
@main
struct TextSnapMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // Held for the lifetime of `main()`; NSApplication holds its delegate weakly.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
