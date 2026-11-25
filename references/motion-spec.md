# Motion, Geometry & Visual Specification — Voice-to-Text Particle Dictation Card

Verified cross-platform visual, geometric, temporal, and mathematical specification for both **Variant A (ASCII Density)** and **Variant B (Dot-Matrix Bloom, recommended default)**.

---

## 1. Measurement Provenance & Attribution

- **Source Inspiration:** `@sucodeee`'s Bluma **Murmur** showcase (`https://x.com/sucodeee/status/2125331380058091832`, `https://bluma.design/c/murmur`, `family: Inputs`, added `2026-11-24`, `mic: true`, Pro plan). Public catalog metadata confirms Web/React/SwiftUI targets and `Geist` / `Geist Mono` typography. All specifications and bundled code in this skill are **clean-room reconstructions** derived solely from public showcase video pixel analysis and independently verified builds.
- **Analyzed Video Stream (`ffprobe` ground truth):**
  - Container: MP4 (`isom`/`isomiso4`), `2,465,564` bytes.
  - Video #0: H.264 (`avc1`, High Profile L4.2), `1080×1080` (`1:1`), `yuv420p` progressive, `r_frame_rate = 60/1` (`avg_frame_rate ≈ 59.856 fps`), `841` frames, `14.050s`, `1,395,312` bps.
  - Audio: **None (`nb_streams: 1`, 0 audio streams)** — speech energy in the showcase is simulated deterministically.
- **Measurement Methods:** `fps=2` full-frame extraction (`28` PNGs), full 841-frame scene-score profiling (max monochrome frame delta `0.006159`, calibrated threshold `gt(scene,0.003)` -> `37` peak-motion keyframes), `34` targeted state-boundary frames (`0.05s–0.20s` steps), 2×/4× nearest-neighbor waveform/particle/glyph crops, and Python/NumPy pixel measurements.

---

## 2. Exact 1080p Proportional Geometry & Color Palette

All measurements are taken directly from the `1080×1080` stacked A/B canvas (`scale = width / 878.0`; recommended presets: `reference1080p = 1.0`, `desktop = 0.68`, `compact = 0.45`).

### Surface, Border & Typography Tokens

| Token | 1080p Measurement (`scale = 1.0`) | Color / Style |
| --- | --- | --- |
| **Canvas Stage Background** | `1080 × 1080 px` | `#0D0D0D`–`#101010` |
| **Card Container Bounds** | `878 × 270 px` (Card A `x=101..978, y=216..485`; Card B vertical pitch `472 px`) | Fill `#1E1E1E` (`rgb(30,30,30)`) |
| **Card Corner Radius** | `38–40 px` continuous rounded rect (`dx = 36–37` at `dy = 0`) | SwiftUI `.continuous` / CSS `border-radius` |
| **Card Hairline Border** | `1.0–1.5 px` stroke | `#272727`–`#292929` (subtle `#2E2E2E -> #252525` top-to-bottom bevel) |
| **Card Ambient Drop Shadow** | Soft drop shadow extending `~35–40 px` below card | `rgba(0, 0, 0, 0.55)` |
| **Transcript / Placeholder Font** | `31–32 px` regular, `41 px` line-height (`~1.3×`), `38 px` left / `40 px` top inset (`34 px` CoreText top offset to match cap-line `y=256`) | `Geist`, `SF Pro Display/Text`, `Inter`; placeholder `#747474`, finalized `#E7E7E7` |
| **Top-Right Status Badge** | Aligned with Line 1 (`top ~40–45 px`, `right ~34–36 px`), dot `8.5–10 px`, text `21 px` | Dot `#FDFDFD`; text `#777777`–`#7A7A7A` with `tabular-nums` / `.monospacedDigit()` |
| **Bottom-Right Action Button** | `82 px` circle (`center (909, 405)` in Card A), **`28 px` right inset** / **`39–40 px` bottom inset** (enforce min `44×44` tap target when scaled down) | Fill `#343434`, rim stroke `#3C3C3C`–`#424242` (`~#404040`), icon `#F0F0F0` |
| **A / B Presentation Badges** | `56 × 56 px` circle centered horizontally (`x = 512..567`, `y = 130` & `602`) | Fill `#EFEFEF`, bold dark letter `#111111` |

---

## 3. Frame-Accurate 60fps State Machine & Reference Timeline

Total seamless loop duration: **`14.05s`** (`841` frames @ 60fps).

