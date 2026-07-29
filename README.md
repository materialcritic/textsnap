# TextSnap

A menu bar OCR utility for macOS. Press a shortcut, drag over anything on screen, and the
text inside the selection is recognized and copied to the clipboard. Recognition runs
on-device through Apple's Vision framework, so nothing leaves the machine.

This is a functional rebuild of the TextSniper workflow, written from scratch against the
public macOS frameworks. It uses its own name and its own generated icon rather than
copying anyone's branding or assets.

## Build

Requires macOS 13 or newer and Xcode (or the Command Line Tools).

```bash
chmod +x build.sh
./build.sh --install --run
```

That produces a universal binary, wraps it in `TextSnap.app`, generates the icon,
ad-hoc signs it, copies it to `/Applications` and launches it.

Other options:

```bash
./build.sh              # build into ./dist only
./build.sh --debug      # fast, current architecture only
./build.sh --native     # release build, current architecture only
```

To sign with a real certificate (recommended, see *Permissions* below):

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TEXTSNAP_BUNDLE_ID="com.yourname.textsnap" ./build.sh --install
```

Prefer Xcode? `open Package.swift`, then set the scheme to *My Mac* and build. You still
need `build.sh` to produce the `.app` bundle, because a bare SwiftPM executable has no
`Info.plist` and therefore cannot be a menu bar app.

## Permissions

**Screen Recording is required.** Reading pixels off the screen is gated behind it. On
first launch the app asks; if you miss the prompt, go to System Settings → Privacy &
Security → Screen & System Audio Recording, enable TextSnap, then quit and reopen it.

macOS ties that grant to the app's code signature. With an ad-hoc signature the signature
changes every time you rebuild, so **you will have to re-grant permission after each
build**. Signing with a Developer ID certificate makes the grant stick.

**Accessibility is optional.** It is only needed for *Clear the additive clipboard after
you paste*, which watches for ⌘V system-wide. Everything else works without it.

## Using it

| | |
|---|---|
| ⌘K | Capture text |
| ⌘⇧3 | Capture QR code or barcode |
| Right-click the menu bar icon | Capture text immediately |
| Left-click the menu bar icon | Open the menu |

While a capture is active:

| | |
|---|---|
| Drag | Select a region; the size is shown live |
| ⌘L | Keep line breaks on/off |
| ⌘H | Additive clipboard on/off |
| ⌘S | Text to speech on/off |
| esc | Cancel |

Every shortcut is remappable in Settings → Shortcuts, including ones that are unassigned
by default: capture forcing line breaks on, capture forcing them off, capture and speak,
repeat the previous selection, toggle or clear the additive clipboard, and stop speaking.

## What's implemented

**Capture.** Drag-select across any display, with dimming, crosshair guides, live pixel
dimensions and a hint bar. Selections spanning two monitors clamp to the display holding
most of the selection. Repeat-previous-selection re-reads the same rectangle, which is what
you want for subtitles or a video playing in place.

**Recognition.** Vision `.accurate` level, automatic language detection or an explicit
primary language, and a custom-words list that takes precedence over the standard lexicon
for jargon and product names. Thin selections are upscaled with a Lanczos filter first,
which measurably helps on small type. Set Japanese, Chinese or Korean as the primary
language to read vertical text.

**Layout reconstruction.** Vision returns text fragments in no particular order, so
`TextAssembler` rebuilds reading order from the bounding boxes: fragments are grouped into
visual lines, lines ordered top to bottom, and paragraph breaks inferred from vertical
gaps. Wide horizontal gaps inside a line become tabs, which keeps tables and code readable.
With line breaks off, each paragraph is reflowed onto one line and words split across a
line by a hyphen are rejoined.

**Codes.** QR and every barcode symbology Vision supports, ordered top-left to
bottom-right, with multiple codes in one selection returned as separate lines.

**Additive clipboard.** Captures stack into one growing payload instead of overwriting,
so a single paste yields everything collected. Persists across restarts, viewable and
clearable in Settings → Clipboard, and can auto-clear after you paste.

**Speech.** Speaks the capture with a rate control, using a voice matched to the detected
language. Has its own capture shortcut and a stop shortcut.

**Also.** Optional capture sound with a choice of system sounds, a confirmation HUD,
automatic opening of a captured URL or QR link, launch at login, an optionally hidden menu
bar icon, and OCR of existing files: *Read Text from File…* handles images and PDFs (each
page rendered at 2x, so scanned PDFs work), *Read Text from Clipboard Image* reads whatever
image you last copied, and you can drop a file onto the app.

## Layout

| File | Role |
|---|---|
| `Launch.swift` | `@main` entry point, accessory activation policy |
| `AppDelegate.swift` | Menu bar item, dynamic menu, first-run onboarding |
| `AppSettings.swift` | Observable preference store backed by `UserDefaults` |
| `HotKeyCenter.swift` | Carbon `RegisterEventHotKey` global shortcuts |
| `KeyCodes.swift` | Key code ↔ glyph tables, live keyboard layout aware |
| `ShortcutRecorder.swift` | Key-capture control bridged into SwiftUI |
| `Overlay.swift` | Selection windows, drawing, drag and key handling |
| `ScreenCapture.swift` | ScreenCaptureKit capture, crop, upscale |
| `Recognizer.swift` | Vision text and barcode requests |
| `TextAssembler.swift` | Reading order and paragraph reconstruction |
| `CaptureCoordinator.swift` | Orchestration: overlay → capture → OCR → clipboard |
| `AdditiveClipboard.swift` | Accumulating buffer with persistence |
| `Feedback.swift` | Confirmation HUD, sound, speech, link opening |
| `SystemServices.swift` | Permission checks, login item |
| `SettingsWindow.swift` | SwiftUI settings panes |

Two design notes worth knowing if you plan to modify it.

*Global shortcuts use Carbon, not an `NSEvent` monitor.* `RegisterEventHotKey` needs no
Accessibility permission and fires while another app is frontmost. An `NSEvent` global
monitor would require Accessibility for the app's core function, which is a much worse
first-run experience.

*OCR runs off the main thread.* `Recognizer` takes an immutable `RecognitionOptions`
snapshot instead of reading `AppSettings` directly, which keeps it free of actor isolation
so `Task.detached` can run it. That matters for multi-page PDFs, where main-thread OCR
would freeze the UI for seconds.

## Known limits

- A selection is captured from a single display. Dragging across a monitor bezel clamps to
  one screen, since text split across two panels is not useful anyway.
- Launch at login uses `SMAppService`, which wants a signed app in `/Applications`. It may
  silently fail for an ad-hoc build run from `dist/`.
- The overlay is hidden for 60 ms before the screen is read, so the dimming does not end up
  in the captured image. On a heavily loaded machine a faint tint can survive.
- Vision handles ordinary prose well but misreads dense symbols, so source code and maths
  need a proofread.
- Continuity Camera import ("capture from iPhone") is not implemented. *Read Text from
  File…* covers the same ground for anything already on disk.
