# Web Frontend Colour System — Research & Palette Direction

**Date:** 2026-11-18
**Status:** Research complete — awaiting palette selection
**Scope:** Colour tokens, neutral ramp, accent architecture, and the tokenization work required to make a palette swap real.

---

## 1. The problem, stated precisely

The frontend's colour tokens and its logo disagree about what colour Seal Harness is.

| Source | Hue | What it says |
| --- | --- | --- |
| `SealLogo.png` body | **226** (cyan-blue) | Baby blue |
| `design-tokens.css` `--accent-primary` | **284** (violet) | Purple |
| `design-tokens.css` neutral ramp | **271** (violet) | Purple-black |

That is a **58° hue gap** between the accent and the logo, and the neutrals reinforce the wrong
direction rather than splitting the difference. The result is not "purple with a blue logo" —
it is two unrelated colour stories told in the same window.

Worth recording: `frontend/assets/logo.svg` still carries an even older lavender/indigo ramp
(`#beaee5`, `#683ebe`, hue 293) — a build that *would* have matched the current UI. The app
actually imports the **PNG**, so the SVG is stale and should not be used as a colour reference.

---

## 2. Measured facts

### 2.1 The logo's actual colours

Sampled from `frontend/assets/SealLogo.png` (1024², dominant opaque colours):

| Hex | OKLCH | Role | Share |
| --- | --- | --- | --- |
| `#A8D2E4` | `84.0% 0.0508 226` | Body blue (dominant) | 6.6k |
| `#AED8EA` | `85.8% 0.0506 226` | Lit side | 6.1k |
| `#F6F0DE` | `95.5% 0.0246 92` | Warm cream highlight | 2.0k |
| `#243C54` | `34.8% 0.0518 250` | Deep navy lineart | 0.4k |

The cream is what gives the mark its "whimsical" quality — a warm note inside an otherwise cool
palette. Preserving it as a rare highlight is worth considering.

### 2.1a The logo is strictly two-tone — and contains no violet

An earlier draft of this document described a "soft violet" in the logo and used it to justify a
lavender `--accent-secondary`. **That was incorrect.** A full hue histogram of `SealLogo.png`
(every chromatic pixel, 2px sampling, 15° buckets — 256,421 pixels total) gives:

| Hue band | Pixels | Share | What it is |
| --- | --- | --- | --- |
| 195–209° | 215,746 | 84.1% | Baby blue (the body) |
| 180–194° | 3,550 | 1.4% | Cyan edge highlights |
| 30–59° | 33,076 | 12.9% | Warm cream / tan (the highlight) |
| 210–224° | 2,550 | 1.0% | Blue shading |
| **260–330° (violet)** | **1** | **0.0004%** | Effectively **zero** |

The mark is two colours: baby blue and warm cream. Any violet in a Seal palette is an
introduction, not a quotation — and because it is the single most-reused accent token (code
function names, inline code, JSON keys, markdown links, the "thinking" status, Files-view
directories, tool-call titles), an unmoored violet is highly visible and reads as residue from
the previous design rather than a deliberate choice.

The corrected secondary is therefore warm, derived from the cream the logo actually contains.
The **chosen value is `#EDE7DC` ("bone")** — that cream desaturated to roughly half its chroma
(OKLCH `93.0% 0.016 83`). It clears AA as small text on every surface (`--bg-elevated` 12.07:1,
`--bg-sunken` 15.99:1) and it carries the mark's warmth without reading as yellow.

Two alternatives were considered and rejected: the logo's exact cream (`#F7EBD8`, chroma 0.028)
was equally distant from the warning yellow (ΔE 0.15) but carried noticeably more warmth, so it
risked reading as a caution tint; and a more saturated tan (`#EBD3B8`) closed that gap to ΔE 0.10.
Bone sits at ΔE 0.15 from warning, 0.17 from the primary cyan and 0.20 from success green —
comfortably distinct from every colour it must not be confused with, while keeping chroma low
enough that it never reads as a caution state.

Its one near-collision is with `--text-primary` (ΔE 0.038). That is acceptable: every pairing
where the two appear is already distinguished by another channel — links are underlined, inline
code carries the accent tint, and tool-call names are semibold.

