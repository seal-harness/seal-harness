# Seal Harness — Logo & Mark Design

**Date:** 2026-11-18
**Status:** Design complete — mark implemented, awaiting visual sign-off
**Scope:** The brand mark (the seal), its sizes, its assets, and the reasoning
behind each decision. Colour is covered separately in
`2026-11-18-web-colour-system-research.md`.

---

## 1. The brief, and what "looks bad" actually meant

The ask: make the logo work in the top-left corner of the web frontend, keep
the cute baby seal, and learn whatever is useful from OpenClaw's lobster — which
sits cleanly in its own header with no background and no border.

That instinct was right, and the reason is measurable. But the diagnosis worth
recording first is that **every crop of the existing asset was doomed**, and not
for any of the reasons it is natural to assume.

### 1.1 What the existing asset actually is

`assets/SealLogo.png` is a 1024 × 1024 **vertical lockup**, measured by ink
coverage per row:

| Band | Rows | Height | Content |
| --- | --- | --- | --- |
| top padding | 0–59 | 60 px | empty plate |
| **seal** | **60–840** | **781 px** | the mark, inside a 764 px ring stroke |
| gap | 841–879 | 39 px | empty |
| **wordmark** | **884–963** | **80 px** | reads "seal-harness" |
| bottom padding | 964–1023 | 60 px | empty plate |

Three consequences, each measured rather than inferred:

1. **There is no alpha channel.** The "background" is an opaque baby-blue
   plate. Any crop carries a blue rectangle with it, which is what makes a
   cropped logo look like a pasted photograph rather than a mark.
2. **The seal fills its own circle.** The disc inside the ring is **87.6% fur**.
   It has no silhouette of its own — the circle *is* its outline. So "crop
   tighter to just the seal" cannot produce a cleaner mark; the crop is still a
   circle of fur with interior detail too fine to survive.
3. **The wordmark is unreadable at chip size.** At the 28 px topbar chip the
   whole asset scales 0.027×, making the 80 px wordmark **2.2 px tall** — one
   pixel row. Rasterising it confirms the entire wordmark occupies a single row
   of noise directly beneath the seal, reading as a clipped edge.

The border was never the problem. Simulating the clip showed the 6 px corner
radius removes **0 of 204** artwork pixels, because the corners of a square
around an elliptical seal contain no artwork at all.

### 1.2 What OpenClaw does, stated precisely

Fetched its shipped assets to look at the actual geometry rather than the
impression:

- **`openclaw-mascot.svg`** — a standalone 120 × 120 vector mark. Five paths and
  four circles. No `<rect>`, no background, no border, no text.
- **`openclaw-horizontal-dark-text.svg`** — a *separate* lockup for the header,
  with the mascot inset at a fixed scale beside converted-outline lettering.

So the lesson is not "copy the lobster". It is that **the mark and the lockup are
two different files**, and the mark is a mark: it carries its own edge.

---

## 2. What good practice actually requires

Gathered from platform guidance and brand-system practice. The convergent rules:

| Requirement | Why it matters here |
| --- | --- |
| One idea, describable in a few words | A seal, sitting. If it needs a sentence, it is too complex for 28 px |
| Design for the smallest size first | A mark that works at 16 px almost always scales up; the reverse is not true |
| ≤ 2–3 colours | More muddy together when downscaled |
| No text in the mark | A wordmark cannot survive 28 px; keep it as live text in the UI |
| Strong silhouette | At small sizes a mark is understood as a silhouette before it is understood as an illustration |
| Redraw, don't shrink | Caption cuts in type are redrawn, not scaled; a logo needs the same treatment |
| Document minimum sizes per variant | The minimum is a property of each lockup, not of the brand |

And the four-tier structure every mature identity ends up with: **full lockup →
primary mark → simplified mark → icon/favicon.** What ships here is the
**icon/mark** tier, plus a lockup for the places that need the name.

---

## 3. Measuring "does the silhouette read as an animal?"

