# COAMI — Brand Identity & App Icon Design Handoff

> **Version:** 1.0  
> **Status:** Ready for design exploration  
> **Audience:** Brand Concept Agent, Logo Design Agent, UI Visual System Agent, Reviewer  
> **Product:** COAMI — Your AI Training Companion  
> **Primary platform:** iOS (iPhone), expandable to other platforms

---

## 1. Product overview

**COAMI** is an intelligent **personal training companion** — not merely a workout tracker or a Calisthenics-only app.

COAMI helps users:
- Plan workouts and training cycles.
- Recognize exercises through **large visual thumbnails and short demonstration videos**.
- Track timed holds, reps, sets and rest intervals.
- Receive reminders and see workout state through **Lock Screen Live Activities** and Dynamic Island where supported.
- Record notes and performance history.
- Work **offline-first**, then synchronize when online.
- Receive personalized feedback and training-plan suggestions from an **AI Coach**, subject to user approval.

**Brand promise:** *A supportive training companion that keeps every workout clear, focused and progressive.*

**Tagline:** **Your AI Training Companion**. Treat this as a supporting line, **not part of the app icon**.

### Brand positioning

| Attribute | Desired expression |
|---|---|
| Companion | Friendly, supportive, always close at hand |
| Intelligence | Smart, precise, helpful — not a generic chatbot |
| Movement | Active and energizing without being aggressive |
| Progress | Consistent, measurable improvement |
| Reliability | Clear, trustworthy, accessible and practical |
| Versatility | Works across Calisthenics, gym and future training types |

**Avoid:** bodybuilding aesthetics, aggressive gym stereotypes, medical/clinical imagery, generic robots, cliché dumbbells, overcomplicated dashboards and motifs that imply Calisthenics is the only supported sport.

---

## 2. Creative direction: iPhone-inspired Liquid Glass

### Visual goal

A **refined, iPhone-inspired translucent glass** treatment: luminous edges, controlled depth, softly refracted aqua/teal gradients and polished surfaces. Modern, approachable and premium — **not** a glossy toy, exaggerated jelly 3D icon or sci-fi neon sign.

### Design principles

1. **Form before effect.** The silhouette must remain recognizable without glass, gradients, highlights or shadows.
2. **Small-screen first.** Prioritize recognition at Home Screen and compact UI sizes.
3. **One focal symbol.** Avoid trying to fit C, speech bubble, human figure, and charts all at full detail simultaneously.
4. **Measured use of glass.** Use translucency and specular highlights to add depth, not obscure the mark.
5. **System-aware.** Check light/dark, tinted/monochrome and accessibility contrast in iOS contexts.
6. **Original identity.** Draw inspiration from platform conventions without copying Apple iconography or any third-party trademark.

### Visual treatment

**Use:**
- Soft transparent or frosted layers.
- Restrained inner highlights and edge lighting.
- Smooth mint → teal → aqua gradients.
- Clean, soft cast shadows; subtle refraction.
- Carefully rounded geometry and optical alignment.
- Strong flat silhouette underneath the effects.

**Avoid:**
- Heavy glass thickness, plastic/jelly finish or strong bloom.
- Rainbow gradients and unrestrained cyan glow.
- Numerous tiny lines or chart bars that disappear at small sizes.
- Baked-in device frames, text, badges or screenshots inside the actual app icon.
- Relying on transparency/blur to create the only visual distinction.

---

## 3. Color system

These values are a **starting palette**, not immutable final output. The Design Agent must verify contrast and appearance against real backgrounds.

| Token | Hex | Suggested use |
|---|---|---|
| `brand.mint` | `#2FF6C4` | Hero highlight / positive energy |
| `brand.teal` | `#00D4C6` | Main signature color |
| `brand.aqua` | `#00A7E1` | Refraction / gradient depth |
| `brand.navy` | `#0B2742` | Dark logo, deep background |
| `brand.ice` | `#EAF7FF` | Light canvas / soft glass |
| `neutral.white` | `#FFFFFF` | Contrast / monochrome mark |

**Default glass palette:** teal/mint glass over deep navy or icy white. Ensure the symbol remains readable even when color effects are removed.

