---
name: particle-dictation-ui
description: >-
  Builds a 60fps Voice-to-Text Particle Dictation Card with curved acoustic-to-typography
  particle arcs, real 4x4 offscreen glyph bitmap materialization, blur-to-sharp word resolution,
  and swappable Variant A (Paul-Bourke ASCII density) vs. Variant B (10x10 energy-dithered
  dot-matrix bloom, default) waveforms for React/HTML5 Canvas and SwiftUI/CoreText/AVAudioEngine.
  Use this skill whenever the user asks to build or customize a voice dictation UI, speech-to-text
  card, particle-to-text animation, ASCII waveform, dot-matrix bloom waveform, Murmur-style voice
  input, or a SwiftUI/React audio visualizer card.
---

# Voice-to-Text Particle Dictation Card (`particle-dictation-ui`)

Build a dark-mode, 60fps speech-to-text dictation card where live vocal energy rises from the bottom edge, launches luminous particles along curved Bézier arcs into the active text cursor, locks onto a real `4×4` glyph bitmap of each incoming word, and crossfades through a soft blur into crisp sans-serif text.

**Attribution & Clean-Room Scope:** Inspired by `@sucodeee`'s Bluma `Murmur` showcase (`https://bluma.design/c/murmur`, X status `2125331380058091832`). `Murmur` is a paid Bluma Pro component; this skill and its bundled reference implementations are clean-room reconstructions verified via FFmpeg pixel/frame analysis of the silent `1080×1080` @ 60fps video plus independent live React/Canvas and SwiftUI/CoreText/AVAudioEngine builds.

---

## Variant Selection (Default: Variant B)

Both variants share 100% identical card chrome, typography, 5-state machine, 2D heightfield, Bézier trajectories, and reset blur sweep. Only three visual primitives differ. **Default to Variant B (`dot-matrix` / `.dotMatrix`)** unless the user requests an ASCII/terminal aesthetic.

| Dimension | Variant A (`ascii` / `.ascii`) | Variant B (`dot-matrix` / `.dotMatrix`) — **Recommended** |
| --- | --- | --- |
| **Bottom Waveform Grid** | `10×16` monospace Paul-Bourke 70-char density ramp over ambient white mountain glow | `10×10` uniform square grid with 3 energy-dithered primitives (`.`, vertical `:`, glowing `8px ●` + radial bloom) |
| **Flying Speech Particles** | Crisp `~4×4` white squares with velocity-aligned comet trails | Glowing `~4–5px` white circles with comet trails and soft flight halo |
| **4×4 Glyph Assembly Mask** | Crisp `4×4` square pixel matrix (`■`) before blur-to-sharp | Glowing `4×4` circular dot matrix (`•`) before blur-to-sharp |

---

## Core Design Tokens & State Machine

Scale proportionally from the `1080p` reference (`878×270`, `scale = width / 878`; desktop `0.68`, compact `0.45`):

- **Surfaces & Chrome:** Stage `#0D0D0D`, card `#1E1E1E`, hairline border `1–1.5px` `#272727`–`#292929`, continuous radius `38–40px`.
- **Typography:** Neutral sans (`Geist`, `SF Pro`, `Inter`) at `31–32px` / `41px` line-height (`~1.3×`), inset `38px` left / `40px` top; placeholder `#747474`, finalized transcript `#E7E7E7`. Monospace for Variant A: `Geist Mono` / `SF Mono`.
- **Status Indicator (Top-Right):** `#FDFDFD` dot (`8.5–10px`) + `#777777`–`#7A7A7A` tabular numerals (`font-variant-numeric: tabular-nums` / `.monospacedDigit()`).
- **Action Button (Bottom-Right):** `82px` circle at `28px` right / `39–40px` bottom inset (`min 44×44` tap target), `#343434` fill, `#3C3C3C`–`#424242` rim stroke, `#F0F0F0` icons (`mic` <-> `stop ■` <-> `•••`).

```text
idle ("Tap the key and speak", mic)
  └─[start]─▶ listening ("Listening..." fades on speech, stop ■, "• 0:00..0:06", mountain wave + particle arcs)
                └─[stop / 7.15s]─▶ thinking (tail words finish settling 7.15s–7.95s, pulsing "• thinking", 1.00s 3-dot wave •••, low simmer)
                                     └─[finalize / 9.32s]─▶ completed (crisp text, mic, status fades, wave collapses by 10.00s)
                                                              └─[reset / 12.53s]─▶ resetting (530ms L-to-R blur sweep -> blank -> placeholder in) ─▶ idle
```

