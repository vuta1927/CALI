# COAMI brand package (Guided Companion C, orange v0, archived)

This package implements the **Guided Companion C** as the current recommendation: an open `C` creates a supportive space, the inner route indicates guided progress, and the point suggests a coach's presence without depicting a chatbot. It combines the strongest small-size form from Concept A with the future-facing progression signal from Concept C.

Status: **implementation candidate, not final human approval**. Trademark similarity screening and legal clearance remain separate release gates.

## Concept scorecard

| Concept | Memorability 25% | Small-size 25% | Positioning 20% | Glass 15% | Flexibility 15% | Weighted |
|---|---:|---:|---:|---:|---:|---:|
| A — Companion C | 4.5 | 4.5 | 4.0 | 4.5 | 4.0 | **4.30** |
| B — Motion Partner | 3.5 | 3.0 | 4.5 | 4.0 | 4.0 | **3.75** |
| C — Guided Progress | 4.0 | 4.0 | 3.75 | 4.0 | 4.5 | **4.05** |

The shipped candidate deliberately adds Concept C's route to Concept A while retaining one dominant `C` silhouette. If human review rejects that hybrid, the three exploration boards remain available for selection.

## Files and generation

- `sources/` contains editable SVG masters and preview sources.
- `logos/` contains independently usable vector lockups and monochrome symbols.
- `app-icon/` contains opaque 1024px glass and flat masters plus a size proof.
- `previews/` contains presentation-only usage mockups.
- `guidelines/` documents tokens, spacing, typography and misuse in editable SVG, Markdown and PDF forms. The PDF is rendered from the vector guideline page; `COAMI-brand-guidelines.png` is its image source.

Palette: orange (flame `#FF7A2F` → orange `#FC4C02` → ember `#E83F00`, ink `#1A1206`, cream `#FFF3EC`), shared with the iOS theme. The previous teal package is kept unchanged in `archive/teal-v1/`; `concept-exploration/` stays in its original teal as a historical record.

PNG exports are deterministic ImageMagick renders from SVG sources. Run `python tools/validate_brand_assets.py` from the repository root to validate dimensions, opacity, SVG integrity and the Xcode asset reference.
