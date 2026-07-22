---
name: Parallax
description: Native Jellyfin client for Apple platforms — theater-dark, monochrome glass, the library is the interface.
colors:
  paper: "#EBEBF0"
  paper-field-inner: "#F1F1F5"
  paper-field-outer: "#E1E1E8"
  paper-surface: "#F8F8FB"
  paper-white: "#F5F5F8"
  ink: "#1C1C24"
  ink-deep: "#22222A"
  graphite: "#16161C"
  graphite-field-inner: "#17171E"
  graphite-field-outer: "#111116"
  graphite-surface: "#1A1A22"
  screen-white: "#FFFFFF"
  player-ink: "#0A0A0C"
  glass-paper: "#F6F6FA85"
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
  chip: "10pt"
  badge: "7pt"
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
    backgroundColor: "{colors.screen-white}"
    textColor: "{colors.player-ink}"
    typography: "{typography.headline}"
  button-form-solid:
    backgroundColor: "{colors.ink-deep}"
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

The palette has two committed faces sharing one hue family (OKLCH H≈285): **Paper** by day — daylight graphite, the night hue lifted into light, cool ink — and **Graphite** by night (near-black blue-leaning dark, screen-white ink). One room, two light switches: switching appearance reads as the same theater with the house lights up or down, not as two apps. Both floors are painted as **ambient light-fields** — screen-pinned, luminance-only elliptical falloffs of the floor's own hue (`BackgroundField` in `DesignTokens.swift`) — lighting, not decoration. (Adopted 2026-07-18, replacing the warm-stone/espresso day face; the Paper app-icon asset still carries the old warm palette and awaits a resample — the launch stage's pencil colors stay icon-derived until then.)

**The material rule (glass is earned, not default).** Liquid Glass is reserved for two places: the **player** (clear, refractive glass over video — `.glassEffect(.clear)`, so footage shows through) and the **system bars** the platform owns (the `.sidebarAdaptable` sidebar / tab bar, the navigation bar — left native). **Everything the app itself draws is flat:** buttons are solid or `fill` fills (the Play pill, circle actions, form CTAs), cards are `surface` panels (the detail description card, settings rows), fields and badges are `fill`. This mirrors Apple's own split — playback is glossy glass, the menus are opaque — and it keeps glass meaningful: when chrome refracts, it's because content (video) is behind it. The player remains the one custom island (monochrome white-on-ink, geometric metrics) because system platters fight video.

This system explicitly rejects: **Plex's busy chrome**, the **Netflix-clone carousel-of-carousels home**, **hobby-app stock UI**, and **custom chrome that fights the platform**.

**Key Characteristics:**
- Monochrome, accentless: tint = label color; the library provides all color
- Two-faced adaptive palette: Paper (light) / Graphite (dark), one hue family, floors lit by subtle ambient fields
- Flat app-drawn chrome; Liquid Glass reserved for the player (over video) + system bars
- The player is a sanctioned custom island (white-on-ink, geometric `u` scaling)
- One design language, two grammars: iOS touch and tvOS focus diverge in expression only
- Warmth lives in copy and detail moments, never in decoration

## 2. Colors: Paper & Graphite

A two-faced monochrome system in one hue family (OKLCH H≈285): daylight graphite and cool ink in light mode, graphite and screen white in dark — resolved per-appearance through one `Color(light:dark:)` helper, never branched at call sites.