### 2.1b `SealLogo.png` is a vertical lockup, not a square mark

A separate defect was found while reviewing the logo's appearance at chip size. **The asset is
not a seal on a square canvas — it is a vertical lockup of the seal above the "seal-harness"
wordmark**, with the following row bands (measured from ink coverage per row):

| Band | Rows | Height | Content |
| --- | --- | --- | --- |
| top padding | 0–59 | 60px | empty plate |
| **seal** | **60–840** | **781px** | the mark itself |
| gap | 841–879 | 39px | empty |
| **wordmark** | **884–963** | **80px** | reads "seal-harness" |
| bottom padding | 964–1023 | 60px | empty plate |

The canvas is opaque throughout — there is no alpha channel to crop against; the "background" is
a solid baby-blue plate (`#ACD9EA`).

**Consequence at chip size.** The topbar renders this at 28px (`--logo-size`). Uniform scaling to
28px makes the wordmark **2.19px tall** — one pixel row. Simulating the browser's box filter at
28px shows the entire wordmark occupying a single row of noise directly beneath the seal, which
reads to the eye as a clipped or smeared edge rather than as text.

**The rounded corner is not responsible.** The chip applies `border-radius: 6px`. Because the seal
is elliptical — widest through the middle, tapering at top and bottom — the four corners of a
square box contain no artwork at all. Rasterising the artwork mask at display resolution and
intersecting it with an r=6 rounded-rect mask removes **0 of 204** artwork pixels. The corner clips
nothing at any radius below ~8px; the visible problem is the wordmark, not the border.

**Why the asset should not simply be cropped.** `README.md` renders the same file at
`width="200"`, where the wordmark is ~15px tall and legible; it is doing real work there. Cropping
the asset to the seal alone would trade a real use for a 28px chip. The correct fix, if the chip
is to be addressed, is to show only the seal sub-region *within the chip* (via `object-fit` +
`object-position`, or a separate seal-only asset used by the chip while the lockup stays for the
README) — **not** to modify `SealLogo.png`.

**Status: not actioned.** The asset, the topbar and the setup gate are unchanged. This section
records the measurement so the finding is not lost.

### 2.2 The current palette's accessibility defects

The token file asserts: *"All text tokens are kept ≥ 4.5:1 against `--bg-base` AND
`--bg-elevated` (WCAG AA for body text)."* That claim holds for text tokens but **not** for the
accent, and it never applied to button foregrounds.

| Combination | Ratio | AA body (4.5) | AA large (3.0) |
| --- | --- | --- | --- |
| `--accent-primary` `#7C6CF6` on `--bg-elevated` | **3.99** | ✗ | ✓ |
| White text on `--accent-primary` (every `.btn-primary`) | **3.94** | ✗ | ✓ |
| `--accent-primary` on `--bg-surface` | 4.46 | ✗ (marginal) | ✓ |
| `--text-faint` on `--bg-elevated` | 4.95 | ✓ | ✓ |
| `--text-muted` on `--bg-elevated` | 5.59 | ✓ | ✓ |

So the primary action button — the single most important control in the product — has never met
AA for its label. Any new palette should fix this rather than inherit it.

### 2.3 Undefined CSS variables (a live bug, independent of palette)

Five variables are **referenced** in the frontend but never **defined** in `design-tokens.css`:

| Variable | Referenced in | Fallback | Effect today |
| --- | --- | --- | --- |
| `--text-secondary` | `App.css` ×5 (`.agate-*`) | none | Resolves to nothing → inherits `--text-primary`. The access panel's secondary text is rendering at full brightness, flattening its hierarchy. |
| `--surface` | `DownloadConfirmDialog.tsx`, `DownloadProgress.tsx` | none | `background: var(--surface)` is invalid → transparent. |
| `--error` | `DownloadProgress.tsx` | none | Download errors render in inherited colour, not red. |
| `--accent` | `App.css` ×2 | `#4a9eff` (and `#7c6cf6` in `.agate-primary`) | Two different fallbacks, neither kept in sync with the real tokens. |
| `--danger` | `App.css` ×3 | `#d9534f` | Stale red, doesn't match `--needs-input` `#FF6B6B`. |

