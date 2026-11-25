# Audio, Streaming ASR & Accessibility Integration Guide

Verified production patterns for connecting real microphone capture, FFT/RMS metering, streaming speech-to-text, deterministic demo drivers, and full accessibility across **React/Web** and **SwiftUI (macOS 14+ / iOS 17+)**.

---

## 1. Web / React Integration (`Web Audio API` + Streaming ASR)

See the verified reference implementation in [examples/react/ParticleDictationCard.tsx](../examples/react/ParticleDictationCard.tsx) (`useMicrophoneDictation` + `ParticleDictationCard`).

### Live Audio Metering (`AnalyserNode` + Ref-Backed 60fps Telemetry)
1. **Capture & Graph Setup:**
   - Request microphone access with `navigator.mediaDevices.getUserMedia({ audio: true })`.
   - Assign `streamRef.current = stream` and `audioCtxRef.current = new AudioContext()` **immediately** so any downstream failure can still release hardware tracks cleanly.
   - Connect `createMediaStreamSource(stream)` -> `AnalyserNode` (`fftSize = 128`, `smoothingTimeConstant = 0.78`).
2. **RMS & Frequency Band Extraction:**
   - Pre-allocate `Uint8Array(analyser.frequencyBinCount)` (frequency bins) and `Uint8Array(analyser.fftSize)` (time-domain waveform) once per session outside the `requestAnimationFrame` callback.
   - Compute centered RMS from `getByteTimeDomainData`, scale (`clamp(rms * 3.4, 0.16, 1.0)`), and fill a reusable `Float32Array(32)` from `getByteFrequencyData`.
3. **Zero-Rerender 60fps Telemetry Pattern (Critical Fix):**
   - **Do NOT call React `setState` at 60Hz inside the audio loop if `paintFrame` depends on those states** — doing so triggers 60Hz React reconciliation and tears down/restarts the main Canvas `requestAnimationFrame` loop every frame.
   - Write high-frequency `{ audioLevel, elapsedSeconds, frequencyBands }` into `telemetryRef.current` every frame.
   - Throttle React state updates (`setAudioLevel` at ~10Hz / `100ms`, `setElapsedSeconds` at 1Hz whole-second boundaries) strictly for external consumers.
   - Inside `ParticleDictationCard`, mirror changing props/refs into `latestRef.current` so `paintFrame = useCallback(..., [])` keeps a stable identity forever and the main rAF loop never restarts.

### Speech-to-Text Wiring (`SpeechRecognition` or External Streaming WebSocket)
- **Built-In Browser `SpeechRecognition`:** Detect `window.SpeechRecognition || window.webkitSpeechRecognition`, enable `continuous = true` and `interimResults = true`, and wrap `rec.start()` in an **inner `try/catch`**. If browser speech recognition is blocked or unavailable (e.g., Firefox, offline Safari, permission quirk), report `onError` while keeping the live microphone waveform running.
- **Custom Streaming ASR (Whisper, Deepgram, Gemini Live, AssemblyAI):** Use `mode="microphone"` with `mic.appendWords(chunk)` or `mode="controlled"` passing `phase`, `transcript`, `audioLevel`, `frequencyBands`, and `elapsedSeconds`.
- **Incremental Word Diffing:** When new partial/final tokens arrive, compare `tokens[i]` against existing `liveWordsRef.current[i]`. **Keep the original `launchStart`/`arriveEnd`/`blurStart`/`sharpEnd` timestamps** for unchanged prefix words so settled words never re-trigger particle flight on interim hypotheses.

### Teardown, Error Recovery & Offscreen Power Savings
- On `stop()`, `reset()`, `catch`, and component unmount: cancel audio `rAF`, stop `SpeechRecognition` inside `try/catch`, stop every `MediaStreamTrack`, and call `audioCtx.close().catch(() => {})`.
- Pause the 60fps Canvas loop when scrolled offscreen using CSS `content-visibility: auto` paired with `contentvisibilityautostatechange` (plus `IntersectionObserver` fallback with `rootMargin: '200px'`). Add outer shell paint margin (`padding` + matching negative `margin`) so paint containment does not clip the card's soft drop shadow.