Read [references/motion-spec.md](./references/motion-spec.md) for the exact 60fps timeline, heightfield/dithering formulas, Bézier arc + comet equations, `4×4` sampling math, and `1.00s` 3-dot luminance wave (`124..244`, `0.15s` lag).

---

## Implementation Workflow

1. **Select target starter & inspect the verified reference implementation:**
   - **React / HTML5 Canvas:** Start from [examples/react/ParticleDictationCard.tsx](./examples/react/ParticleDictationCard.tsx) and standalone interactive preview [examples/react/demo.html](./examples/react/demo.html).
   - **SwiftUI (macOS 14+ & iOS 17+, Swift 6):** Start from [examples/swiftui/ParticleDictationCard.swift](./examples/swiftui/ParticleDictationCard.swift).
2. **Implement the shared 2D heightfield & 5-state machine:**
   - Drive both Variant A and Variant B from one normalized mountain heightfield `h(u, t)` shaped by a Gaussian core + outer skirt and modulated by RMS + frequency bands (or synthesized syllable envelope in demo mode).
   - Keep `thinking` tail-word overlap (`7.15s–7.95s` in demo; live ASR finalization flush in production) so final words finish landing smoothly while `• thinking` and `•••` begin.
3. **Implement the swappable Variant A / Variant B Canvas renderer:**
   - **Variant A:** Map local cell energy onto the 70-char Paul-Bourke ramp and distribute dense-core cells across the top 10 heavy glyphs (`*#MW&8%B@$`) instead of saturating every core cell on `@`/`$`.
   - **Variant B:** Use energy-weighted stochastic halftone dithering across `.`, `:`, and `8px ●` + bloom so even the dense base dynamically mixes all three primitives.
4. **Wire real `4×4` offscreen glyph rasterization & curved particle arcs:**
   - Never substitute fake placeholder rectangles or random clouds. Rasterize each word using exact rendered font metrics: offscreen `<canvas>` `fillText` + alpha sampling aligned to DOM word `getBoundingClientRect()` (React), or CoreText `CTLine` -> 2× oversampled grayscale `CGContext` (SwiftUI).
   - Launch particles from the active waveform crest along quadratic Bézier arcs with velocity-aligned comet tails, **tapering particle head size and fading flight halos as `u -> 1.0`** before crossfading the `4×4` matrix into blurred -> sharp text.
5. **Connect live audio & streaming ASR (or deterministic demo driver):**
   - Follow [references/audio-asr-integration.md](./references/audio-asr-integration.md) for Web Audio `AnalyserNode` + `SpeechRecognition`/custom WebSocket streaming (`appendWords`) or `AVAudioEngine` + `Accelerate`/`vDSP` + `DictationSpeechRecognizerAdapter` (`SFSpeechRecognizer` / WhisperKit / cloud ASR).
   - Preserve each word's initial launch timestamp on incremental ASR updates so settled words never re-launch particles mid-sentence.
6. **Enforce accessibility & reduced motion:**
   - Respect `prefers-reduced-motion` (Web) and `@Environment(\.accessibilityReduceMotion)` (SwiftUI): disable particle flight and Gaussian blur, fade words cleanly, and calm the waveform.
   - Expose Pause/Play controls for looping demos (WCAG 2.2.2) and announce completed transcripts via debounced `aria-live="polite"` or `AccessibilityNotification.Announcement`.
7. **Verify build, rendering, and invariants:** Run the validation script and checks below.

---

## Verified Engineering Pitfalls (Caught & Solved)

Avoid these nine verified failure modes discovered during independent audit:

### Web / React + HTML5 Canvas
1. **Never use per-dot `ctx.shadowBlur` in 60fps Canvas:** Pre-bake radial bloom sprites (drawn in a second additive `globalCompositeOperation = 'lighter'` pass) and a HiDPI Paul-Bourke ASCII glyph atlas once per DPR. Verified result: `60.01 fps`, `0.70ms` avg / `1.50ms` p95 draw across two simultaneous cards.
2. **Never `setState` at 60Hz inside a rAF `useEffect` dependency chain:** Keep 60fps microphone telemetry (`audioLevel`, `elapsedSeconds`, `frequencyBands`) in `telemetryRef`, sync high-frequency props/callbacks through `latestRef` so `paintFrame` has `[]` dependencies (zero rAF teardown), throttle reactive state to ~10Hz level / 1Hz whole-second timer, and `useMemo` word records (`demoLiveWords`).
3. **Never point `aria-describedby` at an `aria-hidden="true"` pre-mounted transcript:** Under AccName 1.2, referencing a pre-mounted hidden word container leaks future words in `idle`. Put `id={transcriptId}` on the dedicated `aria-live="polite"` region (empty on `idle`, populated on completion).
4. **Guard mic startup against partial-init leaks:** Assign `stream` and `AudioContext` immediately before wiring nodes, wrap `SpeechRecognition.start()` in an inner `try/catch` (keeping the live mic waveform running if speech API fails), and run full track/context cleanup in outer `catch` and unmount.

