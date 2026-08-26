# TextSnap

A menu bar OCR utility for macOS. Press a shortcut, drag a rectangle over anything on
screen — a video, a PDF, a photo, a terminal you can't select text in — and the text
inside it is recognized and copied to the clipboard, ready to paste. Recognition runs
entirely on-device through Apple's Vision framework, so no screenshot or text ever
leaves the machine.

Beyond plain text capture, it can read QR codes and barcodes, stack multiple captures
into one growing clipboard payload, translate captured text, speak the captured text
aloud, and run OCR against existing images, PDFs, or whatever is already sitting on the
clipboard.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode or the Xcode Command Line Tools (for `swift build`)

## Build

```bash
chmod +x build.sh
./build.sh --install --run
```

This compiles a universal (arm64 + x86_64) release binary, wraps it in `TextSnap.app`,
generates the app icon from `Resources/AppIcon.iconset`, ad-hoc signs the bundle, copies
it to `/Applications`, and launches it.

Other options:

```bash
./build.sh              # build into ./dist only, don't install or run
./build.sh --debug      # faster build, current architecture only
./build.sh --native     # release build, current architecture only (no universal binary)
./build.sh --install    # build and copy to /Applications, don't launch
./build.sh --run        # build and launch, don't install
```

To sign with a real Developer ID certificate instead of an ad-hoc signature (recommended
— see *Permissions* below):

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TEXTSNAP_BUNDLE_ID="com.yourname.textsnap" ./build.sh --install
```

Prefer working in Xcode? `open Package.swift`, set the run destination to *My Mac*, and
build from there. You still need `build.sh` at least once to produce a proper `.app`
bundle — a bare SwiftPM executable has no `Info.plist` and can't run as a menu bar
(`LSUIElement`) app or hold Screen Recording permission.

## Permissions

**Screen Recording is required.** Reading pixels off the screen is gated behind this
permission on modern macOS. TextSnap requests it on first launch; if you miss the
system prompt, grant it manually: System Settings → Privacy & Security → Screen &
System Audio Recording → enable TextSnap → quit and reopen the app.

macOS ties that grant to the app's code signature. With the default ad-hoc signature,
the signature changes on every rebuild, so **you'll need to re-grant the permission
after each build** — sometimes toggling it off and back on is needed if the switch
already looks enabled but the grant is stale. Signing with a real Developer ID
certificate (see above) keeps the signature stable across builds so the grant sticks.

**Accessibility is optional.** It's only used for *Clear the additive clipboard after
you paste*, which watches system-wide for ⌘V. Every other feature works without it.

## Using it

| Shortcut | Action |
|---|---|
| ⌘K | Capture text |
| ⌘⇧3 | Capture QR code or barcode |
| Right-click the menu bar icon | Capture text immediately |
| Left-click the menu bar icon | Open the menu |

While a capture is active (the dimmed selection overlay is on screen):

| Key | Action |
|---|---|
| Drag | Select a region; live pixel dimensions are shown next to it |
| Click without dragging | Cancelled — a stray click is not treated as a selection |
| ⌘L | Toggle "keep line breaks" for this capture |
| ⌘H | Toggle the additive clipboard |
| ⌘S | Toggle text-to-speech |
| ⌘T | Toggle translation |
| esc / ⌘. | Cancel the capture |

Every action is remappable in Settings → Shortcuts, including several that are
unassigned by default:

- Capture Text (keep line breaks) / Capture Text (as paragraph) — force the line-break
  preference for a single capture, instead of following the standing setting
- Capture Text and Speak
- Capture Previous Selection — re-reads the last rectangle you selected, useful for
  reading the same region repeatedly (subtitles, a counter, a log tail)
- Toggle Additive Clipboard / Clear Additive Clipboard
- Toggle Translation
- Stop Speaking

## What's implemented

**Capture.** Drag-select across any display, with the rest of the screen dimmed,
crosshair guides before you start dragging, live pixel dimensions once you do, and a
hint bar showing the current toggle states. A selection spanning two monitors clamps to
whichever display holds the larger share of it.

**Recognition.** Vision's `.accurate` recognition level, with automatic language
detection or an explicit primary language. A custom-words list takes precedence over
the standard lexicon, which helps with jargon, product names, and technical terms.
Selections shorter than 160px are upscaled with a Lanczos filter first, which noticeably
improves results on small type. Setting Japanese, Chinese, or Korean as the primary
language enables reading vertical text.

**Layout reconstruction.** Vision returns recognized text fragments in no particular
order, so `TextAssembler` rebuilds reading order from each fragment's bounding box:
fragments are grouped into visual lines by vertical overlap, lines are sorted top to
bottom, and paragraph breaks are inferred from vertical gaps between lines. A wide
horizontal gap inside a line becomes a tab rather than a space, which keeps tables and
aligned code readable. With "keep line breaks" off, each paragraph is reflowed onto a
single line, and words split across a line break by a hyphen are rejoined.

**Codes.** QR codes and every barcode symbology Vision supports, read top-left to
bottom-right. Multiple codes inside one selection come back as separate lines in the
same paste.

**Additive clipboard.** Normally each capture replaces the clipboard. With the additive
clipboard on, captures instead stack into one growing payload, so a single paste yields
everything you've collected so far — useful for pulling scattered lines into one place.
It persists across app restarts, is viewable and clearable from Settings → Clipboard,
and can be configured to auto-clear itself right after you paste.

**Translation.** Off by default; turn it on in Settings → Recognition or with ⌘T during
a capture. When enabled, a captured text is translated instead of going straight to the
clipboard: the source language is detected on-device (via `NLLanguageRecognizer`), the
text is sent to a translation provider and translated into whichever target language
you've picked in Settings, and both the original and the translation are shown in a
resizable popup. The translation (not the original) is what lands on the clipboard once
it's ready. Unlike every other feature in this app, translation is **not** fully
on-device — the captured text is sent to a third-party API, so don't turn it on for
anything sensitive. Two providers are available, switchable in Settings:

- **[MyMemory](https://mymemory.translated.net)** — free, no signup or API key. Rate-limited to
  roughly 5,000 words/day per IP (an optional contact email in Settings raises that to
  about 50,000/day), and rejects any single capture over 500 characters outright.
- **[DeepL](https://deepl.com/pro-api)** — needs a free API key from DeepL (Account → API Keys
  after signing up for the API Free plan), which TextSnap stores in the Keychain, not in
  its preferences file. Free tier covers 500,000 characters/month with a far higher
  per-request limit than MyMemory, and generally better translation quality, at the cost
  of requiring an account.

**Speech.** Speaks the captured text with an adjustable rate, using a system voice
matched to the text's detected language. Has its own capture-and-speak shortcut and a
dedicated stop-speaking shortcut. When translation is on, it speaks the translated text.

**Also.** An optional capture sound (choice of several system sounds), a small
confirmation HUD after each capture, automatic opening of a captured link when the
capture is a single URL, launch at login, an optionally hidden menu bar icon, and OCR of
existing content: *Read Text from File…* handles both images and PDFs (each PDF page is
rendered at 2x before OCR, so scanned documents work), *Read Text from Clipboard Image*
reads whatever image you last copied, and dropping a file onto the app does the same.

## Project layout

| File | Role |
|---|---|
| `Launch.swift` | `@main` entry point, sets the accessory (menu bar only) activation policy |
| `AppDelegate.swift` | Menu bar item, dynamic menu construction, first-run onboarding |
| `AppSettings.swift` | Observable preference store backed by `UserDefaults` |
| `HotKeyCenter.swift` | Global shortcuts via Carbon's `RegisterEventHotKey` |
| `KeyCodes.swift` | Key code ↔ glyph tables, aware of the live keyboard layout |
| `ShortcutRecorder.swift` | Key-capture control bridged into SwiftUI for the Shortcuts pane |
| `Overlay.swift` | Selection windows: drawing, dragging, and in-capture key handling |
| `ScreenCapture.swift` | ScreenCaptureKit capture, cropping, and upscaling |
| `Recognizer.swift` | Vision text-recognition and barcode-detection requests |
| `TextAssembler.swift` | Reading-order and paragraph reconstruction from Vision output |
| `CaptureCoordinator.swift` | Orchestration: overlay → capture → OCR → clipboard delivery |
| `AdditiveClipboard.swift` | Accumulating capture buffer with disk persistence |
| `Translator.swift` | On-device language detection, MyMemory translation client, and its popup |
| `Feedback.swift` | Confirmation HUD, capture sound, speech, link opening |
| `SystemServices.swift` | Permission checks and the login-item toggle |
| `SettingsWindow.swift` | SwiftUI settings window and its panes |

Two design notes worth knowing before modifying this:

**Global shortcuts use Carbon, not an `NSEvent` monitor.** `RegisterEventHotKey` needs
no Accessibility permission and fires even while another app is frontmost. An `NSEvent`
global monitor would require Accessibility just for the app's core capture shortcut,
which is a much worse first-run experience than needing it only for the optional
clear-on-paste feature.

**OCR runs off the main thread.** `Recognizer` takes an immutable `RecognitionOptions`
snapshot rather than reading `AppSettings` directly, which keeps it free of main-actor
isolation so `Task.detached` can run it in the background. That matters most for
multi-page PDFs, where main-thread OCR would freeze the UI for several seconds.

## Known limits

- A selection is captured from a single display; dragging across a monitor bezel clamps
  to one screen, since text split across two physical panels isn't useful anyway.
- Launch at login uses `SMAppService`, which expects a signed app living in
  `/Applications`. It can silently fail for an ad-hoc build run straight out of `dist/`.
- The overlay is hidden for roughly 60ms before the screen is read so the dimming
  overlay doesn't end up baked into the captured image. On a heavily loaded machine a
  faint tint can occasionally survive into the capture.
- Vision handles ordinary prose well but misreads dense symbolic content, so source code
  and mathematical notation should be proofread after capture.
- Continuity Camera import (capturing directly from a paired iPhone's camera) isn't
  implemented. *Read Text from File…* covers the same ground for anything already saved
  to disk.
- Translation sends captured text to MyMemory's servers rather than staying on-device,
  needs a network connection, and is subject to MyMemory's free-tier rate limit. Only
  text captures are translated; QR/barcode captures never are.