Do not use color alone to communicate functional meaning. Brand green is not automatically the color for all success/status states.

---

## 4. Typography & wordmark

- Use a legible, contemporary **sans serif** with slightly rounded or humanist geometry.
- Wordmark must read **COAMI**, unambiguously and at small sizes.
- Explore subtle customization in the **C** or **A**, but avoid ambiguous letterforms.
- Tune kerning and optical balance manually.
- Preserve a timeless character; avoid gimmicky futuristic/typewriter styles.
- Select a font whose commercial licensing allows the planned uses. **Do not package or redistribute font binaries unless licensed.**
- Provide outlined/vector wordmark exports where appropriate, plus the name/license of the source typeface.

---

## 5. Symbol concept exploration — three genuinely distinct directions

Produce **at least 3 concepts**. Each must have a different primary idea, not merely a color variation.

### Concept A — Companion C

**Core:** a geometric **C** that subtly suggests a speech/assistant cue through its negative space or silhouette.

- **Strength:** distinctive brand initial; memorable on Home Screen.
- **Risk:** can look like a generic chat app if movement is missing.
- **Direction:** introduce movement through the sweep and angle of the C itself, not extra details.

### Concept B — Motion Partner

**Core:** an abstract human movement gesture nested within a C-like arc or companion shape.

- **Strength:** instantly signals training and supportive motion.
- **Risk:** can turn into an overly detailed fitness pictogram.
- **Direction:** one bold motion curve and one supporting dot/shape at most.

### Concept C — Guided Progress

**Core:** a symbol expressing guidance and improvement via an ascending gesture, route or compressed progression form.

- **Strength:** scales beyond any particular exercise or sport.
- **Risk:** can resemble generic analytics or stock-market branding.
- **Direction:** include a soft companion/coach signature without literal mini bar charts.

For each concept, present **a flat black-and-white silhouette first**, then a glass treatment. Do not allow the glass version to conceal weak geometry.

---

## 6. Identity assets & variants

Required design system:

1. **Primary lockup:** symbol + COAMI wordmark; optional separate tagline variation.
2. **Secondary lockup:** compact horizontal or stacked version without tagline.
3. **Symbol only:** suitable for app icon and compact surfaces.
4. **Monochrome:** dark-on-light and white-on-dark, flat and legible.
5. **iOS app icon:** optimized visual composition at small size; no wordmark/tagline inside.
6. **Light/dark and reduced-effect variants:** maintain recognition without full glass rendering.
7. **Splash / onboarding usage:** demonstrate use of the symbol with typography.
8. **Lock Screen / Live Activity usage:** test a small, simplified mark next to training status.

### Important technical guidance for iOS assets

- Provide a **square 1024 × 1024 px master icon preview** plus vector master and any separately required layers.
- **Do not bake rounded corners into the base app-icon canvas** unless the platform asset workflow explicitly requires it; test within the actual iOS icon mask.
- Support platform-specific icon generation and testing via current Xcode/Apple icon tooling. **Validate the current App Store and iOS icon requirements before release.**
- Do not assume every iPhone surface supports the same glass, transparency or dynamic rendering behavior.
- Keep the symbol inside a generous **optical safe area** and test at 24, 32, 48, 60, 120 and 180 px previews.
- For Live Activity and Dynamic Island assets, prefer the simplified/flat high-contrast mark, not a complex glass render.

---

## 7. Component previews / product placement

Mock up the approved identity in these environments:

| Placement | What to verify |
|---|---|
| iOS Home Screen icon | Immediate recognition, suitable background contrast |
| iOS dark/tinted appearance | No loss of shape or harsh unwanted edges |
| Splash screen | Symbol and wordmark harmonize |
| App header | Legible and restrained next to navigation |
| Exercise Library | Brand does not compete with visual exercise thumbnails |
| Workout Player | Brand does not distract from timer/rep controls |
| Lock Screen Live Activity | Tiny mark readable beside timer/status |
| Dynamic Island | Compact silhouette survives minimal space |
| Website / social avatar | Recognizable with and without wordmark |
| Light/dark backgrounds | Consistent hierarchy and clarity |

