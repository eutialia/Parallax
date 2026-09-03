---
name: apple-platform-references
description: Index of reference documentation that ships with Xcode 26. Use when writing Swift 6.2 concurrency code, debugging Swift compiler diagnostics, or implementing modern iOS 26 SwiftUI/UIKit patterns (Liquid Glass, new toolbar, AttributedString updates, etc.). Read files directly from their Xcode install path so they stay current with the installed Xcode version.
metadata:
  type: reference-index
---

# Apple-shipped reference documentation

Xcode 26 ships two valuable reference sets. Do **not** copy them into the repo — read them directly from Xcode's install path so they stay in sync with your installed Xcode version. Use the `Read` tool against the paths below when relevant.

## When to consult these

| Situation | What to read |
|---|---|
| Writing or debugging Swift 6.2 concurrency code (actors, `Sendable`, `async`, `@MainActor`) | `Swift-Concurrency-Updates.md` (high-level) + relevant diagnostic file (specific error) |
| Compiler emits a Sendable / actor / data-race error you don't recognize | The matching `diagnostics/*.md` file (named after the diagnostic, e.g. `sending-closure-risks-data-race.md`) |
| Implementing iOS 26 SwiftUI views (Liquid Glass material, new toolbar API, styled text) | The relevant SwiftUI-*.md file |
| Working with `AttributedString` or text styling (subtitle rendering, info displays) | `Foundation-AttributedString-Updates.md` |
| Implementing accessibility for users with cognitive impairments | `Implementing-Assistive-Access-in-iOS.md` |
| Considering Span/InlineArray for performance-sensitive buffer code (subtitle compositor, decoder bridges) | `Swift-InlineArray-Span.md` |

## Location 1 — Xcode Intelligence reference docs

Path: `/Applications/Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation/`

Files most relevant to Parallax (in priority order):

- `Swift-Concurrency-Updates.md` — Swift 6.2 Approachable Concurrency, default actor isolation, single-threaded-by-default model. Directly relevant to our actor-based architecture.
- `SwiftUI-Implementing-Liquid-Glass-Design.md` — iOS 26 Liquid Glass design system in SwiftUI. Read before building UI surfaces.
- `SwiftUI-New-Toolbar-Features.md` — Toolbar API changes. Relevant for the player chrome and navigation bars.
- `Foundation-AttributedString-Updates.md` — AttributedString in Swift 6.2. Useful if we ever render subtitles natively or build rich info displays.
- `Swift-InlineArray-Span.md` — `InlineArray` and `Span` for buffer code. Could matter if we ever bridge VLC frame buffers or write a custom decoder.
- `UIKit-Implementing-Liquid-Glass-Design.md` — UIKit Liquid Glass, useful for the `UIViewControllerRepresentable` wrapping `AVPlayerViewController` and any custom UIKit chrome.
- `Implementing-Assistive-Access-in-iOS.md` — accessibility consideration for a future hardening pass.

Not currently relevant (but available — full list):

- `AppIntents-Updates.md` — defer until we add Siri intents (e.g. "Play next episode")
- `SwiftUI-WebKit-Integration.md`, `SwiftUI-AlarmKit-Integration.md`, `SwiftUI-Styled-Text-Editing.md` — out of scope
- `SwiftData-Class-Inheritance.md` — we're not using SwiftData
- `StoreKit-Updates.md` — no IAP
- `WidgetKit-Implementing-Liquid-Glass-Design.md`, `Widgets-for-visionOS.md` — no widgets in scope
- `MapKit-GeoToolbox-PlaceDescriptors.md`, `Swift-Charts-3D-Visualization.md`, `Implementing-Visual-Intelligence-in-iOS.md`, `FoundationModels-Using-on-device-LLM-in-your-app.md`, `AppKit-Implementing-Liquid-Glass-Design.md` — not applicable to Parallax

## Location 2 — Swift compiler diagnostic docs

Path: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/share/doc/swift/diagnostics/`

46 reference files, named to match Swift compiler diagnostic identifiers. Don't read these proactively — read them on-demand when you hit a specific diagnostic you don't already understand.

Highest-relevance for Parallax (concurrency-heavy, actor-heavy, Sendable-heavy architecture):

- `actor-isolated-call.md`
- `sending-closure-risks-data-race.md`
- `sendable-closure-captures.md`
- `sendable-metatypes.md`
- `explicit-sendable-annotations.md`
- `nonisolated-nonsending-by-default.md`
- `isolated-conformances.md`
- `conformance-isolation.md`
- `mutable-global-variable.md`
- `existential-any.md`
- `strict-memory-safety.md`
- `performance-hints.md`
- `upcoming-language-features.md`
- `strict-language-features.md`

To list all available diagnostics, run:
```
ls /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/share/doc/swift/diagnostics/
```

## How to use this skill

1. When you start working on a task that matches one of the "When to consult" rows above, **read the file before writing code**.
2. When the compiler hits a diagnostic you don't recognize, **look up the corresponding `.md` in `diagnostics/` before guessing at a fix**.
3. Don't dump the contents of these files into chat — quote the specific guidance that applies to the current decision.
4. If a file you expected isn't present, the user may be on a different Xcode version. List the directory to see what's actually there.

## When NOT to use this skill

- For SwiftUI API reference of well-established APIs (use Apple's developer.apple.com docs, or `context7` for any library)
- For jellyfin-sdk-swift or third-party library docs (use `context7`)
- For Parallax-specific architecture decisions (those live in `docs/superpowers/specs/`)