### Verbatim Showcase Copy
- Idle placeholder: `Tap the key and speak`
- Pre-speech listening placeholder: `Listening...`
- Recording timer values: `0:00`, `0:01`, `0:02`, `0:03`, `0:04`, `0:05`, `0:06`
- Finalizing status label: `thinking`
- Complete transcript (**17 words across 2 lines**: `8` words on Line 1 + `9` words on Line 2):
  ```text
  Remind me to call Maya tomorrow morning, then
  book a quiet table for two by the river.
  ```

### Timeline Breakdown (`t = frame / 60`)

| Phase | Time Range | Frames | Exact Transitions & Visual Behavior |
| --- | --- | --- | --- |
| **1. `idle`** | `0.00s – 0.50s` | `0 – 30` | Muted `#747474` `Tap the key and speak`. Circular `#343434` button with `#F0F0F0` outline mic. No status badge, no waveform. |
| **2. Start Transition** | `0.50s – 0.70s` | `30 – 42` | `~180–200ms`: placeholder crossfades to `Listening...`; button morphs `mic -> stop ■` (scale + blur + opacity + `~4.5%` subtle press bounce); `• 0:00` fades in; mountain waveform begins rising at `0.55s–0.57s`. |
| **3. `listening` (Pre-Speech)** | `0.70s – 1.90s` | `42 – 114` | Low murmur (`0.70–1.00s`), strong burst starting `1.02s`. Timer ticks `0:01` at `1.48s`. `Listening...` blurs out (`6.5–8px`) and fades to `0` across `1.70s–2.00s`. |
| **4. `listening` (Live Particle Streaming)** | `1.90s – 7.15s` | `114 – 429` | 60fps waveform pulses with speech energy while particles arc from wave crest into word positions (`particle flight -> 4×4 glyph mask -> blur-to-sharp`). Timer ticks: `0:02` (`2.45s`), `0:03` (`3.43s`), `0:04` (`4.42s`), `0:05` (`5.40s`), `0:06` (`6.40s`). |
| **5. `thinking` (Overlap Window)** | `7.15s – 9.32s` | `429 – 559` | At `7.15s`: status switches to breathing `• thinking`; button morphs `stop ■ -> •••` (`160–180ms`) into `1.00s` L-to-R brightness wave; waveform settles to a low simmering ripple (2–3 rows in A, 3–4 rows in B). **Tail overlap (`7.15s–7.95s`):** final words (`by the river.`) finish landing and sharpening during `thinking`. |
| **6. `completed` (Collapse)** | `9.32s – 10.00s` | `559 – 600` | At `9.32s`: `• thinking` fades out (`180ms`), button morphs `••• -> mic` (`180–200ms`), and simmering waveform collapses smoothly to `0` by `10.00s`. |
| **7. `completed` (Static Hold)** | `10.00s – 12.50s` | `600 – 750` | Crisp 2-line `#E7E7E7` transcript + idle mic button for `2.50s`. Cards A and B are pixel-identical (`mean abs diff ≈ 0.41 / 255` from H.264 noise). |
| **8. `resetting` & Loop** | `12.53s – 14.05s` | `752 – 840` | **`530ms` L-to-R staggered blur + fade-out sweep** (`12.53s–13.07s`, Line 1 then Line 2) -> **`630ms` blank hold** (`13.07s–13.70s`) -> **`200ms` placeholder unblur-in** (`13.70s–13.90s`), looping cleanly at `14.00s–14.05s`. |

---

## 4. Shared 2D Mountain Heightfield & Swappable Waveform Renderers

Both variants read the same normalized horizontal ridge height `h(u, t) ∈ [0, 1]` over `u ∈ [-1, 1]` (centered slightly left of the action button in full-width layouts, or centered within `~78%` of card width with right-edge tapering so waves never collide with the circular button).

### Shared Heightfield & Ambient Glow
- **Spatial silhouette:** Sum of a tight Gaussian peak (`exp(-3.55 u²)` or `exp(-(2.35 u)²)`) plus a broader base skirt (`0.36 * exp(-1.55 u²)`), multiplied by left/right edge guards and active envelope `amp ∈ [0, 1]` (`0` in idle/hold, `~0.24–0.34` in `thinking` simmer, `1.0` peak in `listening`).
- **Acoustic modulation:** Map `|u|` logarithmically or linearly into live FFT spectrum bins (low-mid vocal formants centered at the peak, higher frequencies on the outer skirts) blended with RMS loudness and multi-harmonic traveling surface ripples.
- **Ambient backdrop glow:** Soft white radial gradient anchored just below the bottom center of the card (`peak alpha ≈ 0.14–0.17 * envelope`), shared behind both A and B grids.

