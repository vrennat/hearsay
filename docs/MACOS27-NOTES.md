# macOS 27 features and guidelines: what applies to Hearsay

Researched 2026-10-23. Sources: developer.apple.com/macos/whats-new, the HIG pages (Designing for macOS,
The menu bar, Materials, Toolbars, Typography, Color, Layout, Motion, Icons, SF Symbols) read through
their documentation JSON (the HTML pages render client-side), the Liquid Glass technology overview and
`View.glassEffect(_:in:)`. Every SwiftUI API named below was compiled against the installed macOS 27
SDK (`swiftc -typecheck -target arm64-apple-macos27`), not taken from memory.

## What's new page (macOS 27)

The page lists frameworks, not UI changes; it names no Liquid Glass, menu bar or symbol changes.

| Feature | Applies | Where / why not |
| --- | --- | --- |
| Foundation Models framework (multimodal, dynamic profiles, PCC) | Already used | Speaker summaries; nothing new needed for UI polish |
| App Intents entity/intent schemas, View Annotations | No (not now) | Possible later: "start recording" intent; out of scope here |
| Core AI | No | Transcription runs on FluidAudio/Core ML |
| SwiftUI document apps, reorderable content, lazy subviews | No | No documents or reorderable lists |
| NowPlaying framework | No | Hearsay records, it does not play media to the system |
| WidgetKit customization | No | No widgets |
| Music Understanding, Spatial Preview, Safari 27, GPTK 4 | No | Unrelated |

## Liquid Glass and materials (HIG Materials, Liquid Glass overview)

| Guidance / API | Applies | Where |
| --- | --- | --- |
| Standard controls pick up glass automatically | Yes | Toolbars, `.borderedProminent` Start/Stop, segmented picker, search field: left standard |
| Glass is the control layer; never the content layer | Yes | Menu tiles and the details card stay semantic fills (`.fill.quaternary`/`.quinary`); the menu panel is already glass, so glass inside it would be glass on glass |
| Use glass sparingly, for the most important floating elements | Yes | Dictation bubble (`.glassEffect(.regular, in:)`, existing) and the no-notch pill |
| `glassEffect(_:in:)`, `Glass.regular.tint(_:)` | Yes | Pill without a notch: `.regular.tint(.black.opacity(0.35))` |
| Dimming layer of 35 % behind glass over bright content | Yes | The pill's tint, so its white text reads over a light menu bar |
| `GlassEffectContainer`, `glassEffectID` morphing | No | No view has two glass shapes that should merge; one container per single shape adds nothing |
| `.buttonStyle(.glass/.glassProminent)` | No | Every button is inside an already glass or black surface |
| Reduce Transparency / Increase Contrast change glass automatically | Yes | Relied on, not overridden (not verified on screen) |
| `backgroundExtensionEffect`, `scrollEdgeEffectStyle` | No | No edge-to-edge imagery; scroll edges get the system default |

## Menu bar extras (HIG The menu bar)

| Guidance | Applies | Where |
| --- | --- | --- |
| Symbol-based template icon, 24 pt bar | Yes | Owned by the icons agent |
| "Display a menu, not a popover, unless too complex for a menu" | Yes, deliberately deviated | The panel has live tiles, levels and a details card (spec amendment) |
| Let people choose; don't rely on the extra being visible | Partly | Accessory app with no Dock icon by spec; noted, not changed |

## Toolbars

| Guidance | Applies | Where |
| --- | --- | --- |
| Group by function, at most three groups | Yes | Meeting: one group (Show in Finder, Reprocess) + search. Live: status at leading edge + search |
| Symbols without borders; text only when a symbol is unclear | Yes | Existing items use symbols with labels for VoiceOver |
| No app name as window title | Yes | Meeting windows use the meeting title; Live window "Live Transcript" |
| `ToolbarSpacer`, `sharedBackgroundVisibility` | Compiled, not needed | Two groups only |

## SF Symbols

| Feature | Applies | Where |
| --- | --- | --- |
| Breathe ("an ongoing recording session") | Yes | Menu header Recording, recent row while recording, Live window toolbar |
| Rotate (task in progress) | Yes | Menu header Transcribing, recent row while transcribing |
| Variable colour for a changing level | Yes | Call audio tile: `speaker.wave.3.fill` fills with the call level |
| Variable colour iterative (activity) | Yes | Dictation bubble (existing), Live window "Listening" |
| Magic Replace | Yes | Notch pill and Dictation tiles when toggled |
| Hierarchical rendering | Yes | Status symbols in menu header, recent rows, meeting header |
| Gradient rendering (SF Symbols 7) | No | Symbols are small; gradients "look best at larger sizes" |
| Draw On/Off | No | No progress symbol large enough to read it |
| Reduce Motion | Yes | Every effect above is `isActive: !reduceMotion`; Magic Replace becomes `.identity` |

## Typography, colour, layout, motion

| Guidance | Applies | Where |
| --- | --- | --- |
| macOS has no Dynamic Type; use built-in text styles | Yes | Text styles only (`.callout`, `.caption`, `.headline`); fixed sizes only in the pill, which sits in the 24-37 pt menu bar band |
| Semantic and system colours | Yes | `.fill.*`, `.separator`, `.secondary`, `.tint`, `.red`/`.orange` with text |
| Stable layout; content should not jump | Yes | Details card reserves two lines (`lineLimit(2, reservesSpace: true)`), recent rows 36 pt |
| Brief, purposeful motion | Yes | Symbol effects only signal state; nothing animates for decoration |
| `ContentUnavailableView` for empty states | Yes | Meeting transcript (recording / queued / nothing to transcribe), Live window (listening / no transcript) |
