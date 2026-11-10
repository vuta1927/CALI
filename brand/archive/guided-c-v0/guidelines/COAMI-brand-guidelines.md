# COAMI mini brand guidelines

## Identity idea

The open C is a companion space rather than a closed badge. Its rounded rising route represents guided, repeatable improvement; the point is a quiet coach presence, not a robot or chat bubble. The silhouette is intentionally sport-neutral so COAMI can support calisthenics, gym and future training modes.

Status: recommended implementation candidate pending human approval and trademark/legal review.

## Color tokens

| Token | Hex | Usage |
|---|---|---|
| `brand.flame` | `#FF7A2F` | focal highlight and gradient start |
| `brand.orange` | `#FC4C02` | signature stroke and primary brand colour (fills, icons, rings) |
| `brand.ember` | `#E83F00` | gradient depth and refraction |
| `brand.ink` | `#1A1206` | core dark canvas, flat dark mark, text on orange |
| `brand.cream` | `#FFF3EC` | light canvas and high-contrast inner route |
| `neutral.white` | `#FFFFFF` | dark-surface contrast only |

Orange text on light surfaces uses `accentInk` `#C43C00` (≥ 4.5:1); `#FC4C02` alone is for fills, icons and large numerals. These tokens match `ios/CaliApp/DesignSystem/Theme.swift`. The previous teal palette is archived in `../archive/teal-v1/`.

Brand colors do not replace semantic warning/error colors. Every status still includes an icon or text label.

## Geometry and spacing

- Master symbol viewBox: `1024 × 1024`.
- Keep a clear space equal to the companion point diameter (`104` master units) on every side.
- Center the symbol with a clear breathing margin on every side; verify against the actual iOS icon mask. Never add a corner mask to the base 1024px canvas.
- Minimum recommended full-color size: 32px. Use a flat monochrome mark at 24px and in Live Activity/Dynamic Island surfaces. Review `../app-icon/coami-app-icon-preview.png` at 180, 120, 60, 48, 32 and 24px.
- The point must remain circular and the three primary stroke terminals must remain round.

## Typography

UI typography uses Apple's system San Francisco family through SwiftUI, requiring no bundled font. Editable wordmark SVGs use the fallback stack `Avenir Next, Nunito Sans, Arial, sans-serif`; Avenir Next is supplied by Apple platforms, but external publishing must confirm availability or convert approved wordmark text to outlines. No font binaries are included or redistributed.

## Effects

Use glass only on calm, elevated surfaces. The flat silhouette is always the fallback for Reduce Transparency, tinted icons, Lock Screen and very small placements. Avoid bloom, rainbow gradients, thick jelly extrusion and transparency as the only boundary.

## Misuse

- Do not insert the tagline or any small text into the app icon.
- Do not stretch, rotate or recolor individual symbol parts arbitrarily.
- Do not use orange alone to mean success or warning.
- Do not place the glass mark over busy exercise photography without a solid contrast field.
- Do not enlarge brand decoration during active workouts; media, timer and controls have priority.
- Do not present this candidate as trademark-cleared or human-approved.