### Variant A — Monospace Paul-Bourke ASCII Density Field
- **Grid:** `10 × 16 px` cells (scaled by `scale`), up to `~63–65` columns × `8–10` visible rows.
- **70-Character Luminance Ramp (sparse -> dense):**
  ```text
   .'`^",:;Il!i><~+_-?][}{1)(|\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$
  ```
- **Dense-Core Distribution:** Prevent high-energy bottom-center cells from saturating solely onto the final character `$`/`@`. When normalized cell intensity exceeds `~0.74`, distribute character selection across the top 10 dense symbols (`*#MW&8%B@$`) using a temporal spatial hash (`12–18 Hz` shimmer bucket).
- **60fps Performance Pattern:**
  - **HTML5 Canvas:** Pre-render all 70 characters once per DPR onto a single HiDPI horizontal strip canvas (`asciiAtlas`) and blit via `drawImage` + `globalAlpha`.
  - **SwiftUI `Canvas`:** Maintain a per-frame `[Character: GraphicsContext.ResolvedText]` cache inside the draw closure so each distinct glyph is resolved at most once per frame.

### Variant B (Recommended) — `10×10` Energy-Dithered Dot-Matrix Bloom
- **Grid:** Uniform `10 × 10 px` square grid (scaled by `scale`), up to `~55–65` columns × `14–16` visible rows.
- **3 Discrete Non-Empty Primitives:**
  1. **Single faint bottom dot (`.`):** Diameter `~2.2–2.4 px`, shifted slightly below cell center (`+1.6..2.1 px`), opacity `~0.20–0.64`.
  2. **Vertical 2-dot colon (`:`):** Two `~2.35–2.7 px` circles separated vertically by `~4.1–4.6 px`, opacity `~0.32–0.86`.
  3. **Glowing solid white orb (`●`):** `~7.8–8.0 px` diameter pure white `#FFFFFF` circle paired with a soft radial bloom (`~26–29 px` diameter / `14.5 px` radius).
- **Energy-Weighted Stochastic Halftone Dithering:** Verified on 4× ultra crops (`crop_B_dots_ultra`), even the brightest bottom-center core is **never** a solid sheet of `●` orbs — it dynamically mixes `~45–55% ●`, `~30–40% :`, and `~10–20% .` using a `13–14 Hz` temporal-spatial hash modulated by cell energy.
- **60fps Bloom Performance Pattern:**
  - **HTML5 Canvas:** Never call `ctx.shadowBlur`. Pre-bake a `48×48` radial gradient sprite (`bloomSprite`) once per DPR, draw crisp `.`, `:`, and `●` cores in Pass 1, then blit `bloomSprite` over queued `●` centers in Pass 2 using `ctx.globalCompositeOperation = 'lighter'`.
  - **SwiftUI `Canvas`:** Queue glowing orbs during the grid walk, draw soft radial-gradient halos first, then draw crisp `#FFFFFF` orb cores cleanly on top.

---

## 5. Three-Stage Acoustic-to-Typography Pipeline

Every incoming word flows through three overlapping stages:

### Stage 1 — Quadratic Bézier Particle Arcs, Comet Tails & Landing Taper
- **Launch Stagger:** Cells within a word stagger left-to-right combined with deterministic per-cell scatter: `stagger = normX * 0.62 + r1 * 0.38` (or `launchDelay = normX * 0.16 + r1 * 0.12`, `flightDuration ≈ 0.28–0.46s`).
- **Trajectory:**
  $$B(u) = (1-u)^2 P_0 + 2(1-u)u P_1 + u^2 P_2, \qquad u = 1 - (1 - \text{rawP})^{k} \quad (k \in [1.65, 2.05])$$
  - $P_0$ (spawn): along the active bottom mountain crest near `waveCenterX ± spread`, `y = waveBottomY - crestH`.
  - $P_1$ (elevated control point): midpoint horizontally with slight lateral curve + random jitter, elevated above `min(P_0.y, P_2.y)` to form the signature sweeping upward-then-horizontal arc.
  - $P_2$ (target): exact center `(tx, ty)` of the sampled `4×4` glyph cell.
