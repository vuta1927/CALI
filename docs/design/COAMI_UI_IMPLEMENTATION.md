# COAMI UI implementation handoff

## Status

The iOS POC now uses the **Guided Companion C** candidate and the COAMI mint/teal/aqua/navy visual system. This is an implementation candidate for product review, **not** a claim of final human approval, trademark clearance or App Store readiness.

## What changed

- Added a complete editable brand package under `brand/`, including three distinct concept boards, SVG logo masters, opaque 1024px app icons, placement previews and mini guidelines.
- Added an Xcode app-icon asset catalog and changed the user-facing bundle display name to **COAMI**.
- Replaced the dark-only CALI palette with semantic light/dark COAMI tokens while retaining source-compatible `cali*` aliases.
- Added restrained material cards with an opaque Reduce Transparency fallback, brighter brand CTAs and code-native `COAMISymbol`, `COAMIWordmark` and `BrandHeader` views.
- Redesigned onboarding and the Today header around the broader “AI training companion” positioning, rather than a calisthenics-only identity.
- Preserved visual-first exercise hierarchy: poster/demo, countdown and workout actions stay above decorative branding.
- Added a flat high-contrast compact mark to workout, Lock Screen and Dynamic Island surfaces. The Live Activity remains read-only and contains no button, intent or state mutation.

## UI behavior preserved

- All workout commands still flow through the existing reducer/model.
- Countdown expiry still never infers set completion.
- Offline persistence, mock-data labeling, placeholder-media labeling and AI approval/audit behavior are unchanged.
- Notifications remain advisory and require the user to return to COAMI to confirm a set result.

## Accessibility decisions

- Interactive targets keep the existing 44pt minimum.
- System Dynamic Type and system light/dark appearance remain enabled; forced dark mode was removed.
- `accessibilityReduceTransparency` switches branded cards from material to an opaque semantic surface.
- Brand color is never the only state signal; status icons and text labels remain intact.
- The compact mark is hidden from accessibility because adjacent exercise/state text carries meaning.

## Asset and typography notes

- The app icon master is opaque, square and has no baked rounded corners or text.
- The app icon proof shows 180, 120, 60, 48, 32 and 24 px sizes; use the flat monochrome form at 24 px.
- SwiftUI uses the Apple system font. SVG wordmark sources list an Avenir Next/system fallback stack but do not bundle or redistribute font binaries. Convert an approved external wordmark to outlines before final publishing if its target cannot guarantee the selected font.
- Run `python tools/validate_brand_assets.py` after changing any logo or icon export.

## Verification performed on Windows

```text
python tools/validate_brand_assets.py          PASS (6 SVG, 12 PNG, 1 PDF)
python tools/validate_coami_design_sources.py PASS
python tools/validate_coami_ui_copy.py        PASS
python tools/validate_coami_widget_brand.py   PASS
python tools/validate_handoff.py              PASS (schema semantic check skipped: jsonschema unavailable)
python -m py_compile tools/validate_*.py        PASS (five COAMI validators)
git diff --check                              PASS
```

`swift test --package-path ios/Packages/CaliDomain` was attempted once and could not start because `swift` is not installed or available on PATH. Local SwiftUI compile/test was not possible: XcodeGen and Xcode are unavailable on Windows, and Docker Desktop's Linux engine returned HTTP 500. These are environment limitations, not passing build results.

## Required macOS/CI follow-up

```bash
brew install xcodegen
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/CaliApp.xcodeproj -scheme CaliApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
swift test --package-path ios/Packages/CaliDomain
```

Before release, also run the existing unsigned archive workflow and complete the real-device matrix: light/dark, Reduce Transparency, Dynamic Type, VoiceOver, lock/unlock, screen off, permission denied, flight mode, forced termination and clock/time-zone changes.

## Remaining review gates

1. Human selection/approval of the identity direction.
2. Trademark similarity screening and legal clearance.
3. Xcode compile + hosted XCTest on macOS.
4. Real-iPhone Home Screen, Lock Screen and Dynamic Island visual QA.
5. Licensed production exercise photography/video to replace explicit placeholders.
