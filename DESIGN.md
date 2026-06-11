---
name: Parallax
description: Native Jellyfin client for Apple platforms — theater-dark, monochrome glass, the library is the interface.
colors:
  paper: "#D0C8BA"
  paper-surface: "#FAF7F0"
  paper-white: "#F7F2EA"
  espresso: "#221E17"
  espresso-deep: "#2A241D"
  graphite: "#16161C"
  graphite-surface: "#1A1A22"
  screen-white: "#FFFFFF"
  player-ink: "#0A0A0C"
  glass-paper: "#F8F4ED85"
  glass-graphite: "#1C1C2285"
typography:
  display:
    fontFamily: "SF Pro (system)"
    fontSize: "52pt (home hero; 48pt detail; Dynamic Type via scaledFont relativeTo .largeTitle)"
    fontWeight: 800
  headline:
    fontFamily: "SF Pro (system)"
    fontSize: "17pt (.headline)"
    fontWeight: 600
  title:
    fontFamily: "SF Pro (system)"
    fontSize: "22pt/.title2 regular-width, 20pt/.title3 compact"
    fontWeight: 700
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "17pt (.body)"
    fontWeight: 400
  label:
    fontFamily: "SF Pro (system)"
    fontSize: "12pt (.caption) / 11pt (.caption2)"
    fontWeight: 700
rounded:
  panel: "24pt"
  card: "18pt"
  field: "14pt"
  tile: "12pt"
  nav-item: "12pt"
spacing:
  s3: "3pt"
  s8: "8pt"
  s12: "12pt"
  s14: "14pt"
  s16: "16pt"
  s18: "18pt"
  s22: "22pt"
  s26: "26pt"
  s30: "30pt"
  s40: "40pt"
  s60: "60pt"
components:
  button-play-pill:
    backgroundColor: "{colors.espresso-deep}"
    textColor: "{colors.screen-white}"
    typography: "{typography.headline}"
  button-form-solid:
    backgroundColor: "{colors.espresso-deep}"
    textColor: "{colors.paper-white}"
    rounded: "{rounded.field}"
  chip-player-active:
    backgroundColor: "{colors.glass-graphite}"
    textColor: "{colors.screen-white}"
  tile-poster:
    rounded: "{rounded.tile}"
---

# Design System: Parallax

## 1. Overview

**Creative North Star: "Your last local media player"**

Parallax is built to be the player you stop looking after — the definitive native client for a personally curated library. That positioning dictates the aesthetic: nothing here is allowed to feel provisional, ported, or generic. The system is theater-dark and content-forward; artwork and video are the interface, and the chrome is monochrome Liquid Glass that recedes. There is no brand accent anywhere — the global tint is the label color itself — because the only color that matters on screen is the user's own library.

The palette has two committed faces, named for the app-icon assets that define them: **Paper** by day (warm stone background, espresso ink) and **Graphite** by night (near-black blue-leaning dark, screen-white ink). Controls are **tactile glass**: native `.glass` / `.glassProminent` materials with real weight and light response, pressed rather than clicked. The one sanctioned departure from native styling is the player — a self-contained monochrome white-on-ink island with its own geometric metrics — because system platter treatments fight video. Everything else defers to the platform: system button styles, system focus, system navigation.

This system explicitly rejects (from PRODUCT.md): **Plex's busy chrome**, the **Netflix-clone carousel-of-carousels home**, **hobby-app stock UI**, and **custom chrome that fights the platform**.

**Key Characteristics:**
- Monochrome, accentless: tint = label color; the library provides all color
- Two-faced adaptive palette: Paper (light) / Graphite (dark), flat by design
- Native Liquid Glass chrome; tactile, recessive controls
- The player is a sanctioned custom island (white-on-ink, geometric `u` scaling)
- One design language, two grammars: iOS touch and tvOS focus diverge in expression only
- Warmth lives in copy and detail moments, never in decoration

## 2. Colors: Paper & Graphite

A two-faced monochrome system: warm paper and espresso in light mode, graphite and screen white in dark — resolved per-appearance through one `Color(light:dark:)` helper, never branched at call sites.