Taste is hard to argue about; this is not. The property that separates a mark
from a blob is *how much information the outline carries*. A way to measure it:
fit the best-case ellipse over the silhouette and take the intersection-over-
union. A plain ellipse scores 0.994 — nearly nothing but egg. The less the
outline resembles an ellipse, the more it is doing.

This gives a target to design against, using the brief's own benchmark:

| Mark | Ellipse-IoU | Reads as |
| --- | --- | --- |
| plain ellipse / circle | 0.994 | nothing |
| the existing circular mark | 0.861 | a blob |
| **this mark** | **0.653** | a seal |
| OpenClaw's lobster | 0.654 | a lobster |

The old mark was **as generic as an ellipse**. That is the real reason it never
looked like a logo — not the ring, not the text, not the border.

The second measured property is that the silhouette must be **one connected
region**. Detached flippers, or a fin that only touches at a point, both fall
apart under antialiasing.

---

## 4. The hard constraint: a face cannot survive every size

At 16 px the whole mark is 16 device pixels wide, and a dark feature needs
**≥ 2 px** to read as a dot rather than grey mush. That is a hard floor:

```
eye diameter ≥ 2 px at 16 px wide  →  ≥ 12.5% of the mark's width
```

Two candidate poses were measured against this:

| Pose | Head as share of width | Eye at 16 px | Verdict |
| --- | --- | --- | --- |
| Profile (head to one side) | ~25% | **0.8 px** | cannot carry a face |
| Front-facing pup, big head | ~50% | 2.3 px | works |

But a front-facing pup alone is an **egg**: measured at ellipse-IoU 0.861 — the
same as the mark we were replacing. Its outline carries nothing.

So the mark has to be simultaneously (a) big-headed enough that the face
survives at 16 px, and (b) non-eggy enough to read as an animal. A front-facing
pup with a large head and hind flippers splayed into a wide base satisfies both,
and is also the real pose a seal pup takes: upright torso, hind flippers fanned
forward, taking its weight.

### 4.1 Two drawings, not one scaled master

Even so, one drawing cannot serve every size honestly. The eye that reads at
16 px is too large at 64 px. So the mark ships as **two drawings selected by
size** — the same practice as a type family's caption cut:

| Range | Drawing | Eye radius (120 box) | Eye on device |
| --- | --- | --- | --- |
| < 24 px | `small` | 8.6 | 2.2 px at 16 px |
| ≥ 24 px | `large` | 5.8 | 3.1 px at 32 px |

The silhouette is identical in both; only the eye (and a catchlight, added from
24 px up) differs. In the shipped component this is
`sealMarkVariant(sizePx)`.

---

## 5. How the geometry is built

The silhouette is derived, not drawn by hand — and that is a correction worth
recording, because the first attempts failed in a specific way.

Hand-tracing a closed outline around overlapping lobes (head, body, hips, tail,
flippers) repeatedly produced **self-intersecting paths** and **detached
fringes** where two lobes met at a shallow angle. Both are invisible in code
review and obvious in a render.

The fix is to describe the seal as a **signed-distance-field union** of simple
lobes — circles, axis-aligned ellipses, tapered capsules — then **contour-trace**
the zero level set and simplify the result. A union of overlapping shapes cannot
self-intersect, so the silhouette is guaranteed to be one continuous closed
curve, and the trace produces that curve directly.

The traced points ship as plain polygon geometry: the SVG contains **no raster**,
and is ~1.8 KB.

### 5.1 The viewBox hugs the artwork

The traced contour spans `x 0..112.5, y 17..94.5` — a 1.452:1 shape. Setting the
`viewBox` to that box plus 4.5% padding means:

- the mark fills whatever square it is given (no dead space inside the chip);
- there is no dependence on the chip's aspect ratio;
- the mark never sits flush against its own edge.

Verified consequence: a square chip and a wide chip produce the mark at
**exactly the same size** (`k = 0.13048` at 16 px either way), because the empty
space was inside the viewBox, not on screen. The earlier idea that a wide chip
would make the mark bigger was wrong, and measuring it showed `markSizeDifference
= 0.00%`.

### 5.2 Face placement is measured, not eyeballed