**Important UX constraint:** COAMI is a workout assistant. During workouts, exercise photography, demo video, countdown and action controls have priority over large decorative brand treatment.

---

## 8. Brand-board deliverables

For each shortlisted concept, deliver one annotated design board with:

- Symbol in monochrome, wordmark and combined lockup.
- App icon preview at both large and small sizes.
- Signature glass treatment on light and dark backgrounds.
- Core palette and typography rationale.
- Explanation of the symbol's meaning in **2–4 concise sentences**.
- Clear strengths, weaknesses and differentiation risks.

After selecting the final concept, produce a **master brand board**, including spacing, clear space, minimum size, misuses and key applications.

---

## 9. File/package specifications

Use the following directory structure:

```text
brand/
├── README.md
├── concept-exploration/
│   ├── concept-a-companion-c.png
│   ├── concept-b-motion-partner.png
│   └── concept-c-guided-progress.png
├── sources/
│   └── COAMI-brand-master.svg
├── logos/
│   ├── coami-primary.svg
│   ├── coami-secondary.svg
│   ├── coami-symbol.svg
│   ├── coami-monochrome-dark.svg
│   └── coami-monochrome-light.svg
├── app-icon/
│   ├── coami-app-icon-1024.png
│   ├── coami-app-icon-flat-1024.png
│   └── coami-app-icon-preview.png
├── previews/
│   ├── coami-brand-board.png
│   ├── coami-home-screen-preview.png
│   ├── coami-lock-screen-preview.png
│   └── coami-light-dark-preview.png
└── guidelines/
    ├── COAMI-brand-guidelines.md
    └── COAMI-brand-guidelines.pdf
```

**Export rules:**
- **SVG:** editable vector master, clean paths, no missing external image links.
- **PNG:** high-resolution raster exports; transparent background where appropriate for logos (not automatically for iOS icon master).
- **PDF:** vector logo or brand guideline where required.
- **JPEG/PNG previews:** presentation assets only, not substitutes for editable sources.
- **Design source:** include original editable source document when supported by the agent/tool.
- Include exact **color tokens**, spacing rules, vector dimensions and font licensing notes.

Do not mislabel a raster picture placed inside an SVG as a genuinely editable vector logo.

---

## 10. Agent responsibilities & handoff gates

### Agent A — Brand Concept Agent

**Inputs:** Sections 1–5.  
**Work:** propose and explain three truly differentiated identity concepts, create simplified shape explorations and review uniqueness risks.  
**Outputs:** three concept boards plus comparison matrix.  
**Gate:** reviewer selects one direction **before** high-effort polish.

### Agent B — Logo Execution Agent

**Inputs:** approved concept, palette/typography direction, iOS asset constraints.  
**Work:** refine geometry, proportions, wordmark and glass rendering; implement flat and monochrome versions.  
**Outputs:** vector masters, icon variants, raster exports and usage previews.  
**Gate:** small-size and no-effect tests pass.

### Agent C — UI Visual System Agent

**Inputs:** approved logo system and product UI constraints.  
**Work:** translate brand language into app surfaces, navigation accents, cards, button states, workout player, live-activity small mark.  
**Outputs:** UI-ready tokens, usage examples and implementation notes for SwiftUI developers.  
**Gate:** contrast, readability and visual hierarchy checks pass.

### Integrator / Reviewer

- Validate that all exports represent the **same approved identity**.
- Compare concept outputs against the original brief.
- Flag collisions or close resemblance to existing products for human review.
- Confirm all deliverables open correctly and all file references resolve.
- Do not mark design approved without human selection of the final concept.

---

## 11. Workflow

### Phase 1 — Exploration

1. Identify 3 concept directions from Section 5.
2. Produce silhouette sketches and text rationales.
3. Show the 3 directions at **small icon size**, not only hero size.
4. Present strengths, risks and a preferred recommendation.
5. Request final concept selection.

### Phase 2 — Refinement