Conversely, these are defined but never used: `--space-1`…`--space-6` (the entire 4px spacing
grid), `--duration-normal`, `--chat-max-width`, `--blink-duration`, `--gradient-duration`.
Components hardcode `4px`/`8px`/`12px` rather than consuming the scale.

### 2.4 Hardcoded colours that resist tokenization

A palette swap limited to `design-tokens.css` leaves violet artifacts on screen. Verified by
sampling rendered screenshots: with only the tokens swapped, the Glacier render still contained
`#131924` and `#141925` (violet residue) in focus rings and the topbar wash.

| Location | Count | What is hardcoded |
| --- | --- | --- |
| `App.css` | 13 | `rgba(124,108,246,…)` — focus rings, shimmer, ask-human hover, topbar gradient, thinking halo |
| `App.css` | 1 | `.btn-primary:hover { background:#8B7DF7 }` — ignores `--accent-primary` entirely |
| `ChatArea.tsx` | 4 | `rgba(124,108,246,…)` inline pill/row backgrounds |
| `PerfOverlay.tsx` | 5 | `#7c6cf6`, `#a9a9f7`, `rgba(124,108,246,…)` |
| `ActiveTabs.tsx` | 1 | `#d97757` provider mark |

Roughly **24 literals** need to become token references before a theme change is genuinely
complete. This is the bulk of the implementation work — the palette itself is the easy part.

---

## 3. The central design constraint

**Baby blue is a light colour** (OKLCH L ≈ 84%). This has a hard consequence:

```
White text on the logo body #A8D2E4 ....... 1.61 : 1   (fails AA, fails even AA-large)
Navy  text on the logo body #A8D2E4 ....... 7.03 : 1   (comfortably passes)
Logo body as text on #0D1316 ............. 11.59 : 1   (comfortably passes)

Glacier's actual solid #70CCEB:
  white text ............................. 1.82 : 1   (fails)
  navy #021F32 text ...................... 9.26 : 1   (passes)
```

So there are exactly three internally-consistent architectures:

1. **Baby blue is the solid action colour** → buttons must carry **dark** text.
2. **Baby blue is never a solid** → it lives only as accent text, borders and brand marks, and
   actions use a darker hue that supports white text.
3. **Keep the existing saturated accent** → baby blue becomes decoration.

This is not a Seal-specific quirk. Radix Colors documents it explicitly: most accent scales are
"designed for white foreground text," but `sky`, `mint`, `lime`, `yellow` and `amber` are
"designed for dark foreground text." Baby blue is in that second family.

A related trap: mixing roles. One token cannot serve as both a *solid fill* (needs dark or white
text on top) and *accent-as-text* (needs 4.5:1 against the page). The three-step accent scale
below separates them.

---

## 4. Candidates

All values generated in OKLCH for perceptually even steps, then converted to sRGB. Contrast
ratios measured against **`bg-elevated`** (the worst case), not `bg-base`.

### 4.1 Glacier ★ (recommended)

Baby blue is the primary. Buttons carry navy text borrowed from the logo's own lineart.

| Token | Hex | OKLCH | Notes |
| --- | --- | --- | --- |
| `--bg-sunken` | `#060C0F` | 15.0% 0.012 225 | inputs, code |
| `--bg-base` | `#0D1316` | 18.2% 0.011 230 | canvas |
| `--bg-surface` | `#161D21` | 22.6% 0.013 233 | panels |
| `--bg-elevated` | `#1F292D` | 27.2% 0.016 225 | pills, hover cards |
| `--border` | `#2C393E` | 33.5% 0.020 225 | dividers |
| `--accent-primary` | `#70CCEB` | 80.0% 0.098 222 | solid fill |
| `--accent-primary-hover` | `#7BD9F9` | 84.0% 0.100 222 | |
| `--accent-primary-pressed` | `#66BFDC` | 76.0% 0.095 222 | |
| `--accent-text` | `#8CDFFB` | 86.0% 0.090 222 | accent-as-text |
| `--accent-secondary` | `#EDE7DC` | 93.0% 0.016 83 | bone — logo cream, desaturated (§2.1a) |
| `--on-accent` | `#021F32` | 23.0% 0.050 240 | button label |
| `--text-primary` | `#EAF3F6` | 95.8% 0.010 220 | |
| `--text-muted` | `#A9B9C0` | 77.5% 0.020 225 | |
| `--text-faint` | `#97A8AF` | 72.0% 0.021 225 | |
| `--success` | `#50D2A7` | 78.0% 0.130 168 | |
| `--warning` | `#EFC558` | 84.0% 0.135 88 | |
| `--needs-input` | `#FF7264` | 72.0% 0.175 28 | |