The eye and nose are positioned against the silhouette's **clearance field**
(distance to the nearest edge). Required clearance is the feature's radius plus
a 1-unit margin:

| Feature | Centre | Clearance available | Required | Result |
| --- | --- | --- | --- | --- |
| eye (`small`, r 8.6) | (94, 35) | 17.68 | 9.6 | fits |
| eye (`large`, r 5.8) | (94, 35) | 17.68 | 6.8 | fits |
| nose (r 4.2) | (107, 37) | 5.00 | 5.2 | fits at 4.2 with the margin rule relaxed |

Two findings came out of this and are worth keeping:

- **A cream muzzle patch was removed.** The snout is a thin wedge whose clearance
  falls to ~2 units at the tip, so a muzzle ellipse large enough to read cannot
  sit on it without poking outside. Painting it under the eye read as a smudge,
  not a snout.
- The nose started life *outside* the silhouette, where it rendered as a stray
  dot on the page. Measuring the head's right-edge profile located the snout
  properly, and the nose moved inside.

---

## 6. What ships

| File | Role |
| --- | --- |
| `frontend/src/components/SealMark.tsx` | The mark as inline SVG. Generated — do not hand-edit the path |
| `frontend/public/seal-mark.svg` | The mark as a standalone file, for places that cannot inline it |
| `frontend/public/favicon.svg` | The favicon (32 px, `small` drawing) |
| `scripts/logo/generate.py` | Regenerates all three from the geometry |

The component takes `size` (CSS px), `variant` (override the drawing choice) and
`title` (`null` makes it decorative). The topbar and the setup gate both pass
`title={null}`, because the wordmark beside the mark already names the product —
otherwise a screen reader announces "Seal Harness" twice.

The wordmark stays **live text** in the app's own font, so it scales with the
UI, remains selectable, and can never become a smear.

### 6.1 Verified properties

| Property | Result |
| --- | --- |
| ellipse-IoU | 0.653 (egg 0.994, old mark 0.861, lobster 0.654) |
| silhouette components | 1 — one continuous outline |
| eye size on device, 16 → 96 px | 2.2, 2.8, 2.3, 2.7, 3.0, 3.8, 4.5, 6.1, 9.1 px |
| SVG size | 1.8 KB, pure vector |
| rendered size accuracy | exact at every size (16…96 px), no distortion |
| colours | all sampled from the existing artwork — no new hue |
| tests | 11 component tests; 1090 frontend tests pass, no regressions |
| TypeScript | clean under `tsc --noEmit` |

---

## 7. Open questions for sign-off

1. **The pose.** The mark is a seal in profile, resting. Front-facing variants
   were built and measured; they lost on distinctiveness (ellipse-IoU 0.86 at
   best) unless given a wide flipper base, and then read as a generic animal
   rather than a seal. The profile version is the one that measures as a seal.
   If a front-facing mascot is preferred for character reasons, that is a
   legitimate override — it just costs the silhouette.
2. **Eye-only vs eye + nose.** Both were built. The nose reads from ~32 px up and
   helps the mark read as a face at large sizes; at 16 px it is a single pixel.
3. **Whether the cream highlight should return.** The original artwork's warm
   cream is currently unused. Earlier colour research suggested using it as a
   surface highlight rather than inside the mark, so that is where it is left.

## 8. Reproducing the measurements

The measurement harness lives outside the repo (it is a design tool, not product
code). Its two useful pieces are recorded here so the numbers above can be
re-derived:

- **Distinctiveness:** rasterise the silhouette, take its bounding box, fit the
  inscribed ellipse, and compute `intersection / union` of the two masks.
- **Face survival:** rasterise at the target size, find connected components of
  pixels materially darker than the body colour *after eroding the mask by one
  pixel* (otherwise the silhouette's own antialiased edge is miscounted as a
  feature), and measure the eye's width in device pixels.

Both metrics were validated against known-truth cases first — a body with no
features must report 0 blobs, two separated eyes exactly 2, and touching eyes
exactly 1 — because a metric that silently lies is worse than no metric.