### SwiftUI + CoreText + `AVAudioEngine`
5. **Unify clocks on `Date().timeIntervalSinceReferenceDate`:** Never mix `ProcessInfo.processInfo.systemUptime` (~50k s) with `TimelineView`'s `timeline.date.timeIntervalSinceReferenceDate` (~785M s) — clock skew causes live particle arcs and `4×4` glyph masks to be skipped entirely.
6. **Pre-allocate `vDSP` FFT buffers inside `OSAllocatedUnfairLock`:** Never allocate `[Float]` arrays or mutate unsynchronized state inside an `AVAudioEngine` CoreAudio tap callback. Hold pre-allocated `windowed`, `realp`, `imagp`, `magnitudes`, and `smoothedBands` buffers inside an `OSAllocatedUnfairLock<AnalyzerState>`.
7. **Roll back `AVAudioEngine` on failure and wire `teardown()`:** Wrap `engine.start()` + `speechAdapter?.startStreaming()` in `do/catch` calling `stopAudioEngine()` on error, wire `source.teardown()` to `.onDisappear`, and deactivate `AVAudioSession` on stop (`#if os(iOS)`).
8. **Drive live button morphs from `phaseElapsed`, not demo timestamps:** Compute `dictationButtonMorphWeights(phase:phaseElapsed:)` uniformly across demo and live sources so `mic <-> stop ■ <-> •••` morphs work identically in production.
9. **Taper landing particle heads/halos & cache CoreText layouts:** Shrink flying particle heads (`particleSize -> glyphCellDrawSize`) and fade flight halos as `rawP -> 1.0` so adjacent `4×4` cells stay crisp and legible instead of fusing into an over-bloomed bar; cache `CTFont`, space advance, and `[LaidOutWord]` in `CoreTextGlyphSampler`.

---

## Validation Checklist

Run the bundled verification script after making changes or copying examples into a host app:

```bash
./scripts/verify_skill_examples.sh
```

Confirm all checks pass:
- **Skill integrity:** `SKILL.md` frontmatter matches folder name, all relative links resolve, and zero stale internal paths exist.
- **SwiftUI (macOS 14+ & iOS 17+ Simulator):** Zero errors and zero warnings under `swiftc -swift-version 6 -warnings-as-errors -parse-as-library -typecheck`.
- **React TSX & Demo HTML:** Zero strict TypeScript errors (`--strict --noUnusedLocals --noUnusedParameters --noEmit`) when `tsc` + `@types/react` are present; `demo.html` passes inline JS syntax check and renders with `0` console/page errors at ~60fps (`window.__PDC_DEBUG__.setTime(2.50)` / `getStats()`).
- **Accessibility:** Verify `?reduced-motion=1` (Web) or `reduceMotionOverride: true` (SwiftUI) disables blur & flying particles cleanly, and `aria-live="polite"` is empty on `idle`.

---

## Bundled Files

- [references/motion-spec.md](./references/motion-spec.md) — Exact 1080p geometry, color tokens, 60fps timeline, Variant A/B waveform math, Bézier + `4×4` glyph equations, and FFmpeg provenance.
- [references/audio-asr-integration.md](./references/audio-asr-integration.md) — Live Web Audio/`SpeechRecognition` and `AVAudioEngine`/`Accelerate`/`vDSP`/ASR wiring, demo envelopes, and accessibility checklists.
- [examples/react/ParticleDictationCard.tsx](./examples/react/ParticleDictationCard.tsx) — Production React + HTML5 Canvas component & `useMicrophoneDictation` hook.
- [examples/react/demo.html](./examples/react/demo.html) — Zero-build interactive A/B comparison & live microphone playground.
- [examples/swiftui/ParticleDictationCard.swift](./examples/swiftui/ParticleDictationCard.swift) — Production Swift 6 SwiftUI + CoreText + `AVAudioEngine`/`vDSP` component & comparison showcase.
- [scripts/verify_skill_examples.sh](./scripts/verify_skill_examples.sh) — Automated frontmatter, link, Swift 6 (macOS/iOS), TypeScript, and `demo.html` verifier.