---

## 2. SwiftUI / Apple Integration (`AVAudioEngine` + `Accelerate`/`vDSP` + Pluggable ASR)

See the verified Swift 6 reference implementation in [examples/swiftui/ParticleDictationCard.swift](../examples/swiftui/ParticleDictationCard.swift).

### Lock-Protected Pre-Allocated `vDSP` Audio Analysis (`AudioSpectrumAnalyzer`)
- **Zero CoreAudio-Thread Heap Churn:** Never allocate `[Float]` scratch buffers inside `inputNode.installTap(...)`. Pre-allocate `windowed` (`fftSize = 1024`), `realp` (`512`), `imagp` (`512`), `magnitudes` (`512`), and `smoothedBands` (`24`) inside `OSAllocatedUnfairLock<AnalyzerState>`.
- **Signal Pipeline:**
  1. Compute RMS via `vDSP_rmsqv` and map speech dBFS (`[-52 ... -10 dBFS]`) to `[0 ... 1]` with exponential smoothing (`0.55 / 0.45`).
  2. Multiply mono float32 PCM by a pre-computed Hann window (`vDSP_hann_window`), pack via `vDSP_ctoz`, run forward real-to-complex FFT (`vDSP_fft_zrip`), and compute squared magnitudes (`vDSP_zvmags`).
  3. Aggregate bins logarithmically into `24` speech-weighted frequency bands (`[-68 ... -16 dB]` -> `[0 ... 1]`, smoothed `0.58 / 0.42`).
  4. Destroy `FFTSetup` cleanly in `deinit` (`vDSP_destroy_fftsetup`).

### Unified Clock Epoch (Critical Fix)
- SwiftUI's `TimelineView(.animation(minimumInterval: 1.0 / 60.0))` yields `timeline.date.timeIntervalSinceReferenceDate` (~785M seconds since 2001-01-01).
- **Always stamp every audio snapshot, phase transition, recording start, and ASR word arrival with `Date().timeIntervalSinceReferenceDate`** — never `ProcessInfo.processInfo.systemUptime` (~50k seconds). Mixing epochs skips live particle flight (`elapsed` becomes huge) and breaks `phaseElapsed` button morphs.

### `AVAudioEngine` Lifecycle, Rollback & iOS `AVAudioSession`
- **iOS Session Activation (`#if os(iOS)`):** Configure `AVAudioSession.sharedInstance()` with `.setCategory(.record, mode: .measurement, options: [.duckOthers])` and `.setActive(true, options: .notifyOthersOnDeactivation)`.
- **Input Guard:** Validate `format.channelCount > 0 && format.sampleRate > 0` before installing bus-0 tap (deactivating iOS `AVAudioSession` if invalid).
- **Transactional Startup Rollback:** Wrap `engine.prepare()`, `try engine.start()`, and `try speechAdapter?.startStreaming(...)` in `do / catch`. On any failure, call `stopAudioEngine()`, clear words, reset `phase = .idle`, and rethrow so neither the tap nor the audio session leaks.
- **Clean Teardown:** Implement `DictationSource.teardown()` calling `stopAudioEngine()` + `speechAdapter?.finishStreaming()`, and invoke `source.teardown()` inside `.onDisappear`. Inside `stopAudioEngine()`, remove bus-0 tap, stop the engine, reset `latestAudio` to `.silent`, and deactivate `AVAudioSession` (`#if os(iOS)`).
- **Info.plist Keys:** Include `NSMicrophoneUsageDescription` (required on iOS/macOS) and `NSSpeechRecognitionUsageDescription` when pairing with Apple's `SFSpeechRecognizer`.