### Primary
- **Ink** (#1C1C24): The light-mode ink and the app's entire "accent" — it is the global tint, every label, every glyph. Near-black in the floor's own blue-leaning family; brand warmth lives in copy and artwork, not the ink.
- **Screen White** (#FFFFFF): The dark-mode ink and tint. Pure white, because in a dark room over artwork anything less reads as dimmed.

### Neutral
- **Paper** (#EBEBF0): Light-mode floor base. Daylight graphite — the night hue lifted to daylight; it ignores the system's dark-elevation lift so scaled iPad windows don't shift. Painted as the day field `#F1F1F5 → #EBEBF0 → #E1E1E8` (±3–4% L).
- **Paper Surface** (#F8F8FB, drawn at 92%): Light-mode raised surface for cards and panels (~1.1–1.2:1 over the field, native-calm lift).
- **Graphite** (#16161C): Dark-mode floor base. Near-black with a blue lean; the theater at house-lights-down. Painted as the night field `#17171E → #16161C → #111116` (1.06:1 span — dimmer than day on purpose; dark-adapted eyes amplify deltas; the inner stop is the launch field's own).
- **Graphite Surface** (#1A1A22): Dark-mode raised surface.
- **Ink Deep** (#22222A): Solid button fill for form CTAs in light mode.
- **Paper White** (#F5F5F8): Label color on ink-filled buttons in light mode.
- **Player Ink** (#0A0A0C): The player's fixed near-black backdrop, both schemes — the player is pinned dark. (The hero Play pill is likewise theme-FIXED: white fill + player ink label in both schemes, owner directive 2026-07-14.)
- **Glass Paper / Glass Graphite** (#F6F6FA at 52% / #1C1C22 at 52%): The tint layer inside `.glassEffect` where glass is sanctioned (the player, hero chrome); one token, no variants.

### Opacity ramp (derived, not separate hexes)
Light: secondary label = ink at 78%, tertiary at 60%, separator 12%, fill 10% / 6% — tuned to clear WCAG AA on the fill backplate (secondary 6.7:1, tertiary 3.97:1). Dark: secondary 62%, tertiary 45%, separator 10%, fill 24% / 16%.

### Named Rules
**The No-Accent Rule.** The global tint is `Color.label`. No brand color exists anywhere in chrome — prohibited. Color on screen comes from artwork. The sole exceptions, both marking state rather than brand: destructive red on destructive actions, and the `ok` green (#3DA45A) server LED — each applied explicitly.

**The Two Faces Rule.** Every adaptive color resolves through `Color(light:dark:)` in `DesignTokens.swift`. Never branch on `colorScheme` at a call site; never use system semantic colors (`.primary`, `.systemBackground`) — the palette is custom on purpose.

**The Lighting Rule.** Screen floors are ambient light-fields, not flat paint: `BackgroundField` (a luminance-only elliptical falloff of the floor's own hue, center x 0.5 / y 0.30) is what `screenFloor()` and every root/sheet floor draws. Fields are LIGHTING and stay inside these bounds — hue-locked, screen-pinned (never scrolling with content), ≤ ~4% L span. Hue gradients and decorative color ramps in chrome remain banned; a field that reads as "a gradient" rather than as light has crossed the line.

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

Depth in Parallax is **material and scrim layering, not shadow stacking**. Surfaces separate through tone and hairline strokes — Liquid Glass (`.glassEffect` + `glassBorder`) where glass is sanctioned, flat `surface` panels everywhere else — and legibility over artwork comes from band scrims and gradient washes — never bare text, never text shadows in chrome. The system is flat at rest; what reads as "elevation" is material translucency.

### Shadow Vocabulary
Shadows exist only where something floats over *media*:
- **Player handle/bubble** (`black @0.5–0.6, radius 2–20 × u`): scrub affordances over video.
- **Subtitle legibility** (`black @0.9, radius 3`): text over unpredictable frames.
- **Library card** (`black @0.2, radius 8, y 4`): the single chrome shadow, under 16:9 banners.

### Named Rules
**The Legibility-Only Shadow Rule.** A shadow must justify itself as legibility over media. Decorative shadows on chrome are prohibited — separation is glass's job.

**The Scrim-Under-Text Rule.** Text over artwork always sits on a scrim or glass layer (hero band scrims, shelf footer progressive blur, player dim at `rgba(4,4,8,0.46)` × state factor). If you can imagine a bright frame breaking the text, it's already broken.

## 5. Components

Controls are **flat**: each non-player control draws its own solid / `fill` fill via `flatControlFill` (the single rest-fill ↔ focus-platter helper). Liquid Glass is reserved for the player + system bars. The non-player tvOS focus model is ONE bespoke treatment — white platter + ink content + lift — applied uniformly, because the system platter doesn't recolor custom content (it would leave white-on-white).

### Buttons
- **Shape:** Capsule pills and circles, continuous corners everywhere. Pill height = circle diameter, matched via `ActionRow.controlHeight` (iPhone 50 / iPad 52 / tvOS 62).
- **Primary (Play pill, `PrimaryPlayButton`):** a flat solid pill, theme-FIXED white + player-ink label in BOTH schemes (owner directive 2026-07-14 — it rides artwork and must not flip with the app theme). Reserves its widest title invisibly so Play/Resume swaps never resize.
- **Icon buttons (`CircleGlassButton`):** circular `heroGlass` fill + hairline + white glyph — the SAME recipe as the 4K/HDR/CC badges; the active state is a glyph swap (heart→heart.fill). 1.05 optical overshoot on iOS.
- **Form CTAs (`formActionButton`):** `.solid` = solid `buttonFill`; `.glass` (secondary) = `fill` + hairline. Disabled dims the pill but keeps the label legible (no blank-pill bug).
- **Focus (tvOS):** one bespoke recipe for every flat control — white platter + ink + lift (`flatControlFill` inverts the fill, `tvChipButton`/`tvFocusEffect` lifts). Posters keep the native `.borderless` lockup (image content); the player keeps clear-glass-over-video with a platter on its active/focused state.

### Chips
- **Player chips (`PlayerGlassChip`):** material ramp — rest = clear interactive glass + 30% dim; active = frosted tinted glass; focused (tvOS) = solid-white platter with ink, faded over an always-mounted glass base (a structural swap snaps the glass morph — prohibited).
- **Metadata badges:** frosted hero-glass capsules (4K/HDR/CC), caption-bold, monochrome.

### Cards / Containers
- **Corner Style:** panel 24pt / card 18pt / tile 12pt — the concentric `Radius` system is the brand's shape lever; nav items inset 12pt from panels (24 − 12).
- **Background:** `surfacePanel(cornerRadius:)` (`GlassSurface.swift`) = opaque `surface` fill + 1pt hairline border. Flat per the material rule — no glass on app-drawn cards.
- **Shadow Strategy:** none (see Elevation); LibraryCard is the lone exception.
- **Poster tiles (`MediaTile`):** artwork-only, no visible title (the title survives as the VoiceOver label); optional progressive-blur footer (real `.ultraThinMaterial` masked by an alpha ramp) for captions and progress. Artwork loads fade in over a BlurHash (or gray) placeholder via `artworkReveal`; memory-cache hits render instantly, never re-fading.

### Inputs / Fields
- **Search:** system `.searchable`, everywhere — no custom search field. (A custom bar was built and deleted: an in-content field under the `.sidebarAdaptable` keyboard hits an off-screen bug no inset fix reaches. The system slot is the contract; don't resurrect the custom one.)
- **Text fields:** field radius (14pt), `fill` background, no stroke at rest.

### Navigation
- **iPhone:** bottom `TabView`; **iPad/tvOS:** `.sidebarAdaptable` with a dynamic Libraries `TabSection`. Never a fixed-column `NavigationSplitView` root. Drill-downs are `NavigationStack`.
- **tvOS:** focus contract centralized in `TVFocusReader` + `TVFocusModifiers` — poster tiles are native `.borderless` with the system `.highlight` effect re-masked to tile corners; chips use a custom lift style. 40pt inter-tile gaps are the focus-safe floor.

### The Player (signature)
The sanctioned custom island. Monochrome white-on-ink, pinned dark, every dimension a `PlayerMetrics × u` formula. Shared scrim vocabulary (`PlayerScrimStyle`: ink dim × state factor — cold start 0.74, live frame 0.50, error 0.62), one loading primitive (`PlayerScrimRing`, a unit-tested indeterminate white arc), calm loading vs loud error scrims with frozen geometry so the ring never jumps, double-tap seek flash, and a three-mode progress bar (track 0.20 → buffered 0.36 → played white) that reserves its tallest handle so the centerline never shifts. Custom because native platters fight video — and still bound by platform contracts: focus inversion, Reduce Motion, remote semantics.

## 6. Motion

One shared vocabulary — `extension Animation` in `DesignTokens.swift` plus the focus timing in `TVFocusModifiers.swift`; call sites keep their own Reduce-Motion gating. The house feel is the **organic spring settle**: user-initiated motion lands with life, not a snap — and conversely, motion is never re-sprung app-wide unscoped.

- **organicSettle** (spring, response 0.4, damping 0.86): user-initiated reveals and snaps — hero carousel page settle, detail overview expand.
- **pressDim** (easeOut 0.12): the one press-dim cue, shared by the tvOS chip/quiet styles and the iOS flat form CTA.
- **tilePressResponse** (easeOut 0.15): iOS touch-down scale + opacity on full-bleed artwork tiles, released on the same curve before the `.zoom` push.
- **chromeToggle** (easeOut 0.15): player HUD chrome opacity toggle — fast and retargetable, so a rapid re-tap reverses mid-flight instead of replaying.
- **tvFocusChrome** (easeOut 0.18): focus platter/ink crossfade on the SAME curve as the focus scale lift, so chrome never snaps mid-scale.
- **playerStateCrossfade** (easeInOut 0.2): the player's interlocking scrim/transport swaps — one token across the two files implementing that state machine.
- **artworkReveal** (easeOut 0.25): artwork fade-in over its BlurHash/gray placeholder after a real load; memory-cache hits skip it entirely.
- **contentSwap** (easeOut 0.25): screen-level loading→loaded crossfade, iOS/iPadOS only (tvOS keeps a hard cut — re-identifying focusable content mid-animation strands the focus engine).
- **playerCoverFade** (easeInOut 0.3): full-bleed player covers — the reload spinner and the track-switch failure overlay.

**The One-Token Rule.** Any feel that repeats ships as ONE named token — three button styles share `pressDim`, both player HUD files share `playerStateCrossfade` — so timing can't drift between surfaces. A raw duration literal in chrome is a defect, same as a raw radius.

## 7. Do's and Don'ts

### Do:
- **Do** keep chrome monochrome: tint is the label color, ink (#1C1C24) by day, white by night. The artwork is the accent.
- **Do** use the `Radius` enum (panel 24 / card 18 / field 14 / tile 12 / chip 10 / badge 7) and `Space` scale — raw radius or spacing literals in chrome are a defect.
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
- **Don't** introduce a brand accent color, hue gradient, or decorative tint anywhere in chrome. Prohibited without exception. (The `BackgroundField` floors are not an exception but a different thing: luminance-only falloffs of the floor's own hue are lighting — see The Lighting Rule.)
- **Don't** use system semantic colors or branch on `colorScheme` at call sites — every adaptive color goes through `Color(light:dark:)` tokens.
- **Don't** put Dynamic Type in the player or fixed sizes in chrome — the Two Scales Rule cuts both ways.
- **Don't** swap glass structurally inside a `GlassEffectContainer` — fade layers over an always-mounted base, or the morph snaps.

*Audit test: if a screenshot could pass for Plex, the chrome has won over the content — strip it back.*