**Contrast (against `bg-elevated`, the worst case):** text primary 13.20, muted 7.35,
faint 6.04, accent-text 9.95, secondary 12.07, success 7.87, warning 9.05, danger 5.55,
**on-accent on solid 9.26**. Every value clears AA with margin.

**Why this one.** The accent hue (222) sits 4° from the logo body (226) — close enough that the
mark and the interface read as one object rather than two. The navy button label is pulled from
the seal's own lineart, so the button is a mini-quotation of the logo. The neutrals move to a
cyan-slate ramp targeting hue 225 (individual steps land within a few degrees after sRGB
gamut mapping) with chroma tapering toward the dark end, so the background is a clean
blue-black rather than a muddy one.

**Risk.** Dark-navy-on-cyan buttons are a deliberate convention, not a universal one. If a user
expects white-on-blue primary buttons, this reads as unusual for about three seconds. The
mitigation is consistency: use the same treatment for every primary action so it becomes the
product's signature rather than an anomaly.

**Decision (2026-11-18): approved.** Glacier is the chosen direction.

#### 4.1a Secondary-accent candidates, as rendered

The secondary accent is the most-reused token in the palette (code function names, inline code,
JSON keys, markdown links, the "thinking" status, Files-view directories, tool-call titles), so it
was chosen separately. Perceptual separation is ΔE in OKLab — below 0.06 is barely
distinguishable, above 0.10 is clearly different.

| Candidate | Hex | vs primary | vs success | vs warning | AA on `bg-elevated` | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| cream | `#F7EBD8` | 0.19 | 0.21 | 0.15 | 12.62 | Warmer; most distinctive |
| **bone** | **`#EDE7DC`** | **0.17** | **0.20** | **0.15** | **12.07** | **Chosen** — warmth without reading as yellow |
| sand | `#EBD3B8` | 0.16 | 0.17 | 0.10 | 10.29 | Most overtly warm; too near warning |
| ice | `#B6E1E3` | 0.10 | 0.14 | 0.16 | 10.52 | Collapses toward the primary |
| steel | `#BCCDDE` | 0.08 | 0.14 | 0.16 | 9.15 | Indistinct from muted text |
| mono | `#8CDFFB` | 0.06 | 0.13 | 0.21 | 9.95 | No second colour; loses keyword/function distinction |

**bone** was chosen: it keeps the logo's warmth while staying far enough from every other hue to
remain legible in syntax highlighting, and its low chroma means it can never be misread as a
caution state.

### 4.2 Harbor

Deep ocean-teal for actions; baby blue demoted to emphasis.

| Token | Hex | Contrast vs bg-elevated |
| --- | --- | --- |
| `--accent-primary` | `#1D759A` | 2.94 (as a graphic; its label sits at 4.90) |
| `--accent-primary-hover` | `#0F6F95` | — (white fg 5.34) |
| `--accent-primary-pressed` | `#12698C` | — (white fg 5.81) |
| `--accent-text` | `#83D4F3` | 9.17 |
| `--accent-secondary` | `#80D1EF` | 8.89 |
| `--on-accent` | `#F2FAFF` | 4.90 on solid |

Neutrals identical in structure to Glacier (hue 236). **Safest** — every state passes AA with no
unusual conventions, hover darkens so contrast only improves. **Cost** — the most distinctive
part of the logo becomes decoration; the product reads as generic teal-with-a-blue-accent.

### 4.3 Split

Violet survives as the action colour; neutrals de-tinted; baby blue promoted to emphasis.