### Pluggable Speech Adapter (`DictationSpeechRecognizerAdapter`)
Implement the `Sendable` protocol to plug Apple `SFSpeechRecognizer`, WhisperKit, or a WebSocket ASR client directly into `LiveAudioEngineDictationSource`:
- `startStreaming(onPartialTranscript:onFinalTranscript:)` — forward callbacks onto `@MainActor` with `let arrival = Date().timeIntervalSinceReferenceDate` captured at callback time into `ingestRecognizedTranscript(_:isFinal:at:)`.
- `appendAudioBuffer(_ buffer: AVAudioPCMBuffer)` — invoked directly from the `AVAudioEngine` tap (e.g., pass to `SFSpeechAudioBufferRecognitionRequest.append(buffer)`).
- `finishStreaming()` — invoke `endAudio()` / close stream on user stop or teardown.
- `ingestRecognizedTranscript` updates changed tokens in place while keeping existing `launchTime` for matching word indices so live particle arcs stay steady across partial ASR edits.

---

## 3. Deterministic Demo Envelope & Visual Regression Hooks

Because the showcase video is silent, deterministic playback is invaluable for UI previews, design reviews, and automated visual regression:

- **React Component:** Pass `mode="demo"` with `demoTimeSeconds={2.50}` (freezes rAF and paints exact frame deterministically) or `demoPaused={true}` (pauses progression without resetting).
- **Standalone HTML (`examples/react/demo.html`):** Supports query parameters `?t=2.50`, `?clean=1` (hides controls for pixel diffing), `?variant=ab|a|b`, `?reduced-motion=1`, plus `window.__PDC_DEBUG__.setTime(sec)`, `getStats()`, `setReducedMotion(bool)`, and `setViewMode(mode)`.
- **SwiftUI Component:** Pass `DemoDictationSource(autoLoop: false, fixedTime: 2.50)` or `ParticleDictationCard(style: .dotMatrix, overrideTime: 2.50)` to render deterministic snapshots via `ImageRenderer` or `#Preview`.

---

## 4. Accessibility & Reduced Motion Checklist

| Requirement | Web / React Implementation | SwiftUI (macOS / iOS) Implementation |
| --- | --- | --- |
| **Reduced Motion** | Track `window.matchMedia('(prefers-reduced-motion: reduce)')` live + CSS `@media (prefers-reduced-motion: reduce)`. Skip particle flight & blur filters; snap words in cleanly; throttle waveform shimmer (`2Hz`) and keep status/wave dots steady. | Read `@Environment(\.accessibilityReduceMotion)` (with optional `reduceMotionOverride` for testing). Skip particle flight & `.blur(radius:)`; replace rapid dot/ASCII shimmer with calm static-rhythm bell bars (`drawReducedMotionWaveform`); fade words smoothly (`0.18s`). |
| **Pause / Stop / Hide (WCAG 2.2.2)** | Expose `demoPaused` prop and a visible Pause/Play toggle whenever looping demo playback is mounted. | Support `autoLoop: false` or user-controlled pause/seek on `DemoDictationSource` in continuous showcases. |
| **Screen Reader Transcript Announcement** | Mark `<canvas>` and animated word spans `aria-hidden="true"`. Render a dedicated visually-hidden `<div id={transcriptId} aria-live="polite" aria-atomic="true">` populated on completion (empty in `idle`) to avoid per-frame spam. | Apply `.accessibilityElement(children: .contain)`, `.accessibilityLabel("Voice dictation card")`, `.accessibilityValue(...)`, and emit `AccessibilityNotification.Announcement(message).post()` strictly on phase transitions (including full transcript on `.completed`). |
| **Action Button Semantics & Focus** | Point `aria-describedby={transcriptId}` at the `aria-live="polite"` region (never at hidden pre-mounted words!). Update `aria-label` by phase (`Start` / `Stop` / `Finalizing`), set `aria-disabled` in `thinking`, enforce `>= 44×44px` hit target, and show a high-contrast `:focus-visible` outline. | Provide dynamic `.accessibilityLabel` (`Start dictation` / `Stop dictation` / `Finalizing dictation`) and `.accessibilityHint(frame.phase.accessibilityDescription)` on the primary `Button`, maintaining `>= 44×44pt` touch target on iOS. |
| **Numeric Stability** | `font-variant-numeric: tabular-nums` on elapsed timer. | `.monospacedDigit()` on elapsed timer `Text`. |
