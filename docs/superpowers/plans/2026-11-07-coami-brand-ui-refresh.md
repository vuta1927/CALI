# COAMI Brand & iOS UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand the existing iOS POC from CALI to COAMI and apply a coherent, accessible mint/teal/aqua liquid-glass visual system without changing workout domain behavior.

**Architecture:** Keep the current SwiftUI feature and domain structure intact. Add a code-native COAMI identity layer (vector SVG masters, deterministic PNG exports, SwiftUI symbol/wordmark views), then centralize adaptive colors, glass surfaces and branded components so existing screens inherit the new language with targeted hierarchy improvements. Treat the chosen Companion C / Guided Progress direction as the implementation recommendation, not as human-approved trademark clearance.

**Tech Stack:** Swift 6, SwiftUI, WidgetKit/ActivityKit, XcodeGen, SVG, ImageMagick, XCTest

**Spec:** `docs/design/COAMI_Brand_Design_Handoff.md`

## Global Constraints

- Preserve offline-first behavior and all current domain/timer semantics.
- Exercise media, countdown and actions remain visually dominant during workouts.
- The icon contains no wordmark or tagline and has no baked rounded corners.
- The flat silhouette must remain legible at 24, 32, 48, 60, 120 and 180 px, with a visible margin inside the iOS icon mask.
- Use `#2FF6C4`, `#00D4C6`, `#00A7E1`, `#0B2742`, `#EAF7FF` and white as the initial brand family; do not use color as the only status signal.
- Keep every interactive target at least 44×44 pt and support Dynamic Type, Reduce Transparency and Reduce Motion.
- Do not claim trademark clearance or final human approval.
- Do not touch API, SQL, persistence or workout-domain contracts.
- Existing edits in `CHANGELOG.md`, `ios/README.md` and `docs/design/` belong to the user and must be preserved.

## Review Focus

- Reduce Transparency enabled: cards remain opaque, bordered and readable; tested by pure style-policy assertions in Task 2.
- Light and dark appearance: semantic foreground/background pairs retain hierarchy; tested by token identity and luminance assertions in Task 2.
- Small logo surfaces: symbol geometry remains unclipped at compact sizes; tested by SVG bounds/export checks in Task 1.
- Workout safety: reaching a deadline still never records completion; existing `CaliDomain` reducer tests remain the regression gate in Task 4.
- Missing exercise media: placeholder remains explicitly labeled and visually distinct from production content; existing UI copy is retained and checked in Task 3.

---

### Task 1: Code-native COAMI identity package