1. Refine the approved symbol's geometry and proportions.
2. Design wordmark and lockups.
3. Produce carefully balanced glass, flat and monochrome versions.
4. Test against light/dark screens and iOS Home Screen mockups.
5. Review accessibility and legibility at small sizes.

### Phase 3 — Finalization

1. Export vector and raster assets.
2. Produce brand board and mini guideline.
3. Verify file quality and naming.
4. Prepare implementation-ready assets and handoff notes.
5. Record approved version and any remaining risks.

---

## 12. Acceptance criteria / definition of done

A concept can only be approved when **all** of these are met:

- [ ] Name **COAMI** is clear and correctly spelled in wordmark exports.
- [ ] Symbol communicates **assistant / motion / progress** without demanding all three literal pictograms.
- [ ] Identity works for a broad **training assistant**, not just Calisthenics.
- [ ] The symbol is recognizable at iOS Home Screen sizes.
- [ ] A flat monochrome version is successful without glass treatment.
- [ ] Glass highlights and gradients are restrained, not distracting.
- [ ] Logo remains distinct on light, dark and simplified/tinted presentations.
- [ ] Color contrast and wordmark readability are reviewed.
- [ ] App icon has no small body text or tagline.
- [ ] Lock Screen and Dynamic Island previews include a simplified high-contrast option.
- [ ] Vector source assets and independently usable raster exports exist.
- [ ] Mini brand guideline explains safe area, minimum size and misuses.
- [ ] All font and image asset licensing is documented.
- [ ] Existing app names/logos and trademark conflicts are **screened**, with legal clearance identified as a separate step.
- [ ] Human reviewer has selected and approved the final concept.

### Suggested review scorecard (1–5 each)

| Criterion | Weight |
|---|---:|
| Memorability / distinctiveness | 25% |
| Small-size legibility | 25% |
| Companion/training positioning | 20% |
| Premium iPhone glass aesthetic | 15% |
| Cross-channel flexibility | 15% |

**Total: 100%.** Glass rendering is intentionally weighted below form and legibility.

---

## 13. Ready-to-use prompt for the Design Agent

```text
You are a senior brand identity and mobile visual designer.

Read COAMI_Brand_Design_Handoff.md completely and follow it as the
source of truth for COAMI's brand exploration.

Context:
COAMI is an AI personal training companion for workout planning,
visual exercise guidance, timers, rep/set/rest tracking, workout
journaling, offline sync, Lock Screen Live Activities, and coaching.
It must not appear limited to Calisthenics.

Creative direction:
Premium, friendly, energetic, trustworthy, minimalist, with a
restrained Apple/iPhone-inspired Liquid Glass treatment.
Use mint/teal/aqua/navy as the initial color family.

Tasks:
1. Create 3 genuinely distinct vector-friendly logo concepts.
2. For each, show a flat monochrome silhouette and glass preview,
   small-size app icon, rationale, strengths and risks.
3. Recommend the best concept using the provided scorecard.
4. Do not falsely claim final approval: the human reviewer selects
   a direction before final refinement.
5. After approval, produce primary/secondary logos, icon-only,
   monochrome, light/dark variants and iOS app icon assets.
6. Prepare a brand board, mini guideline and handoff notes.
7. Check small-size recognizability, copyright/trademark similarity,
   output integrity, editable vectors and asset licensing.

Deliverables:
Follow the folder structure and acceptance criteria in this brief.
Do not include wordmark/tagline inside the actual app icon.
Do not fake an editable vector by embedding a bitmap in SVG.
```

---

## 14. Explicit out-of-scope items

- Implementing the complete iOS app or backend.
- Final UX flows for every feature beyond necessary branding previews.
- Trademark registration or legal opinion.
- Publishing the app to App Store.
- Producing a 3D mascot or animated character unless separately approved.

---

## 15. Reference design direction

Previous COAMI visuals established the desired **mint/teal glass C-inspired identity** with an integrated sense of motion/assistant/progress. Use them as **creative references, not a fixed finished logo**. Re-evaluate silhouette clarity, small-size reproduction and originality during concept exploration.

**Final strategic constraint:** *COAMI must look like a trusted companion that helps people train, not like a tool that merely counts repetitions.*