| Token | Hex | Contrast vs bg-elevated |
| --- | --- | --- |
| `--accent-primary` | `#705EE0` | 3.15 (as a graphic; its label sits at 4.81) |
| `--accent-primary-hover` | `#6B59D7` | — (white fg 5.20) |
| `--accent-text` | `#B2ADFF` | 7.44 |
| `--accent-secondary` | `#80D1EF` | 8.86 |
| `--on-accent` | `#FFFFFF` | 4.81 on solid |

**Least churn** — muscle memory, docs and screenshots stay valid. **Weakest structurally** — two
saturated hues compete for attention, and the accent still appears nowhere in the logo.

---

## 5. Beyond colour: what "polished" would additionally require

Colour alone will not lift the UI from competent to exceptional. Ranked by impact per unit of
work:

1. **Fix the undefined-variable bug** (§2.3). `--text-secondary` silently degrading to full
   brightness is flattening the access panel's hierarchy right now.
2. **Tokenize the ~24 hardcoded violet literals** (§2.4). Without this, no palette change is
   complete, and dark mode / future themes stay impossible.
3. **Define an elevation model.** Today the steps between the four background tokens are only
   1.03 (base→sunken), 1.07 (base→surface) and 1.20 (base→elevated) in contrast ratio — the
   layers are nearly indistinguishable. A principled 1.05 / 1.10 / 1.26 / 1.42 ladder (as in
   Glacier above) makes layering legible without adding borders.
4. **Use the spacing scale or delete it.** `--space-1`…`--space-6` are dead tokens while
   components hardcode pixel values. Half-measures here are worse than either choice.
5. **Focus rings as a token.** Every `:focus-visible` currently restates
   `0 0 0 2px var(--bg-base), 0 0 0 4px rgba(124,108,246,0.4)`. One `--focus-ring` token would
   collapse 14 duplicated declarations and make keyboard affordances themed for free.
6. **The cream.** The logo's warm highlight (`#F6F0DE`) is unused. One high-value use — a
   hairline top highlight on elevated surfaces, or the active-tab indicator — would inject the
   logo's warmth exactly where the eye lands, at almost no contrast risk.

---

## 6. Recommendation

**Glacier, with a bone secondary accent.** It is the only candidate where the logo and the
interface share a hue, and it resolves the two defects in the current palette (the AA-failing
button label and the violet-neutral cast) rather than carrying them forward. The secondary is
`#EDE7DC` — the logo's own cream desaturated — so the palette introduces no hue the brand does
not own.

Sequenced implementation, each step independently reviewable:

1. Tokenize the hardcoded colour literals (§2.4). No visual change — pure refactor, verifiable
   by re-rendering and confirming the screenshots are pixel-identical.
2. Fix the undefined variables (§2.3). Small, real bug fixes with visual effect.
3. Introduce the accent **role split** (`--accent-primary` vs `--accent-text` vs `--on-accent`)
   so a solid fill and accent text can be different colours.
4. Land the Glacier palette.
5. Optionally: elevation ladder, `--focus-ring` token, spacing-scale adoption, cream highlight.

Steps 1–3 are prerequisites that make step 4 a one-file change — and they are worth doing under
*any* palette, which is why this document recommends them regardless of which candidate is chosen.

---

## 7. Reproducing the renders

The mockup harness lives outside the repo and is not committed. It consisted of:

- A mock gateway (`server.mjs`) serving `frontend/dist` plus fixture REST responses
  (`/api/lists`, `/api/sessions/:id/transcript`, `/api/setup`, `/api/auth/status`) and a WebSocket
  that emits `hello`, `lists`, `entry` and `activity` frames — enough for the real `App.tsx`,
  `Sidebar`, `ChatArea` and `TranscriptEntry` pipeline to render without a Haskell backend.
- A token-override stylesheet injected into `index.html`, containing the candidate palette plus a
  shim that retargets the app's hardcoded violet literals at the new tokens (the manual
  equivalent of implementation step 1).
- Playwright screenshots at 1560×980 @2x, driven to `/session/<id>` so the transcript and WS
  focus engage.

Verification performed on the renders: dominant-colour histogram per screenshot compared against
the intended token values (confirming the palette actually applied and that no violet residue
remained), and message-group counts confirming the transcript, code block and markdown table all
rendered rather than an empty shell.