**Files:**
- Create: `brand/README.md`
- Create: `brand/sources/COAMI-brand-master.svg`
- Create: `brand/logos/coami-primary.svg`
- Create: `brand/logos/coami-secondary.svg`
- Create: `brand/logos/coami-symbol.svg`
- Create: `brand/logos/coami-monochrome-dark.svg`
- Create: `brand/logos/coami-monochrome-light.svg`
- Create: `brand/concept-exploration/concept-a-companion-c.png`
- Create: `brand/concept-exploration/concept-b-motion-partner.png`
- Create: `brand/concept-exploration/concept-c-guided-progress.png`
- Create: `brand/app-icon/coami-app-icon-1024.png`
- Create: `brand/app-icon/coami-app-icon-flat-1024.png`
- Create: `brand/app-icon/coami-app-icon-preview.png`
- Create: `brand/previews/coami-brand-board.png`
- Create: `brand/previews/coami-home-screen-preview.png`
- Create: `brand/previews/coami-lock-screen-preview.png`
- Create: `brand/previews/coami-light-dark-preview.png`
- Create: `brand/guidelines/COAMI-brand-guidelines.md`
- Create: `ios/CaliApp/Assets.xcassets/Contents.json`
- Create: `ios/CaliApp/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `ios/CaliApp/Assets.xcassets/AppIcon.appiconset/coami-app-icon-1024.png`
- Modify: `ios/project.yml`

**Interfaces:**
- Consumes: brand brief palette, three concept directions and iOS icon constraints.
- Produces: editable SVG symbol/lockups and deterministic raster assets; `AppIcon` asset catalog name for Xcode.

- [x] Create the three distinct monochrome-first concept boards and score them with the brief's weighted rubric.
- [x] Implement the recommended symbol as clean SVG paths with a 1024×1024 optical safe area and separate flat/glass treatments.
- [x] Export all required PNGs with ImageMagick and copy the 1024 master into the Xcode asset catalog.
- [x] Run `magick identify` for every PNG and verify the icon is exactly 1024×1024, opaque, square and readable in generated small-size previews at 24, 32, 48, 60, 120 and 180 px.
- [x] Validate each SVG as XML and confirm it contains no embedded raster `<image>` elements or unresolved external links.

### Task 2: Adaptive COAMI SwiftUI design system

**Files:**
- Modify: `ios/CaliApp/DesignSystem/Theme.swift`
- Modify: `ios/CaliApp/DesignSystem/Components.swift`
- Create: `ios/CaliApp/DesignSystem/COAMILogo.swift`
- Modify: `ios/CaliAppTests/CaliAppTests.swift`

**Interfaces:**
- Consumes: Task 1 geometry and exact brand tokens.
- Produces: `COAMIColorToken`, `COAMISymbol`, `COAMIWordmark`, `BrandHeader`, `GlassCardModifier`, plus source-compatible `cali*` aliases for feature views.

- [x] Add failing XCTest assertions for exact token hex values, light/dark semantic mappings and accessibility effect policy.
- [x] Run the hosted iOS tests on macOS or document the unavailable local Xcode runner; failures must reference missing token/style APIs.
- [x] Implement adaptive palette tokens, restrained gradients, raised glass material with Reduce Transparency fallback, branded controls and the reusable SwiftUI logo.
- [x] Re-run hosted tests where available and perform a static Swift syntax/reference scan on Windows.

### Task 3: App shell and visual-first screen hierarchy

**Files:**
- Modify: `ios/CaliApp/App/RootView.swift`
- Modify: `ios/CaliApp/Features/Home/TodayView.swift`
- Modify: `ios/CaliApp/Features/Catalog/CatalogView.swift`
- Modify: `ios/CaliApp/Features/Planner/PlanView.swift`
- Modify: `ios/CaliApp/Features/Journal/HistoryView.swift`
- Modify: `ios/CaliApp/Features/AIReview/AIReviewView.swift`
- Modify: `ios/CaliApp/Features/Settings/ProfileView.swift`
- Modify: `ios/CaliApp/DesignSystem/PosterView.swift`
- Modify: `ios/project.yml`

**Interfaces:**
- Consumes: Task 2 semantic tokens and components.
- Produces: COAMI-branded app shell/onboarding, adaptive light/dark surfaces and clearer visual hierarchy while preserving navigation and feature behavior.

- [x] Replace user-facing CALI branding with COAMI and broad-training companion copy while retaining medical disclaimers and mock-data labels.
- [x] Add a restrained brand header/onboarding treatment; keep content and calls to action below Dynamic Type-safe layouts.
- [x] Apply glass cards and gradient accents selectively to hero/progress/AI surfaces; keep exercise posters dominant and avoid decorative glass in dense lists.
- [x] Remove the forced dark appearance so semantic colors support system light/dark mode.
- [x] Search user-facing source for stale `CALI` copy and verify only technical identifiers or historical comments remain.

### Task 4: Workout/Live Activity integration and evidence

**Files:**
- Modify: `ios/CaliApp/Features/WorkoutPlayer/WorkoutPlayerView.swift`
- Modify: `ios/CaliApp/Features/WorkoutPlayer/ResultFormView.swift`
- Modify: `ios/CaliActivityWidget/WorkoutLiveActivity.swift`
- Modify: `CHANGELOG.md`
- Create: `docs/design/COAMI_UI_IMPLEMENTATION.md`

**Interfaces:**
- Consumes: Task 2 compact symbol and semantic tokens.
- Produces: compact high-contrast COAMI mark for workout and Live Activity surfaces, plus implementation/evidence notes.

- [x] Add only restrained identity cues to workout headers; timer, exercise media and action controls remain primary.
- [x] Add a simplified high-contrast mark to Lock Screen/Dynamic Island without adding state-changing widget behavior.
- [x] Run `python tools/validate_handoff.py` and attempt `swift test --package-path ios/Packages/CaliDomain` once; `swift` is unavailable on this Windows host.
- [x] Record that XcodeGen/Xcode build and XCTest require macOS CI, and real-device visual QA remains pending.
- [x] Inspect `git diff --check`, asset dimensions, SVG integrity and changed-file scope; append a concise Unreleased changelog entry without overwriting user edits.

## Execution Note

Implementation is native in the current session because the user explicitly requested “cứ làm”. Commits and PR creation are intentionally excluded from this dirty shared worktree; the final handoff will list verification evidence and remaining device/CI checks.