### Primary
- **Espresso** (#221E17): The light-mode ink and the app's entire "accent" — it is the global tint, every label, every glyph. A near-black warm brown, not gray; the warmth of the brand without a single decorative color.
- **Screen White** (#FFFFFF): The dark-mode ink and tint. Pure white, because in a dark room over artwork anything less reads as dimmed.

### Neutral
- **Paper** (#D0C8BA): Light-mode background. Warm stone, deliberately flat — it ignores the system's dark-elevation lift so scaled iPad windows don't shift.
- **Paper Surface** (#FAF7F0, drawn at 92%): Light-mode raised surface for cards and panels.
- **Graphite** (#16161C): Dark-mode background. Near-black with a blue lean; the theater at house-lights-down.
- **Graphite Surface** (#1A1A22): Dark-mode raised surface.
- **Espresso Deep** (#2A241D): Solid button fill — the Play pill in both schemes, form CTAs in light.
- **Paper White** (#F7F2EA): Label color on espresso-filled buttons in light mode.
- **Player Ink** (#0A0A0C): The player's fixed near-black backdrop, both schemes — the player is pinned dark.
- **Glass Paper / Glass Graphite** (#F8F4ED at 52% / #1C1C22 at 52%): The tint layer inside `.glassEffect` panels and bars; a 74%-alpha "strong" variant exists for surfaces needing more body.

### Opacity ramp (derived, not separate hexes)
Secondary label = ink at 62%, tertiary at 34%, separator at 12% (light) / 10% (dark), fill at 12% / 24%. Apple's exact semantic ramp, applied to the custom inks.

### Named Rules
**The No-Accent Rule.** The global tint is `Color.label`. No brand color exists anywhere in chrome — prohibited. Color on screen comes from artwork. The sole exception: destructive red on destructive actions, applied explicitly.

**The Two Faces Rule.** Every adaptive color resolves through `Color(light:dark:)` in `DesignTokens.swift`. Never branch on `colorScheme` at a call site; never use system semantic colors (`.primary`, `.systemBackground`) — the palette is custom on purpose.

## 3. Typography

**Display Font:** SF Pro (system)
**Body Font:** SF Pro (system)
**Mono usage:** system monospaced for Quick Connect codes and player time labels (`.monospacedDigit`)

**Character:** One family, many weights — `.bold` for titles, `.semibold` for controls and glyphs, `.medium` for de-emphasis. No custom font files; the voice is pure platform, differentiated by weight discipline and scale.

### Hierarchy
- **Display** (heavy, 52pt home hero / 48pt detail, via `scaledFont(relativeTo: .largeTitle)`): Hero titles over artwork. Bespoke sizes still ride Dynamic Type through `TypeScale.scaledFont`.
- **Headline** (semibold, 17pt `.headline`): Buttons, the Play pill, circle glass glyphs — deliberately shared so pill and disc heights match.
- **Title** (bold, `.title2` regular-width / `.title3` compact): Shelf and section headers, idiom-switched.
- **Body** (regular, 17pt `.body`): Settings rows, prose.
- **Label** (bold/semibold, `.caption`/`.caption2`): Metadata, badges, chips. Weight carries emphasis, never color.

### Named Rules
**The Two Scales Rule.** App chrome rides Dynamic Type — always. The player rides geometry: fixed `Font.system(size:)` driven by `PlayerMetrics × u`, authored at a 1920-wide base. Never mix the two scales in one surface.

**The Quiet Mono Rule.** Monospace appears only where digits must not jitter: time labels and pairing codes. Never as a display voice.

## 4. Elevation

Depth in Parallax is **glass and scrim layering, not shadow stacking**. Surfaces separate through Liquid Glass materials (`.glassEffect` + hairline `glassBorder` stroke), and legibility over artwork comes from band scrims and gradient washes — never bare text, never text shadows in chrome. The system is flat at rest; what reads as "elevation" is material translucency.

### Shadow Vocabulary
Shadows exist only where something floats over *media*:
- **Player handle/bubble** (`black @0.5–0.6, radius 2–20 × u`): scrub affordances over video.
- **Play button** (`black @0.32, radius 8 scaled, y 4`): the one floating control.
- **Subtitle legibility** (`black @0.9, radius 3`): text over unpredictable frames.
- **Library card** (`black @0.2, radius 8, y 4`): the single chrome shadow, under 16:9 banners.

### Named Rules
**The Legibility-Only Shadow Rule.** A shadow must justify itself as legibility over media. Decorative shadows on chrome are prohibited — separation is glass's job.

**The Scrim-Under-Text Rule.** Text over artwork always sits on a scrim or glass layer (hero band scrims, shelf footer progressive blur, player dim at `rgba(4,4,8,0.46)` × state factor). If you can imagine a bright frame breaking the text, it's already broken.

## 5. Components

Controls are **tactile glass**: native materials with weight and light response. The system owns rest, focus, and label wherever possible; pinning happens only where the system fails (documented at each site).

### Buttons
- **Shape:** Capsule pills and circles; form CTAs at field radius (14pt), continuous corners everywhere.
- **Primary (Play pill, `PrimaryPlayButton`):** `.glassProminent` tinted Espresso Deep (#2A241D) with white label on iOS; bare `.glass` on tvOS so the system owns focus inversion. Reserves its widest title invisibly so Play/Resume swaps never resize.
- **Icon buttons (`CircleGlassButton`):** circular `.glass` discs at `.headline` so they height-match the pill; iOS pins dark + white glyph with a 1.05 optical overshoot.
- **Form CTAs (`formActionButton`):** `.solid` = `.glassProminent` espresso; `.glass` = plain glass. iOS pins the solid label (system would render white-on-white against a light tint).
- **Focus (tvOS):** system-owned — focused = opaque platter + ink, per HIG. Never replicate focus with custom state.

### Chips
- **Player chips (`PlayerGlassChip`):** material ramp — rest = clear interactive glass + 30% dim; active = frosted tinted glass; focused (tvOS) = solid-white platter with ink, faded over an always-mounted glass base (a structural swap snaps the glass morph — prohibited).
- **Metadata badges:** frosted hero-glass capsules (4K/HDR/CC), caption-bold, monochrome.

### Cards / Containers
- **Corner Style:** panel 24pt / card 18pt / tile 12pt — the concentric `Radius` system is the brand's shape lever; nav items inset 12pt from panels (24 − 12).
- **Background:** `glassPanel()` / `glassBar()` = `.glassEffect` tinted Glass Paper/Graphite + 1pt hairline border.
- **Shadow Strategy:** none (see Elevation); LibraryCard is the lone exception.
- **Poster tiles (`MediaTile`):** artwork-only, no visible title (the title survives as the VoiceOver label); optional progressive-blur footer (real `.ultraThinMaterial` masked by an alpha ramp) for captions and progress.

### Inputs / Fields
- **Search (`SearchBar`):** custom rounded `fill` field with magnifier and clear — replaces `.searchable`, which iPadOS 26 hoists into the top-trailing glass slot and breaks the sidebar toggle.
- **Text fields:** field radius (14pt), `fill` background, no stroke at rest.

### Navigation
- **iPhone:** bottom `TabView`; **iPad/tvOS:** `.sidebarAdaptable` with a dynamic Libraries `TabSection`. Never a fixed-column `NavigationSplitView` root. Drill-downs are `NavigationStack`.
- **tvOS:** focus contract centralized in `TVFocusReader` + `TVFocusModifiers` — poster tiles are native `.borderless` with the system `.highlight` effect re-masked to tile corners; chips use a custom lift style. 40pt inter-tile gaps are the focus-safe floor.

### The Player (signature)
The sanctioned custom island. Monochrome white-on-ink, pinned dark, every dimension a `PlayerMetrics × u` formula. Shared scrim vocabulary (`PlayerScrimStyle`: ink dim × state factor — cold start 0.74, live frame 0.50, error 0.62), one loading primitive (`PlayerScrimRing`, a unit-tested indeterminate white arc), calm loading vs loud error scrims with frozen geometry so the ring never jumps, double-tap seek flash, and a three-mode progress bar (track 0.20 → buffered 0.36 → played white) that reserves its tallest handle so the centerline never shifts. Custom because native platters fight video — and still bound by platform contracts: focus inversion, Reduce Motion, remote semantics.

## 6. Do's and Don'ts

### Do:
- **Do** keep chrome monochrome: tint is the label color, espresso (#221E17) by day, white by night. The artwork is the accent.
- **Do** use the `Radius` enum (panel 24 / card 18 / field 14 / tile 12) and `Space` scale — raw radius or spacing literals in chrome are a defect.
- **Do** put text over artwork on a scrim or glass layer, always.
- **Do** let the system own focus, rest, and label states wherever a native style exists; pin colors only where the system demonstrably fails, and document why at the site.
- **Do** carry warmth in copy and empty states — "your library", human error messages — while the palette stays monochrome.
- **Do** provide a Reduce Motion alternative for every animation (the skeleton shimmer and scrim ring set the standard).
- **Do** prove visual claims with rendered pixels: previews are permanent design artifacts.

### Don't:
- **Don't** build **Plex's busy chrome** — no badge clusters, banner stacks, or toolbar sprawl. Information earns its pixel.
- **Don't** ship the **Netflix-clone home** — undifferentiated carousel-of-carousels. Shelves exist because Continue Watching and Next Up are jobs, not decoration.
- **Don't** ship **hobby-app stock UI** — bare `List` rows, default buttons, settings-screen energy on content surfaces.
- **Don't** write **custom chrome that fights the platform** — no fake tab bars, no replicated focus, no `.buttonStyle(.plain)` inside the `tv*` wrappers (it kills tvOS focus).
- **Don't** introduce a brand accent color, gradient, or decorative tint anywhere in chrome. Prohibited without exception.
- **Don't** use system semantic colors or branch on `colorScheme` at call sites — every adaptive color goes through `Color(light:dark:)` tokens.
- **Don't** put Dynamic Type in the player or fixed sizes in chrome — the Two Scales Rule cuts both ways.
- **Don't** swap glass structurally inside a `GlassEffectContainer` — fade layers over an always-mounted base, or the morph snaps.

*Audit test: if a screenshot could pass for Plex, the chrome has won over the content — strip it back.*