- **Velocity-Aligned Comet Trail:** Stroke a linear-gradient line from `head = B(u)` to `tail = B(max(0, u - tailSpan))` where `tailSpan` peaks mid-flight (`sin(rawP * π)`) and collapses toward `0` on arrival (`1 - rawP * 0.72..0.90`).
- **Critical Landing Head & Halo Taper:** As `rawP -> 1.0` (final `~22–34%` of flight):
  - Taper flying head size from flight size (`4.0–4.2 px`) down to settled cell draw size (`~2.6–3.4 px`).
  - Fade the flight halo to `0` (`landingHaloFade = 1 - smoothstep(0.66..0.72, 1.0, rawP)`).
  - *Why:* Prevents arriving particles from over-blooming neighboring `4×4` cells into an illegible white bar.
- **Flyer Cap (Web Canvas):** For long words with >44 sampled cells, retain flying comet streaks for a deterministic subset (`clamp(round(word.length * 6.5), 14, 44)`) while all cells still lock into the `4×4` bitmap upon arrival.

### Stage 2 — Real `4×4` Offscreen Glyph Bitmap Rasterization
- **Web / React (`sampleWordGlyphCells`):** Measure each rendered `<span class="pdc-word">` via `getBoundingClientRect()` and `getComputedStyle()`, draw the word in `#FFFFFF` onto a reused offscreen `<canvas>` with identical font metrics, and alpha-sample `4×4 px` blocks (`avgAlpha >= 0.14 || maxAlpha >= 0.52`). Across the 17-word reference transcript, this yields `~1,162` authentic stroke cells.
- **SwiftUI (`CoreTextGlyphSampler`):** Measure and draw `CTLine` onto a 2× oversampled 8-bit `CGColorSpaceCreateDeviceGray()` `CGContext`, then sample `4×4` logical grid cells using mean-weighted coverage (`meanNorm * 0.90 + peakNorm * 0.10 >= 0.24`) so interior letter counters (`e`, `o`, `a`, `d`) remain open and legible. Cache `CTFont`, space advance, word masks, and `[LaidOutWord]` layouts under `OSAllocatedUnfairLock`.
- **Visual Primitives:** Variant A draws crisp `4×4` square pixels (`fillRect`); Variant B draws glowing circular dots (`arc` / `ellipseIn`) with subtle low-alpha micro-halo on dense stroke cells.

### Stage 3 — Blur-to-Sharp Resolution & `530ms` Staggered Reset Sweep
- **Word Unblur Crossfade (`~320–340ms`):** After the word's `4×4` bitmap locks in, fade the vector text opacity `0 -> 1` while reducing Gaussian blur `7.5 px -> 0` (scaled by `scale`) as the `4×4` canvas mask simultaneously fades out (`1 -> 0`).
- **Staggered L-to-R Reset Sweep (`530ms` total):** For word index `i` out of `N` words:
  - `wordDelay = (i / max(1, N - 1)) * 0.34`
  - `clearProgress = smoothstep((resetElapsed - wordDelay) / 0.19..0.20)`
  - `opacity = 1 - clearProgress`, `blur = clearProgress * (9.0..9.5 * scale)`

---

## 6. Micro-Interaction Polish Specs

- **Button Icon Morphs (`mic <-> stop ■ <-> •••`):** Duration `160–200ms`, driven solely by `phaseElapsed` (source-agnostic across demo and live modes):
  - Outgoing weight `1 - smoothstep(0, 0.10..0.18, phaseElapsed)`, incoming weight `smoothstep(0.06..0, 0.18..0.19, phaseElapsed)`.
  - Apply `scale = 0.55..0.58 + 0.42..0.45 * weight`, `blur = (1 - weight) * 4.0 * scale`, `opacity = weight`.
  - Subtle `4.5%` tactile press bounce (`1 - sin(...) * 0.045`) on `idle -> listening` trigger.
- **Thinking `•••` Traveling Luminance Wave:** Three `~6 px` circular dots (`~5–5.5 px` gap) oscillating smoothly left-to-right:
  - **Period:** `1.00s` (60 frames @ 60fps).
  - **Phase lag per dot:** `0.15s` (`dotIndex * 0.15`).
  - **Grayscale range:** `124..244` (`124/255 .. 244/255`).
- **`• thinking` Status Dot Breathing:** Smooth sinusoidal opacity (`~0.54..1.00`) and optional subtle scale (`0.88..1.00`) over `~1.0–1.15s` cycle; static `1.0` under reduced motion.
- **Timer Stability:** Always enforce `font-variant-numeric: tabular-nums` (CSS) and `.monospacedDigit()` (SwiftUI) on `0:00..0:06` so digits never jitter horizontally.
