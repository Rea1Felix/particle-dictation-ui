import React, {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
} from 'react';

/* ============================================================================
 * Types & Public API
 * ========================================================================== */

export type ParticleDictationVariant = 'ascii' | 'dot-matrix';

export type DictationPhase =
  | 'idle'
  | 'listening'
  | 'thinking'
  | 'completed'
  | 'resetting';

export type DictationMode = 'demo' | 'microphone' | 'controlled';

export interface ParticleDictationCardProps {
  /** Visual rendering style: 'ascii' (Variant A) or 'dot-matrix' (Variant B, default). */
  variant?: ParticleDictationVariant;
  /** Execution mode: deterministic video demo loop, live Web Audio mic, or fully controlled. */
  mode?: DictationMode;
  /** Deterministic timestamp in seconds (0..14.05) to scrub/freeze demo playback. */
  demoTimeSeconds?: number | null;
  /** Pause/resume demo playback (WCAG 2.2.2 Pause, Stop, Hide). */
  demoPaused?: boolean;
  /** Loop demo continuously when true (default true). */
  demoLoop?: boolean;
  /** Override demo transcript lines (default matches the 2-line reference showcase). */
  demoLines?: [string, string] | string[];
  /** Controlled phase when mode="controlled". */
  phase?: DictationPhase;
  /** Controlled transcript string when mode="controlled". */
  transcript?: string;
  /** Controlled normalized audio amplitude 0..1 when mode="controlled". */
  audioLevel?: number;
  /** Controlled frequency band levels (values 0..1) when mode="controlled". */
  frequencyBands?: Float32Array | number[];
  /** Controlled elapsed recording seconds when mode="controlled". */
  elapsedSeconds?: number;
  /** Placeholder text in idle state. */
  placeholder?: string;
  /** Placeholder text during initial listening before first word lands. */
  listeningPlaceholder?: string;
  /** Label shown during thinking state. */
  thinkingLabel?: string;
  /** Logical card width in CSS pixels (default 878). Scales cleanly via responsive container. */
  width?: number;
  /** Logical card height in CSS pixels (default 270). */
  height?: number;
  /** Optional prefix to disambiguate accessible button names when multiple cards render on one page. */
  ariaLabelPrefix?: string;
  /** Callback when state machine phase changes. */
  onPhaseChange?: (phase: DictationPhase) => void;
  /** Callback when transcript text updates. */
  onTranscriptChange?: (transcript: string) => void;
  /** Optional click handler for the action button (overrides default toggle when returning false). */
  onActionClick?: (currentPhase: DictationPhase) => boolean | void;
  /** Callback for microphone / SpeechRecognition errors. */
  onError?: (error: Error) => void;
  /** Optional frame telemetry callback (dtMs, drawMs, fps) for profiling. */
  onFrameMetrics?: (metrics: { dtMs: number; drawMs: number; fps: number }) => void;
  className?: string;
  style?: React.CSSProperties;
}

export interface MicrophoneDictationState {
  phase: DictationPhase;
  transcript: string;
  audioLevel: number;
  frequencyBands: Float32Array;
  elapsedSeconds: number;
  /** Zero-rerender 60fps ref-backed audio telemetry for Canvas loops. */
  telemetryRef: React.RefObject<{
    audioLevel: number;
    elapsedSeconds: number;
    frequencyBands: Float32Array;
  }>;
  isSupported: boolean;
  hasSpeechRecognition: boolean;
  error: Error | null;
  start: () => Promise<void>;
  stop: () => void;
  reset: () => void;
  /** Append externally transcribed words (e.g. Whisper/Deepgram streaming WebSocket). */
  appendWords: (words: string) => void;
}

/* ============================================================================
 * Design Tokens & Reference Timeline Constants (Calibrated to 1080x1080 @ 60fps)
 * ========================================================================== */

export const DEMO_LOOP_DURATION = 14.05;

export const DEFAULT_DEMO_LINES: readonly string[] = [
  'Remind me to call Maya tomorrow morning, then',
  'book a quiet table for two by the river.',
];

// Paul-Bourke 70-level ASCII luminance ramp (sparse -> dense)
const ASCII_RAMP =
  " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$";

interface WordTimingSpec {
  text: string;
  line: number;
  launchStart: number;
  arriveEnd: number;
  blurStart: number;
  sharpEnd: number;
}

// Frame-accurate schedule matched to reference contact sheet (17 words across 2 lines)
const DEFAULT_WORD_TIMINGS: ReadonlyArray<[number, number, number, number]> = [
  [1.86, 2.46, 2.66, 3.00], // 0: Remind (fully locked 4x4 bitmap at t=2.5s)
  [2.14, 2.74, 2.94, 3.26], // 1: me (actively landing at t=2.5s)
  [2.38, 3.02, 3.24, 3.56], // 2: to (particles arcing mid-flight at t=2.5s)
  [2.78, 3.36, 3.58, 3.88], // 3: call
  [3.12, 3.68, 3.84, 4.12], // 4: Maya (crisp before t=4.2s)
  [3.52, 4.24, 4.38, 4.72], // 5: tomorrow (4x4 bitmap assembling at t=4.2s)
  [3.96, 4.66, 4.86, 5.18], // 6: morning, (particles arcing at t=4.2s)
  [4.56, 5.16, 5.34, 5.66], // 7: then
  [4.88, 5.44, 5.62, 5.90], // 8: book
  [5.22, 5.64, 5.78, 6.02], // 9: a
  [5.40, 5.94, 6.12, 6.44], // 10: quiet
  [5.70, 6.22, 6.38, 6.64], // 11: table
  [5.96, 6.44, 6.58, 6.82], // 12: for
  [6.20, 6.70, 6.86, 7.12], // 13: two
  [6.48, 6.94, 7.08, 7.32], // 14: by
  [6.72, 7.16, 7.30, 7.56], // 15: the
  [7.00, 7.50, 7.66, 7.95], // 16: river. (finishes landing during thinking overlap)
];

const TIMER_TICKS = [0.5, 1.48, 2.45, 3.43, 4.42, 5.4, 6.4];

interface GlyphCell {
  /** Card-local target X (center of 4x4 cell) */
  tx: number;
  /** Card-local target Y (center of 4x4 cell) */
  ty: number;
  /** Normalized rasterized ink weight 0..1 */
  weight: number;
  /** Deterministic per-cell randoms for synchronized A/B trajectories */
  r1: number;
  r2: number;
  r3: number;
  r4: number;
  /** Normalized launch stagger 0..1 within its word */
  stagger: number;
  /** Whether this cell carries an explicit flying comet particle */
  hasFlyer: boolean;
}

interface WordRect {
  x: number;
  y: number;
  width: number;
  height: number;
  font: string;
}

interface LiveWordRecord {
  key: string;
  text: string;
  launchStart: number;
  arriveEnd: number;
  blurStart: number;
  sharpEnd: number;
}

/* ============================================================================
 * Deterministic Math & Value Noise Utilities (Zero GC Allocation in Hot Loop)
 * ========================================================================== */

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

function smoothstep(edge0: number, edge1: number, x: number): number {
  const t = clamp((x - edge0) / (edge1 - edge0), 0, 1);
  return t * t * (3 - 2 * t);
}

function hash2i(x: number, y: number, seed: number): number {
  let h = (x * 374761393 + y * 668265263 + seed * 1442695041) | 0;
  h = ((h ^ (h >>> 13)) * 1274126177) | 0;
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

function smoothCellNoise(col: number, row: number, timeSec: number, rateHz: number): number {
  const t = timeSec * rateHz;
  const ti = Math.floor(t);
  const tf = t - ti;
  const s = tf * tf * (3 - 2 * tf);
  const a = hash2i(col, row, ti);
  const b = hash2i(col, row, ti + 1);
  return a + (b - a) * s;
}

function formatTimer(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const mins = Math.floor(s / 60);
  const secs = s % 60;
  return `${mins}:${secs < 10 ? '0' : ''}${secs}`;
}

/* ============================================================================
 * Offscreen Canvas Sprites & Real 4x4 Glyph Bitmap Sampler
 * ========================================================================== */

interface PrebakedAssets {
  bloomSprite: HTMLCanvasElement;
  particleBloomSprite: HTMLCanvasElement;
  asciiAtlas: HTMLCanvasElement;
  asciiCellW: number;
  asciiCellH: number;
  dpr: number;
}

function createPrebakedAssets(dpr: number): PrebakedAssets {
  const safeDpr = clamp(dpr || 1, 1, 3);

  // 1. Pre-baked radial bloom sprite for Variant B 8px glowing dots (zero shadowBlur stalls)
  const bloomSize = 48;
  const bloomSprite = document.createElement('canvas');
  bloomSprite.width = bloomSize;
  bloomSprite.height = bloomSize;
  const bctx = bloomSprite.getContext('2d');
  if (bctx) {
    const half = bloomSize / 2;
    const g = bctx.createRadialGradient(half, half, 1.5, half, half, half);
    g.addColorStop(0.0, 'rgba(255, 255, 255, 0.72)');
    g.addColorStop(0.24, 'rgba(255, 255, 255, 0.34)');
    g.addColorStop(0.55, 'rgba(255, 255, 255, 0.10)');
    g.addColorStop(1.0, 'rgba(255, 255, 255, 0.0)');
    bctx.fillStyle = g;
    bctx.fillRect(0, 0, bloomSize, bloomSize);
  }

  // 2. Smaller tight halo sprite for flying particles & settled glyph dots
  const pSize = 28;
  const particleBloomSprite = document.createElement('canvas');
  particleBloomSprite.width = pSize;
  particleBloomSprite.height = pSize;
  const pctx = particleBloomSprite.getContext('2d');
  if (pctx) {
    const half = pSize / 2;
    const g = pctx.createRadialGradient(half, half, 0.5, half, half, half);
    g.addColorStop(0.0, 'rgba(255, 255, 255, 0.65)');
    g.addColorStop(0.32, 'rgba(255, 255, 255, 0.22)');
    g.addColorStop(1.0, 'rgba(255, 255, 255, 0.0)');
    pctx.fillStyle = g;
    pctx.fillRect(0, 0, pSize, pSize);
  }

  // 3. Pre-rendered HiDPI monochrome Paul-Bourke ASCII glyph strip for 60fps Variant A
  const asciiCellW = 10;
  const asciiCellH = 16;
  const asciiAtlas = document.createElement('canvas');
  asciiAtlas.width = Math.ceil(ASCII_RAMP.length * asciiCellW * safeDpr);
  asciiAtlas.height = Math.ceil(asciiCellH * safeDpr);
  const actx = asciiAtlas.getContext('2d');
  if (actx) {
    actx.scale(safeDpr, safeDpr);
    actx.font =
      '500 13.5px "Geist Mono", "SF Mono", "JetBrains Mono", ui-monospace, Menlo, Consolas, monospace';
    actx.textAlign = 'center';
    actx.textBaseline = 'middle';
    actx.fillStyle = '#F2F2F2';
    for (let i = 0; i < ASCII_RAMP.length; i++) {
      const ch = ASCII_RAMP[i];
      if (ch !== ' ') {
        actx.fillText(ch, i * asciiCellW + asciiCellW * 0.5, asciiCellH * 0.52);
      }
    }
  }

  return {
    bloomSprite,
    particleBloomSprite,
    asciiAtlas,
    asciiCellW,
    asciiCellH,
    dpr: safeDpr,
  };
}

/**
 * Real offscreen canvas glyph rasterizer: draws the actual word string using
 * the DOM's exact computed font metrics, then alpha-samples it onto a 4x4 px
 * grid aligned directly to the word's bounding box.
 */
export function sampleWordGlyphCells(
  word: string,
  rect: WordRect,
  wordIndex: number,
  scratchCanvas?: HTMLCanvasElement
): GlyphCell[] {
  const pad = 4;
  const w = Math.max(4, Math.ceil(rect.width) + pad * 2);
  const h = Math.max(4, Math.ceil(rect.height) + pad * 2);
  const canvas = scratchCanvas || document.createElement('canvas');
  if (canvas.width < w) canvas.width = w;
  if (canvas.height < h) canvas.height = h;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!ctx) return [];

  ctx.clearRect(0, 0, w, h);
  ctx.font = rect.font;
  ctx.fillStyle = '#FFFFFF';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';

  // Align text vertically inside the DOM span's line box
  const metrics = ctx.measureText(word);
  const ascent =
    typeof metrics.fontBoundingBoxAscent === 'number'
      ? metrics.fontBoundingBoxAscent
      : rect.height * 0.78;
  const descent =
    typeof metrics.fontBoundingBoxDescent === 'number'
      ? metrics.fontBoundingBoxDescent
      : rect.height * 0.22;
  const glyphBoxH = ascent + descent;
  const verticalOffset = Math.max(0, (rect.height - glyphBoxH) * 0.5);

  ctx.fillText(word, pad, pad + verticalOffset);

  const imgData = ctx.getImageData(0, 0, w, h).data;
  const step = 4;
  const cells: GlyphCell[] = [];
  const startX = pad;
  const startY = pad;
  const endX = pad + Math.ceil(rect.width);
  const endY = pad + Math.ceil(rect.height);

  for (let gy = startY; gy < endY; gy += step) {
    for (let gx = startX; gx < endX; gx += step) {
      let sumAlpha = 0;
      let maxAlpha = 0;
      let count = 0;
      for (let dy = 0; dy < step && gy + dy < h; dy++) {
        const rowOff = (gy + dy) * w;
        for (let dx = 0; dx < step && gx + dx < w; dx++) {
          const a = imgData[(rowOff + gx + dx) * 4 + 3] / 255;
          sumAlpha += a;
          if (a > maxAlpha) maxAlpha = a;
          count++;
        }
      }
      const avgAlpha = count > 0 ? sumAlpha / count : 0;
      if (avgAlpha >= 0.14 || maxAlpha >= 0.52) {
        const idx = cells.length;
        const r1 = hash2i(wordIndex * 97 + idx, 11, 1337);
        const r2 = hash2i(wordIndex * 97 + idx, 23, 7331);
        const r3 = hash2i(wordIndex * 97 + idx, 37, 4242);
        const r4 = hash2i(wordIndex * 97 + idx, 53, 9001);
        const normX = clamp((gx - startX) / Math.max(1, rect.width), 0, 1);
        // Left-to-right arrival wave with organic scatter
        const stagger = clamp(normX * 0.62 + r1 * 0.38, 0, 1);
        cells.push({
          tx: rect.x + (gx - startX) + step * 0.5,
          ty: rect.y + (gy - startY) + step * 0.5,
          weight: clamp(avgAlpha * 1.55 + maxAlpha * 0.25, 0.28, 1.0),
          r1,
          r2,
          r3,
          r4,
          stagger,
          hasFlyer: true,
        });
      }
    }
  }

  // Cap active flying comet trails per word (~34..46) to match video arc density cleanly
  const maxFlyers = clamp(Math.round(word.length * 6.5), 14, 44);
  if (cells.length > maxFlyers) {
    const keepRatio = maxFlyers / cells.length;
    for (let i = 0; i < cells.length; i++) {
      cells[i].hasFlyer = cells[i].r4 <= keepRatio;
    }
  }

  return cells;
}

/* ============================================================================
 * Deterministic Demo Envelope & Shared 2D Mountain Heightfield
 * ========================================================================== */

function computeDemoWaveAmplitude(t: number): number {
  if (t < 0.55 || t >= 10.0) return 0;

  // Smooth rise at start of listening (0.55s -> 0.85s)
  if (t < 1.02) {
    const rise = smoothstep(0.55, 0.82, t);
    return rise * (0.28 + 0.14 * Math.sin(t * 9.5));
  }

  // Active speech energy (1.02s -> 7.15s) with organic syllable modulation
  if (t < 7.15) {
    const ramp = smoothstep(0.96, 1.15, t);
    const syllables =
      0.82 +
      0.13 * Math.sin(t * 3.8 + 0.9) +
      0.09 * Math.sin(t * 8.1 - 0.6) +
      0.06 * Math.cos(t * 13.7 + 0.4);
    return clamp(ramp * syllables, 0.56, 1.0);
  }

  // Thinking state low simmering ripple (7.15s -> 9.32s)
  if (t < 9.32) {
    const settle = 1 - smoothstep(7.15, 7.62, t);
    const simmer = 0.23 + 0.04 * Math.sin(t * 5.2) + 0.025 * Math.cos(t * 9.4);
    return lerp(simmer, 0.72, settle);
  }

  // Graceful collapse downward (9.32s -> 10.00s)
  const collapse = 1 - smoothstep(9.32, 9.98, t);
  return collapse * 0.24;
}

function computeDemoPhase(t: number): DictationPhase {
  if (t < 0.5) return 'idle';
  if (t < 7.15) return 'listening';
  if (t < 9.32) return 'thinking';
  if (t < 12.53) return 'completed';
  return 'resetting';
}

function computeDemoTimerLabel(t: number): string {
  let sec = 0;
  for (let i = 0; i < TIMER_TICKS.length; i++) {
    if (t >= TIMER_TICKS[i]) sec = i;
  }
  return formatTimer(sec);
}

/**
 * Shared 2D mountain ridge height h(u, t) ∈ [0, 1] used identically by
 * Variant A (ASCII density) and Variant B (Dot-Matrix).
 */
function sampleMountainRidge(
  u: number,
  t: number,
  amp: number,
  bands?: Float32Array | number[] | null
): number {
  if (amp <= 0.004) return 0;

  // Bell-curve central mountain with smooth outer skirts
  const shiftedU = u + 0.06 * Math.sin(t * 1.9);
  const coreBell = Math.exp(-3.55 * shiftedU * shiftedU);
  const wideSkirt = 0.36 * Math.exp(-1.55 * u * u);

  // Taper right edge gently before the circular bottom-right action button
  const rightGuard = 1 - smoothstep(0.62, 0.98, u);
  const leftGuard = 1 - smoothstep(0.76, 1.02, -u);

  let modulation: number;
  if (bands && bands.length > 0) {
    // Map center peak to low-mid voice formants, skirts to higher frequencies
    const dist = Math.abs(u);
    const binF = clamp(dist * (bands.length * 0.65), 0, bands.length - 1);
    const i0 = Math.floor(binF);
    const i1 = Math.min(bands.length - 1, i0 + 1);
    const frac = binF - i0;
    const binVal = lerp(bands[i0] || 0, bands[i1] || 0, frac);
    modulation = 0.42 + 0.88 * binVal + 0.16 * Math.sin(u * 9.5 + t * 5.2);
  } else {
    const h1 = 0.22 * Math.sin(u * 4.8 - t * 3.7);
    const h2 = 0.18 * Math.sin(u * 9.7 + t * 6.4);
    const h3 = 0.11 * Math.cos(u * 17.3 - t * 9.2);
    const peakBreath = 0.84 + 0.22 * Math.sin(t * 5.1 + u * 2.2);
    modulation = clamp(peakBreath + h1 + h2 + h3, 0.25, 1.35);
  }

  return clamp((coreBell * 0.78 + wideSkirt) * modulation * amp * rightGuard * leftGuard, 0, 1.05);
}

/* ============================================================================
 * Canvas Renderer (Variant A ASCII, Variant B Dot-Matrix, Flying Particles, 4x4 Glyphs)
 * ========================================================================== */

interface RenderFrameInput {
  ctx: CanvasRenderingContext2D;
  assets: PrebakedAssets;
  width: number;
  height: number;
  variant: ParticleDictationVariant;
  timeSec: number;
  waveAmp: number;
  frequencyBands?: Float32Array | number[] | null;
  words: ReadonlyArray<LiveWordRecord>;
  wordGlyphMap: Map<string, GlyphCell[]>;
  reducedMotion: boolean;
}

function renderDictationCanvas(input: RenderFrameInput): void {
  const {
    ctx,
    assets,
    width,
    height,
    variant,
    timeSec,
    waveAmp,
    frequencyBands,
    words,
    wordGlyphMap,
    reducedMotion,
  } = input;

  ctx.clearRect(0, 0, width, height);

  const scale = width / 878;
  const waveCenterX = width * 0.478;
  const waveHalfWidth = width * 0.415;
  const maxWaveHeight = height * 0.62;
  const waveBottomY = height - 4 * scale;

  /* ------------------------------------------------------------------------
   * 1. Ambient Mountain Glow Behind Waveform (Shared by A & B)
   * ---------------------------------------------------------------------- */
  if (waveAmp > 0.01) {
    const glowR = (145 + waveAmp * 145) * scale;
    const glowY = waveBottomY + 18 * scale;
    const g = ctx.createRadialGradient(
      waveCenterX,
      glowY,
      10 * scale,
      waveCenterX,
      glowY - waveAmp * 46 * scale,
      glowR
    );
    const peakAlpha = clamp(waveAmp * (variant === 'dot-matrix' ? 0.17 : 0.14), 0, 0.18);
    g.addColorStop(0.0, `rgba(255, 255, 255, ${peakAlpha.toFixed(3)})`);
    g.addColorStop(0.45, `rgba(255, 255, 255, ${(peakAlpha * 0.36).toFixed(3)})`);
    g.addColorStop(1.0, 'rgba(255, 255, 255, 0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, height * 0.25, width, height * 0.75);
  }

  /* ------------------------------------------------------------------------
   * 2. Waveform Grid (Variant A: ASCII Density Field | Variant B: 10x10 Dots)
   * ---------------------------------------------------------------------- */
  const animT = reducedMotion ? Math.floor(timeSec * 2) * 0.5 : timeSec;

  if (waveAmp > 0.012) {
    if (variant === 'ascii') {
      const cellW = 10 * scale;
      const cellH = 16 * scale;
      const cols = Math.floor((waveHalfWidth * 2) / cellW);
      const rows = Math.ceil(maxWaveHeight / cellH) + 1;
      const startX = waveCenterX - (cols * cellW) * 0.5;
      const srcW = assets.asciiCellW * assets.dpr;
      const srcH = assets.asciiCellH * assets.dpr;
      const rampLen = ASCII_RAMP.length - 1;

      for (let col = 0; col < cols; col++) {
        const cx = startX + (col + 0.5) * cellW;
        const u = (cx - waveCenterX) / waveHalfWidth;
        const ridge = sampleMountainRidge(u, animT, waveAmp, frequencyBands);
        if (ridge <= 0.025) continue;

        const maxRow = Math.min(rows, Math.ceil((ridge * maxWaveHeight) / cellH) + 1);
        for (let row = 0; row < maxRow; row++) {
          const v = ((row + 0.45) * cellH) / maxWaveHeight;
          const depth = ridge - v;
          if (depth < -0.055) continue;

          const bodyEnergy = smoothstep(-0.05, 0.24, depth);
          const shimmer = smoothCellNoise(col, row, animT, reducedMotion ? 1.5 : 15);
          const coreBoost = (1 - v) * 0.22;
          const intensity = clamp(bodyEnergy * (0.58 + 0.56 * shimmer) + coreBoost * bodyEnergy, 0, 1);

          // Sparse fringe speckles right above the mountain slope
          if (depth < 0 && shimmer < 0.78) continue;

          // Distribute dense core evenly across *#MW&8%B@$ instead of saturating at final char '$'
          const charSeed = smoothCellNoise(col + 31, row + 17, animT, reducedMotion ? 1.2 : 12);
          let charIdx: number;
          if (intensity >= 0.74) {
            const denseStart = rampLen - 10;
            charIdx = clamp(denseStart + Math.floor(charSeed * 11), denseStart, rampLen);
          } else {
            charIdx = clamp(Math.round((intensity / 0.74) * (rampLen - 10)), 1, rampLen - 10);
          }
          const alpha = clamp(0.20 + intensity * 0.76, 0.16, 0.94);

          ctx.globalAlpha = alpha;
          ctx.drawImage(
            assets.asciiAtlas,
            charIdx * srcW,
            0,
            srcW,
            srcH,
            startX + col * cellW,
            waveBottomY - (row + 1) * cellH,
            cellW,
            cellH
          );
        }
      }
      ctx.globalAlpha = 1;
    } else {
      // Variant B: 10x10 luminous dot-matrix with 3 discrete primitives (`.`, `:`, `●` + pre-baked bloom)
      const pitch = 10 * scale;
      const cols = Math.floor((waveHalfWidth * 2) / pitch);
      const rows = Math.ceil(maxWaveHeight / pitch) + 1;
      const startX = waveCenterX - (cols * pitch) * 0.5;
      const bloomDrawSize = 26 * scale;
      const bloomHalf = bloomDrawSize * 0.5;

      // Pass 1: crisp dots (`.`, `:`, `●`)
      const glowDots: Array<{ x: number; y: number; alpha: number }> = [];

      for (let col = 0; col < cols; col++) {
        const cx = startX + (col + 0.5) * pitch;
        const u = (cx - waveCenterX) / waveHalfWidth;
        const ridge = sampleMountainRidge(u, animT, waveAmp, frequencyBands);
        if (ridge <= 0.02) continue;

        const maxRow = Math.min(rows, Math.ceil((ridge * maxWaveHeight) / pitch) + 1);
        for (let row = 0; row < maxRow; row++) {
          const cy = waveBottomY - (row + 0.5) * pitch;
          const v = ((row + 0.5) * pitch) / maxWaveHeight;
          const depth = ridge - v;
          if (depth < -0.05) continue;

          const body = smoothstep(-0.045, 0.22, depth);
          const shimmer = smoothCellNoise(col, row, animT, reducedMotion ? 1.5 : 13);
          // Energy-dithered core: dynamically mixes ●, :, and . even in bottom core (matches crop_B_dots_ultra)
          const signal = body * (0.18 + 0.96 * shimmer);

          if (signal < 0.14) continue;

          if (signal < 0.34) {
            // Primitive 1: single faint dot `.`
            const a = clamp(0.24 + (signal - 0.14) * 1.6, 0.22, 0.56);
            ctx.fillStyle = `rgba(220, 220, 220, ${a.toFixed(3)})`;
            ctx.beginPath();
            ctx.arc(cx, cy + 2.1 * scale, 1.2 * scale, 0, Math.PI * 2);
            ctx.fill();
          } else if (signal < 0.67) {
            // Primitive 2: vertical 2-dot colon `:`
            const a = clamp(0.46 + (signal - 0.34) * 1.2, 0.45, 0.86);
            ctx.fillStyle = `rgba(236, 236, 236, ${a.toFixed(3)})`;
            const dotR = 1.35 * scale;
            const sep = 2.3 * scale;
            ctx.beginPath();
            ctx.arc(cx, cy - sep, dotR, 0, Math.PI * 2);
            ctx.arc(cx, cy + sep, dotR, 0, Math.PI * 2);
            ctx.fill();
          } else {
            // Primitive 3: bright solid 8px glowing circle `●`
            const intensity = clamp((signal - 0.67) / 0.33, 0, 1);
            const r = (3.55 + intensity * 0.45) * scale;
            ctx.fillStyle = '#FFFFFF';
            ctx.beginPath();
            ctx.arc(cx, cy, r, 0, Math.PI * 2);
            ctx.fill();
            glowDots.push({ x: cx, y: cy, alpha: 0.42 + intensity * 0.45 });
          }
        }
      }

      // Pass 2: Additive pre-baked radial bloom sprites (rock-solid 60fps)
      if (glowDots.length > 0) {
        ctx.save();
        ctx.globalCompositeOperation = 'lighter';
        for (let i = 0; i < glowDots.length; i++) {
          const gd = glowDots[i];
          ctx.globalAlpha = gd.alpha * 0.55;
          ctx.drawImage(
            assets.bloomSprite,
            gd.x - bloomHalf,
            gd.y - bloomHalf,
            bloomDrawSize,
            bloomDrawSize
          );
        }
        ctx.restore();
      }
    }
  }

  /* ------------------------------------------------------------------------
   * 3. Flying Speech Particles (Bézier Arcs + Velocity-Aligned Comet Trails)
   *    & Stage-2 4x4 Bitmap Glyph Lock-In (Square for A, Circular for B)
   * ---------------------------------------------------------------------- */
  if (reducedMotion || words.length === 0) return;

  const haloSize = 14 * scale;
  const haloHalf = haloSize * 0.5;
  const sqSize = 3.3 * scale;
  const dotRadius = 1.72 * scale;

  for (let wIdx = 0; wIdx < words.length; wIdx++) {
    const word = words[wIdx];
    // Skip words not yet launched or fully resolved to crisp DOM text
    if (timeSec < word.launchStart || timeSec > word.sharpEnd + 0.05) continue;

    const cells = wordGlyphMap.get(word.key);
    if (!cells || cells.length === 0) continue;

    const launchSpan = Math.max(0.26, word.arriveEnd - word.launchStart);
    const flightDuration = clamp(launchSpan * 0.58, 0.28, 0.36);
    const staggerSpan = Math.max(0.06, launchSpan - flightDuration);

    // Crossfade bitmap fade-out as DOM text unblurs in
    const bitmapFadeOut =
      timeSec >= word.blurStart
        ? 1 - smoothstep(word.blurStart, lerp(word.blurStart, word.sharpEnd, 0.72), timeSec)
        : 1;

    if (bitmapFadeOut <= 0.005) continue;

    for (let cIdx = 0; cIdx < cells.length; cIdx++) {
      const cell = cells[cIdx];
      const cellLaunch = word.launchStart + cell.stagger * staggerSpan;
      const cellArrive = cellLaunch + flightDuration;

      if (timeSec < cellLaunch) continue;

      if (timeSec < cellArrive) {
        // ---- Stage 1: Particle in flight along curved Quadratic Bézier arc ----
        if (!cell.hasFlyer) continue;

        const rawU = clamp((timeSec - cellLaunch) / flightDuration, 0, 1);
        // Smooth ease-out curve for crisp deceleration into letter lock-in
        const u = 1 - Math.pow(1 - rawU, 2.05);

        // Spawn from the active bottom waveform crest/body
        const x0 = waveCenterX + (cell.r1 - 0.5) * (150 * scale);
        const crestH = Math.max(38 * scale, waveAmp * maxWaveHeight * (0.42 + cell.r2 * 0.52));
        const y0 = waveBottomY - crestH;

        const x2 = cell.tx;
        const y2 = cell.ty;

        // Elevated Bézier control point creates the signature sweeping upward-then-horizontal arc
        const dx = x2 - x0;
        const cpx = x0 + dx * 0.42 + (dx < 0 ? 48 : -36) * scale + (cell.r3 - 0.5) * 44 * scale;
        const cpy = Math.min(y0, y2) - (16 + cell.r2 * 44) * scale;

        const invU = 1 - u;
        const px = invU * invU * x0 + 2 * invU * u * cpx + u * u * x2;
        const py = invU * invU * y0 + 2 * invU * u * cpy + u * u * y2;

        // Velocity-aligned comet tail that gracefully tapers down as particle locks into glyph
        const tailLenU = (0.048 + 0.036 * Math.sin(rawU * Math.PI)) * (1 - rawU * 0.72);
        const tailU = Math.max(0, u - tailLenU);
        const invT = 1 - tailU;
        const tx = invT * invT * x0 + 2 * invT * tailU * cpx + tailU * tailU * x2;
        const ty = invT * invT * y0 + 2 * invT * tailU * cpy + tailU * tailU * y2;

        const headAlpha =
          smoothstep(0, 0.12, rawU) * (0.84 + 0.16 * cell.weight) * bitmapFadeOut;

        // Velocity-aligned tapered comet trail
        const trailGrad = ctx.createLinearGradient(px, py, tx, ty);
        trailGrad.addColorStop(0, `rgba(255, 255, 255, ${(headAlpha * 0.68).toFixed(3)})`);
        trailGrad.addColorStop(0.55, `rgba(255, 255, 255, ${(headAlpha * 0.22).toFixed(3)})`);
        trailGrad.addColorStop(1, 'rgba(255, 255, 255, 0)');
        ctx.strokeStyle = trailGrad;
        ctx.lineWidth = (variant === 'ascii' ? 2.1 : 2.3) * scale;
        ctx.lineCap = 'round';
        ctx.beginPath();
        ctx.moveTo(px, py);
        ctx.lineTo(tx, ty);
        ctx.stroke();

        // Soft halo behind flying head (fades smoothly as particle lands into crisp 4x4 glyph)
        const landingHaloFade = 1 - smoothstep(0.72, 1.0, rawU);
        if (landingHaloFade > 0.02) {
          ctx.globalAlpha = headAlpha * (variant === 'dot-matrix' ? 0.65 : 0.4) * landingHaloFade;
          ctx.drawImage(
            assets.particleBloomSprite,
            px - haloHalf,
            py - haloHalf,
            haloSize,
            haloSize
          );
          ctx.globalAlpha = 1;
        }

        // Particle head: Crisp 4x4 square (Variant A) vs Luminous circle (Variant B), tapering to cell size on lock-in
        ctx.fillStyle = `rgba(255, 255, 255, ${headAlpha.toFixed(3)})`;
        const landT = smoothstep(0.78, 1.0, rawU);
        if (variant === 'ascii') {
          const ps = lerp(4.0, 3.3, landT) * scale;
          ctx.fillRect(px - ps * 0.5, py - ps * 0.5, ps, ps);
        } else {
          ctx.beginPath();
          ctx.arc(px, py, lerp(2.25, 1.72, landT) * scale, 0, Math.PI * 2);
          ctx.fill();
        }
      } else {
        // ---- Stage 2: 4x4 Bitmap Glyph Cell Locked In Place ----
        const settlePop = smoothstep(cellArrive, cellArrive + 0.06, timeSec);
        const alpha = clamp(cell.weight * settlePop * bitmapFadeOut * 0.96, 0, 1);
        if (alpha <= 0.02) continue;

        if (variant === 'ascii') {
          // Variant A: crisp 4x4 grid square pixels
          ctx.fillStyle = `rgba(244, 244, 244, ${alpha.toFixed(3)})`;
          ctx.fillRect(
            cell.tx - sqSize * 0.5,
            cell.ty - sqSize * 0.5,
            sqSize,
            sqSize
          );
        } else {
          // Variant B: glowing 4x4 grid circular dots
          if (cell.weight > 0.65) {
            ctx.globalAlpha = alpha * 0.28;
            ctx.drawImage(
              assets.particleBloomSprite,
              cell.tx - haloHalf * 0.72,
              cell.ty - haloHalf * 0.72,
              haloSize * 0.72,
              haloSize * 0.72
            );
            ctx.globalAlpha = 1;
          }
          ctx.fillStyle = `rgba(248, 248, 248, ${alpha.toFixed(3)})`;
          ctx.beginPath();
          ctx.arc(cell.tx, cell.ty, dotRadius, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }
  }
}

/* ============================================================================
 * Real Microphone Hook (Web Audio AnalyserNode + Optional Web Speech API)
 * ========================================================================== */

interface BrowserSpeechRecognitionEvent {
  resultIndex: number;
  results: {
    length: number;
    [index: number]: {
      isFinal: boolean;
      0: { transcript: string };
    };
  };
}

interface BrowserSpeechRecognition {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: BrowserSpeechRecognitionEvent) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
  abort: () => void;
}

type SpeechRecognitionCtor = new () => BrowserSpeechRecognition;

function getSpeechRecognitionCtor(): SpeechRecognitionCtor | null {
  if (typeof window === 'undefined') return null;
  const w = window as unknown as {
    SpeechRecognition?: SpeechRecognitionCtor;
    webkitSpeechRecognition?: SpeechRecognitionCtor;
  };
  return w.SpeechRecognition || w.webkitSpeechRecognition || null;
}

export function useMicrophoneDictation(options?: {
  lang?: string;
  thinkingHoldMs?: number;
  onPhaseChange?: (phase: DictationPhase) => void;
  onTranscriptChange?: (transcript: string) => void;
  onError?: (error: Error) => void;
}): MicrophoneDictationState {
  const [phase, setPhase] = useState<DictationPhase>('idle');
  const [transcript, setTranscript] = useState<string>('');
  const [audioLevel, setAudioLevel] = useState<number>(0);
  const [elapsedSeconds, setElapsedSeconds] = useState<number>(0);
  const [error, setError] = useState<Error | null>(null);

  const bandsRef = useRef<Float32Array>(new Float32Array(32));
  const telemetryRef = useRef({
    audioLevel: 0,
    elapsedSeconds: 0,
    frequencyBands: bandsRef.current,
  });
  const lastStateSyncMsRef = useRef<number>(0);
  const lastWholeSecondRef = useRef<number>(-1);
  const streamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const recognitionRef = useRef<BrowserSpeechRecognition | null>(null);
  const rafRef = useRef<number | null>(null);
  const startTimeRef = useRef<number>(0);
  const thinkingTimerRef = useRef<number | null>(null);
  const optionsRef = useRef(options);
  optionsRef.current = options;

  const isSupported =
    typeof window !== 'undefined' &&
    typeof navigator !== 'undefined' &&
    Boolean(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  const hasSpeechRecognition = Boolean(getSpeechRecognitionCtor());

  const updatePhase = useCallback((next: DictationPhase) => {
    setPhase(next);
    optionsRef.current?.onPhaseChange?.(next);
  }, []);

  const cleanupAudio = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
    if (recognitionRef.current) {
      try {
        recognitionRef.current.stop();
      } catch {
        // Ignore already-stopped SpeechRecognition
      }
      recognitionRef.current = null;
    }
    if (streamRef.current) {
      streamRef.current.getTracks().forEach((track) => track.stop());
      streamRef.current = null;
    }
    if (audioCtxRef.current) {
      audioCtxRef.current.close().catch(() => {});
      audioCtxRef.current = null;
    }
    analyserRef.current = null;
  }, []);

  const stop = useCallback(() => {
    cleanupAudio();
    updatePhase('thinking');
    telemetryRef.current.audioLevel = 0.24;
    setAudioLevel(0.24);
    const holdMs = optionsRef.current?.thinkingHoldMs ?? 1200;
    if (thinkingTimerRef.current !== null) {
      window.clearTimeout(thinkingTimerRef.current);
    }
    thinkingTimerRef.current = window.setTimeout(() => {
      telemetryRef.current.audioLevel = 0;
      setAudioLevel(0);
      bandsRef.current.fill(0);
      updatePhase('completed');
    }, holdMs);
  }, [cleanupAudio, updatePhase]);

  const start = useCallback(async () => {
    if (!isSupported) {
      const err = new Error('Web Audio microphone capture is unavailable in this browser.');
      setError(err);
      optionsRef.current?.onError?.(err);
      return;
    }
    if (thinkingTimerRef.current !== null) {
      window.clearTimeout(thinkingTimerRef.current);
      thinkingTimerRef.current = null;
    }
    cleanupAudio();
    setError(null);
    setTranscript('');
    telemetryRef.current.audioLevel = 0;
    telemetryRef.current.elapsedSeconds = 0;
    lastWholeSecondRef.current = 0;
    lastStateSyncMsRef.current = 0;
    setElapsedSeconds(0);

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;
      const AudioCtx =
        window.AudioContext ||
        (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
      const audioCtx = new AudioCtx();
      audioCtxRef.current = audioCtx;
      const source = audioCtx.createMediaStreamSource(stream);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 128;
      analyser.smoothingTimeConstant = 0.78;
      source.connect(analyser);

      analyserRef.current = analyser;
      startTimeRef.current = performance.now();
      updatePhase('listening');

      const freqData = new Uint8Array(analyser.frequencyBinCount);
      const timeData = new Uint8Array(analyser.fftSize);

      const sampleLoop = () => {
        if (!analyserRef.current) return;
        analyserRef.current.getByteFrequencyData(freqData);
        analyserRef.current.getByteTimeDomainData(timeData);

        let sumSq = 0;
        for (let i = 0; i < timeData.length; i++) {
          const centered = (timeData[i] - 128) / 128;
          sumSq += centered * centered;
        }
        const rms = Math.sqrt(sumSq / timeData.length);
        const normalizedRms = clamp(rms * 3.4, 0.16, 1.0);

        const outBands = bandsRef.current;
        const binStep = Math.max(1, Math.floor(freqData.length / outBands.length));
        for (let i = 0; i < outBands.length; i++) {
          outBands[i] = clamp((freqData[i * binStep] || 0) / 225, 0, 1);
        }

        const nowMs = performance.now();
        const elapsedSec = (nowMs - startTimeRef.current) / 1000;
        // Write 60fps audio telemetry to ref without triggering 60Hz React re-renders
        telemetryRef.current.audioLevel = normalizedRms;
        telemetryRef.current.elapsedSeconds = elapsedSec;

        // Throttle reactive state updates for external consumers (~10Hz level, 1Hz whole-second timer)
        if (nowMs - lastStateSyncMsRef.current >= 100) {
          lastStateSyncMsRef.current = nowMs;
          setAudioLevel(normalizedRms);
        }
        const wholeSec = Math.floor(elapsedSec);
        if (wholeSec !== lastWholeSecondRef.current) {
          lastWholeSecondRef.current = wholeSec;
          setElapsedSeconds(wholeSec);
        }
        rafRef.current = requestAnimationFrame(sampleLoop);
      };
      rafRef.current = requestAnimationFrame(sampleLoop);

      // Optional browser SpeechRecognition hook (falls back cleanly to external appendWords)
      const Ctor = getSpeechRecognitionCtor();
      if (Ctor) {
        try {
          const rec = new Ctor();
          rec.continuous = true;
          rec.interimResults = true;
          rec.lang = optionsRef.current?.lang ?? 'en-US';
          rec.onresult = (event) => {
            let assembled = '';
            for (let i = 0; i < event.results.length; i++) {
              assembled += event.results[i][0].transcript;
            }
            const trimmed = assembled.trim();
            setTranscript(trimmed);
            optionsRef.current?.onTranscriptChange?.(trimmed);
          };
          rec.onerror = (ev) => {
            if (ev.error !== 'no-speech' && ev.error !== 'aborted') {
              const err = new Error(`SpeechRecognition error: ${ev.error}`);
              setError(err);
              optionsRef.current?.onError?.(err);
            }
          };
          rec.start();
          recognitionRef.current = rec;
        } catch (recErr) {
          // Keep live microphone waveform running even if SpeechRecognition fails to start
          const err = recErr instanceof Error ? recErr : new Error(String(recErr));
          optionsRef.current?.onError?.(err);
        }
      }
    } catch (e) {
      cleanupAudio();
      const err = e instanceof Error ? e : new Error(String(e));
      setError(err);
      updatePhase('idle');
      optionsRef.current?.onError?.(err);
    }
  }, [cleanupAudio, isSupported, updatePhase]);

  const reset = useCallback(() => {
    if (thinkingTimerRef.current !== null) {
      window.clearTimeout(thinkingTimerRef.current);
      thinkingTimerRef.current = null;
    }
    cleanupAudio();
    setTranscript('');
    telemetryRef.current.audioLevel = 0;
    telemetryRef.current.elapsedSeconds = 0;
    lastWholeSecondRef.current = -1;
    setAudioLevel(0);
    setElapsedSeconds(0);
    bandsRef.current.fill(0);
    updatePhase('idle');
  }, [cleanupAudio, updatePhase]);

  const appendWords = useCallback((words: string) => {
    setTranscript((prev) => {
      const next = prev ? `${prev} ${words.trim()}` : words.trim();
      optionsRef.current?.onTranscriptChange?.(next);
      return next;
    });
  }, []);

  useEffect(() => {
    return () => {
      if (thinkingTimerRef.current !== null) {
        window.clearTimeout(thinkingTimerRef.current);
      }
      cleanupAudio();
    };
  }, [cleanupAudio]);

  return {
    phase,
    transcript,
    audioLevel,
    frequencyBands: bandsRef.current,
    elapsedSeconds,
    telemetryRef,
    isSupported,
    hasSpeechRecognition,
    error,
    start,
    stop,
    reset,
    appendWords,
  };
}

/* ============================================================================
 * Scoped Component Stylesheet (Injected Once, Zero External CSS Dependencies)
 * ========================================================================== */

const STYLE_TAG_ID = 'particle-dictation-card-styles';

const COMPONENT_CSS = `
.pdc-shell {
  content-visibility: auto;
  contain-intrinsic-size: auto 270px;
  display: inline-block;
  max-width: 100%;
  box-sizing: border-box;
  /* Extra paint margin prevents content-visibility paint containment from clipping the soft ambient shadow */
  padding: 20px 36px 52px 36px;
  margin: -20px -36px -52px -36px;
}

.pdc-card {
  position: relative;
  --pdc-scale: 1;
  color-scheme: only dark;
  background-color: #1E1E1E;
  color: #E7E7E7;
  border: 1.5px solid #282828;
  border-radius: calc(38px * var(--pdc-scale));
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.03),
    0 22px 44px rgba(0, 0, 0, 0.56),
    0 4px 14px rgba(0, 0, 0, 0.36);
  overflow: hidden;
  box-sizing: border-box;
  font-family: "Geist", -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Inter", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  user-select: text;
}

.pdc-canvas {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  pointer-events: none;
  z-index: 2;
}

.pdc-text-layer {
  position: absolute;
  top: calc(40px * var(--pdc-scale));
  left: calc(38px * var(--pdc-scale));
  right: calc(170px * var(--pdc-scale));
  z-index: 1;
  font-size: calc(31px * var(--pdc-scale));
  line-height: calc(41px * var(--pdc-scale));
  font-weight: 400;
  letter-spacing: -0.015em;
  color: #E7E7E7;
}

.pdc-placeholder {
  position: absolute;
  top: 0;
  left: 0;
  margin: 0;
  color: #747474;
  white-space: nowrap;
  pointer-events: none;
  will-change: opacity, filter;
}

.pdc-transcript {
  position: relative;
  margin: 0;
  color: #E7E7E7;
}

.pdc-line {
  display: block;
  min-height: calc(41px * var(--pdc-scale));
}

.pdc-word {
  display: inline-block;
  white-space: pre;
  will-change: opacity, filter;
}

.pdc-status {
  position: absolute;
  top: calc(45px * var(--pdc-scale));
  right: calc(36px * var(--pdc-scale));
  z-index: 3;
  display: inline-flex;
  align-items: center;
  gap: calc(10px * var(--pdc-scale));
  font-size: calc(21px * var(--pdc-scale));
  line-height: calc(28px * var(--pdc-scale));
  font-weight: 400;
  color: #787878;
  font-variant-numeric: tabular-nums;
  pointer-events: none;
  will-change: opacity;
}

.pdc-status-dot {
  width: calc(10px * var(--pdc-scale));
  height: calc(10px * var(--pdc-scale));
  border-radius: 50%;
  background-color: #FDFDFD;
  flex-shrink: 0;
  will-change: opacity, transform;
}

.pdc-action-btn {
  position: absolute;
  right: calc(28px * var(--pdc-scale));
  bottom: calc(40px * var(--pdc-scale));
  z-index: 4;
  width: calc(82px * var(--pdc-scale));
  height: calc(82px * var(--pdc-scale));
  min-width: 44px;
  min-height: 44px;
  border-radius: 50%;
  border: 1px solid #3E3E3E;
  background-color: #343434;
  color: #F0F0F0;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  padding: 0;
  outline: none;
  transition: background-color 150ms ease, border-color 150ms ease;
}

.pdc-action-btn:hover {
  background-color: #3D3D3D;
  border-color: #4A4A4A;
}

.pdc-action-btn:focus-visible {
  outline: 3px solid #F0F0F0;
  outline-offset: 4px;
}

.pdc-icon-slot {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
  will-change: opacity, transform, filter;
}

.pdc-stop-square {
  width: 17px;
  height: 17px;
  border-radius: 4.5px;
  background-color: #F0F0F0;
}

.pdc-dots-wave {
  display: inline-flex;
  align-items: center;
  gap: 5px;
}

.pdc-wave-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background-color: #F0F0F0;
}

.pdc-visually-hidden:where(:not(:focus-within, :active)) {
  position: absolute !important;
  clip-path: inset(50%) !important;
  overflow: hidden !important;
  width: 1px !important;
  height: 1px !important;
  margin: -1px !important;
  padding: 0 !important;
  border: 0 !important;
  white-space: nowrap !important;
}

@media (prefers-reduced-motion: reduce) {
  .pdc-placeholder,
  .pdc-word,
  .pdc-icon-slot {
    filter: none !important;
  }
}
`;

function ensureStylesInjected(): void {
  if (typeof document === 'undefined') return;
  if (document.getElementById(STYLE_TAG_ID)) return;
  const style = document.createElement('style');
  style.id = STYLE_TAG_ID;
  style.textContent = COMPONENT_CSS;
  document.head.appendChild(style);
}

/* ============================================================================
 * ParticleDictationCard React Component
 * ========================================================================== */

export const ParticleDictationCard: React.FC<ParticleDictationCardProps> = ({
  variant = 'dot-matrix',
  mode = 'demo',
  demoTimeSeconds = null,
  demoPaused = false,
  demoLoop = true,
  demoLines = DEFAULT_DEMO_LINES,
  phase: controlledPhase,
  transcript: controlledTranscript,
  audioLevel: controlledAudioLevel = 0,
  frequencyBands: controlledFrequencyBands,
  elapsedSeconds: controlledElapsedSeconds = 0,
  placeholder = 'Tap the key and speak',
  listeningPlaceholder = 'Listening...',
  thinkingLabel = 'thinking',
  width = 878,
  height = 270,
  ariaLabelPrefix,
  onPhaseChange,
  onTranscriptChange,
  onActionClick,
  onError,
  onFrameMetrics,
  className,
  style,
}) => {
  const transcriptId = useId();
  const shellRef = useRef<HTMLDivElement | null>(null);
  const cardRef = useRef<HTMLDivElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const wordSpanRefs = useRef<Map<string, HTMLSpanElement>>(new Map());
  const assetsRef = useRef<PrebakedAssets | null>(null);
  const scratchCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const glyphMapRef = useRef<Map<string, GlyphCell[]>>(new Map());
  const isSkippedRef = useRef<boolean>(false);

  // Live animation refs so 60fps canvas loop runs outside React re-render overhead
  const demoClockRef = useRef<number>(demoTimeSeconds ?? 0);
  const lastRafTsRef = useRef<number | null>(null);
  const lastPhaseRef = useRef<DictationPhase>('idle');
  const livePhaseTransitionRef = useRef<{
    from: DictationPhase;
    to: DictationPhase;
    startSec: number;
  }>({ from: 'idle', to: 'idle', startSec: -10 });

  // Visual state synced at state-change boundaries or DOM-driven opacity/blur via direct refs
  const placeholderIdleRef = useRef<HTMLParagraphElement | null>(null);
  const placeholderListenRef = useRef<HTMLParagraphElement | null>(null);
  const statusWrapRef = useRef<HTMLDivElement | null>(null);
  const statusDotRef = useRef<HTMLSpanElement | null>(null);
  const statusTextRef = useRef<HTMLSpanElement | null>(null);
  const actionBtnRef = useRef<HTMLButtonElement | null>(null);
  const iconMicRef = useRef<HTMLSpanElement | null>(null);
  const iconStopRef = useRef<HTMLSpanElement | null>(null);
  const iconDotsRef = useRef<HTMLSpanElement | null>(null);
  const waveDotRefs = useRef<Array<HTMLSpanElement | null>>([null, null, null]);

  // Accessible state & reduced motion
  const [reducedMotion, setReducedMotion] = useState<boolean>(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return false;
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  });
  const [announcedTranscript, setAnnouncedTranscript] = useState<string>('');
  const [uiPhase, setUiPhase] = useState<DictationPhase>('idle');

  // Microphone mode integration
  const mic = useMicrophoneDictation({
    onPhaseChange: mode === 'microphone' ? onPhaseChange : undefined,
    onTranscriptChange: mode === 'microphone' ? onTranscriptChange : undefined,
    onError: mode === 'microphone' ? onError : undefined,
  });

  // Live word records for microphone / controlled streaming mode
  const liveWordsRef = useRef<LiveWordRecord[]>([]);
  const [liveWordsVersion, setLiveWordsVersion] = useState(0);

  // Inject scoped CSS once
  useEffect(() => {
    ensureStylesInjected();
  }, []);

  // Track prefers-reduced-motion live
  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    const handler = (ev: MediaQueryListEvent) => setReducedMotion(ev.matches);
    setReducedMotion(mq.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);

  // Build deterministic demo word list from demoLines
  const demoWords: WordTimingSpec[] = useMemo(() => {
    const out: WordTimingSpec[] = [];
    let globalIdx = 0;
    for (let lineIdx = 0; lineIdx < demoLines.length; lineIdx++) {
      const tokens = demoLines[lineIdx].trim().split(/\s+/).filter(Boolean);
      for (const token of tokens) {
        const spec = DEFAULT_WORD_TIMINGS[globalIdx];
        if (spec) {
          out.push({
            text: token,
            line: lineIdx,
            launchStart: spec[0],
            arriveEnd: spec[1],
            blurStart: spec[2],
            sharpEnd: spec[3],
          });
        } else {
          // Graceful evenly spaced fallback for custom demoLines > 17 words
          const base = 2.02 + globalIdx * 0.29;
          out.push({
            text: token,
            line: lineIdx,
            launchStart: base,
            arriveEnd: base + 0.5,
            blurStart: base + 0.66,
            sharpEnd: base + 0.96,
          });
        }
        globalIdx++;
      }
    }
    return out;
  }, [demoLines]);

  // Pre-memoized LiveWordRecord[] for demo mode (avoids per-frame array allocation in 60fps loop)
  const demoLiveWords: LiveWordRecord[] = useMemo(
    () =>
      demoWords.map((w, i) => ({
        key: `demo-${i}`,
        text: w.text,
        launchStart: w.launchStart,
        arriveEnd: w.arriveEnd,
        blurStart: w.blurStart,
        sharpEnd: w.sharpEnd,
      })),
    [demoWords]
  );

  // Sync latest high-frequency props, mic telemetry, & callbacks into a ref so paintFrame & rAF stay stable
  const latestRef = useRef({
    width,
    height,
    variant,
    mode,
    demoLoop,
    demoLiveWords,
    demoLines,
    micPhase: mic.phase,
    micTelemetryRef: mic.telemetryRef,
    controlledPhase,
    controlledAudioLevel,
    controlledFrequencyBands,
    controlledElapsedSeconds,
    thinkingLabel,
    reducedMotion,
    onPhaseChange,
    onTranscriptChange,
    onFrameMetrics,
  });
  latestRef.current = {
    width,
    height,
    variant,
    mode,
    demoLoop,
    demoLiveWords,
    demoLines,
    micPhase: mic.phase,
    micTelemetryRef: mic.telemetryRef,
    controlledPhase,
    controlledAudioLevel,
    controlledFrequencyBands,
    controlledElapsedSeconds,
    thinkingLabel,
    reducedMotion,
    onPhaseChange,
    onTranscriptChange,
    onFrameMetrics,
  };

  // Synchronize live transcript tokens (for microphone & controlled modes)
  const activeExternalTranscript =
    mode === 'microphone' ? mic.transcript : mode === 'controlled' ? controlledTranscript || '' : '';

  useEffect(() => {
    if (mode === 'demo') return;
    const tokens = activeExternalTranscript.trim().split(/\s+/).filter(Boolean);
    const nowSec = performance.now() / 1000;
    const prev = liveWordsRef.current;

    if (tokens.length === 0) {
      if (prev.length > 0) {
        liveWordsRef.current = [];
        glyphMapRef.current.clear();
        setLiveWordsVersion((v) => v + 1);
      }
      return;
    }

    const next: LiveWordRecord[] = [];
    for (let i = 0; i < tokens.length; i++) {
      const existing = prev[i];
      if (existing && existing.text === tokens[i]) {
        next.push(existing);
      } else {
        next.push({
          key: `live-${i}-${tokens[i]}`,
          text: tokens[i],
          launchStart: nowSec,
          arriveEnd: nowSec + 0.48,
          blurStart: nowSec + 0.62,
          sharpEnd: nowSec + 0.98,
        });
      }
    }
    liveWordsRef.current = next;
    setLiveWordsVersion((v) => v + 1);
  }, [mode, activeExternalTranscript]);

  // Rasterize all rendered word spans onto real 4x4 px offscreen glyph masks
  const rebuildGlyphMasks = useCallback(() => {
    const cardEl = cardRef.current;
    if (!cardEl || typeof window === 'undefined') return;
    const cardRect = cardEl.getBoundingClientRect();
    if (cardRect.width === 0 || cardRect.height === 0) return;

    const scaleX = width / cardRect.width;
    const scaleY = height / cardRect.height;

    if (!scratchCanvasRef.current) {
      scratchCanvasRef.current = document.createElement('canvas');
    }

    const nextMap = new Map<string, GlyphCell[]>();
    let idx = 0;
    wordSpanRefs.current.forEach((spanEl, key) => {
      const text = spanEl.dataset.word || '';
      if (!text) return;
      const r = spanEl.getBoundingClientRect();
      const cs = window.getComputedStyle(spanEl);
      const rect: WordRect = {
        x: (r.left - cardRect.left) * scaleX,
        y: (r.top - cardRect.top) * scaleY,
        width: r.width * scaleX,
        height: r.height * scaleY,
        font: `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`,
      };
      nextMap.set(key, sampleWordGlyphCells(text, rect, idx, scratchCanvasRef.current!));
      idx++;
    });

    glyphMapRef.current = nextMap;
  }, [width, height]);

  // Rebuild glyph masks on mount, resize, font load, or word changes
  useEffect(() => {
    rebuildGlyphMasks();
    if (typeof document !== 'undefined' && document.fonts && document.fonts.ready) {
      document.fonts.ready.then(() => rebuildGlyphMasks()).catch(() => {});
    }
    if (typeof ResizeObserver === 'undefined' || !cardRef.current) return;
    const ro = new ResizeObserver(() => rebuildGlyphMasks());
    ro.observe(cardRef.current);
    return () => ro.disconnect();
  }, [rebuildGlyphMasks, demoWords, liveWordsVersion]);

  // Pause background rAF when off-screen via contentvisibilityautostatechange + IO fallback
  useEffect(() => {
    const shell = shellRef.current;
    if (!shell || typeof document === 'undefined') return;

    const supportsCV = 'contentVisibility' in document.documentElement.style;
    if (supportsCV) {
      const onStateChange = (ev: Event) => {
        const cvEv = ev as Event & { skipped?: boolean };
        isSkippedRef.current = Boolean(cvEv.skipped);
      };
      shell.addEventListener('contentvisibilityautostatechange', onStateChange);
      return () => shell.removeEventListener('contentvisibilityautostatechange', onStateChange);
    }

    if (typeof IntersectionObserver !== 'undefined') {
      const io = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            isSkippedRef.current = !entry.isIntersecting;
          }
        },
        { rootMargin: '200px' }
      );
      io.observe(shell);
      return () => io.disconnect();
    }
    return undefined;
  }, []);

  // Core frame paint function (stable identity via latestRef; zero rAF teardown across renders)
  const paintFrame = useCallback((nowMs: number, forcedDemoTime?: number | null) => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const s = latestRef.current;
    const drawStart = performance.now();
    const dpr = clamp(typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1, 1, 3);
    const targetW = Math.round(s.width * dpr);
    const targetH = Math.round(s.height * dpr);
    if (canvas.width !== targetW || canvas.height !== targetH) {
      canvas.width = targetW;
      canvas.height = targetH;
    }
    if (!assetsRef.current || assetsRef.current.dpr !== dpr) {
      assetsRef.current = createPrebakedAssets(dpr);
    }

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // Resolve timeline clock, phase, wave amplitude, and active word records
    let t = 0;
    let phase: DictationPhase = 'idle';
    let waveAmp = 0;
    let bands: Float32Array | number[] | null = null;
    let timerText = '0:00';
    let activeWords: ReadonlyArray<LiveWordRecord> = [];

    if (s.mode === 'demo') {
      if (typeof forcedDemoTime === 'number' && Number.isFinite(forcedDemoTime)) {
        t = s.demoLoop
          ? ((forcedDemoTime % DEMO_LOOP_DURATION) + DEMO_LOOP_DURATION) % DEMO_LOOP_DURATION
          : clamp(forcedDemoTime, 0, DEMO_LOOP_DURATION);
        demoClockRef.current = t;
      } else {
        t = demoClockRef.current;
      }
      phase = computeDemoPhase(t);
      waveAmp = computeDemoWaveAmplitude(t);
      timerText = computeDemoTimerLabel(t);
      activeWords = s.demoLiveWords;
    } else if (s.mode === 'microphone') {
      const tel = s.micTelemetryRef.current;
      t = nowMs / 1000;
      phase = s.micPhase;
      waveAmp =
        phase === 'listening'
          ? Math.max(0.28, tel.audioLevel)
          : phase === 'thinking'
            ? 0.24
            : 0;
      bands = phase === 'listening' ? tel.frequencyBands : null;
      timerText = formatTimer(tel.elapsedSeconds);
      activeWords = liveWordsRef.current;
    } else {
      t = nowMs / 1000;
      phase = s.controlledPhase ?? 'idle';
      waveAmp =
        phase === 'listening'
          ? clamp(s.controlledAudioLevel || 0.65, 0.2, 1)
          : phase === 'thinking'
            ? 0.24
            : 0;
      bands = s.controlledFrequencyBands ?? null;
      timerText = formatTimer(s.controlledElapsedSeconds);
      activeWords = liveWordsRef.current;
    }

    // Sync phase state for ARIA button labels, live morph transitions, & callbacks
    if (phase !== lastPhaseRef.current) {
      const prevPhase = lastPhaseRef.current;
      lastPhaseRef.current = phase;
      livePhaseTransitionRef.current = { from: prevPhase, to: phase, startSec: t };
      setUiPhase(phase);
      if (s.mode === 'demo') {
        s.onPhaseChange?.(phase);
        if (phase === 'completed') {
          const full = s.demoLines.join(' ');
          setAnnouncedTranscript(full);
          s.onTranscriptChange?.(full);
        } else if (phase === 'idle') {
          setAnnouncedTranscript('');
        }
      }
    }

    // Smooth wave collapse & rise in live microphone / controlled modes
    if (s.mode !== 'demo') {
      const tr = livePhaseTransitionRef.current;
      const phaseAge = Math.max(0, t - tr.startSec);
      if (phase === 'listening') {
        waveAmp *= smoothstep(0, 0.28, phaseAge);
      } else if (phase === 'thinking') {
        const settle = 1 - smoothstep(0, 0.45, phaseAge);
        waveAmp = lerp(0.24, Math.max(0.55, waveAmp), settle);
      } else if (phase === 'completed' && tr.from === 'thinking' && phaseAge < 0.68) {
        waveAmp = (1 - smoothstep(0, 0.66, phaseAge)) * 0.24;
      }
    }

    /* --------------------------------------------------------------------
     * Update DOM micro-interactions cleanly (zero React re-render per frame)
     * ------------------------------------------------------------------ */

    // 1. Placeholders ("Tap the key and speak" & "Listening...")
    let idleOp = 0;
    let idleBlur = 0;
    let listenOp = 0;
    let listenBlur = 0;

    if (s.mode === 'demo') {
      if (t < 0.5) {
        idleOp = 1;
      } else if (t < 0.62) {
        idleOp = 1 - smoothstep(0.5, 0.6, t);
        listenOp = smoothstep(0.5, 0.62, t);
      } else if (t < 1.74) {
        listenOp = 1;
      } else if (t < 2.02) {
        const p = smoothstep(1.74, 2.0, t);
        listenOp = 1 - p;
        listenBlur = p * 8;
      } else if (t >= 13.7) {
        const p = smoothstep(13.7, 13.92, t);
        idleOp = p;
        idleBlur = (1 - p) * 6;
      }
    } else {
      const hasText = activeWords.length > 0;
      idleOp = phase === 'idle' && !hasText ? 1 : 0;
      listenOp = phase === 'listening' && !hasText ? 1 : 0;
    }

    if (placeholderIdleRef.current) {
      placeholderIdleRef.current.style.opacity = idleOp.toFixed(3);
      placeholderIdleRef.current.style.filter =
        !s.reducedMotion && idleBlur > 0.05 ? `blur(${idleBlur.toFixed(2)}px)` : 'none';
    }
    if (placeholderListenRef.current) {
      placeholderListenRef.current.style.opacity = listenOp.toFixed(3);
      placeholderListenRef.current.style.filter =
        !s.reducedMotion && listenBlur > 0.05 ? `blur(${listenBlur.toFixed(2)}px)` : 'none';
    }

    // 2. Per-word DOM blur-to-sharp crossfade & 530ms L-to-R staggered reset sweep
    for (let i = 0; i < activeWords.length; i++) {
      const w = activeWords[i];
      const el = wordSpanRefs.current.get(w.key);
      if (!el) continue;

      let op = 0;
      let blurPx = 0;

      if (s.mode === 'demo') {
        if (t >= 12.53) {
          // Left-to-right staggered blur-out sweep (12.53s -> 13.07s = ~540ms)
          const totalWords = Math.max(1, activeWords.length - 1);
          const wordClearStart = 12.53 + (i / totalWords) * 0.34;
          const clearProgress = smoothstep(wordClearStart, wordClearStart + 0.2, t);
          op = 1 - clearProgress;
          blurPx = clearProgress * 9.5;
        } else if (s.reducedMotion) {
          op = t >= w.launchStart ? 1 : 0;
          blurPx = 0;
        } else if (t >= w.blurStart) {
          const p = smoothstep(w.blurStart, w.sharpEnd, t);
          op = p;
          blurPx = (1 - p) * 7.5;
        }
      } else {
        const tr = livePhaseTransitionRef.current;
        const phaseAge = Math.max(0, t - tr.startSec);
        if (phase === 'resetting') {
          const totalWords = Math.max(1, activeWords.length - 1);
          const wordClearStart = (i / totalWords) * 0.34;
          const clearProgress = smoothstep(wordClearStart, wordClearStart + 0.2, phaseAge);
          op = 1 - clearProgress;
          blurPx = clearProgress * 9.5;
        } else if (s.reducedMotion) {
          op = 1;
          blurPx = 0;
        } else if (t >= w.blurStart) {
          const p = smoothstep(w.blurStart, w.sharpEnd, t);
          op = p;
          blurPx = (1 - p) * 7.5;
        }
      }

      el.style.opacity = op.toFixed(3);
      el.style.filter = !s.reducedMotion && blurPx > 0.08 ? `blur(${blurPx.toFixed(2)}px)` : 'none';
    }

    // 3. Top-Right Status Badge (`• 0:00..0:06` & pulsing `• thinking`)
    let statusOp = 0;
    let statusLabel = timerText;
    let dotOp = 1;
    let dotScale = 1;

    if (s.mode === 'demo') {
      if (t >= 0.5 && t < 7.15) {
        statusOp = smoothstep(0.5, 0.68, t);
        statusLabel = timerText;
      } else if (t >= 7.15 && t < 9.52) {
        statusOp = t < 9.32 ? 1 : 1 - smoothstep(9.32, 9.5, t);
        statusLabel = s.thinkingLabel;
        const pulse = s.reducedMotion ? 1 : 0.5 + 0.5 * Math.cos((t - 7.15) * Math.PI * 2);
        dotOp = 0.54 + 0.46 * pulse;
        dotScale = 0.88 + 0.12 * pulse;
      }
    } else {
      if (phase === 'listening') {
        statusOp = 1;
        statusLabel = timerText;
      } else if (phase === 'thinking') {
        statusOp = 1;
        statusLabel = s.thinkingLabel;
        const pulse = s.reducedMotion ? 1 : 0.5 + 0.5 * Math.sin(t * Math.PI * 2);
        dotOp = 0.54 + 0.46 * pulse;
        dotScale = 0.88 + 0.12 * pulse;
      }
    }

    if (statusWrapRef.current) {
      statusWrapRef.current.style.opacity = statusOp.toFixed(3);
    }
    if (statusDotRef.current) {
      statusDotRef.current.style.opacity = dotOp.toFixed(3);
      statusDotRef.current.style.transform = `scale(${dotScale.toFixed(3)})`;
    }
    if (statusTextRef.current && statusTextRef.current.textContent !== statusLabel) {
      statusTextRef.current.textContent = statusLabel;
    }

    // 4. Bottom-Right Action Button Morphs (mic <-> stop ■ <-> 1.0s-period 3-dot wave •••)
    let micW = 0;
    let stopW = 0;
    let dotsW = 0;
    let btnPressScale = 1;

    if (s.mode === 'demo') {
      if (t < 0.5) {
        micW = 1;
      } else if (t < 0.7) {
        micW = 1 - smoothstep(0.5, 0.59, t);
        stopW = smoothstep(0.56, 0.68, t);
        // Subtle tactile button press bounce on trigger
        const bounce = Math.sin(smoothstep(0.5, 0.66, t) * Math.PI);
        btnPressScale = 1 - (s.reducedMotion ? 0 : bounce * 0.045);
      } else if (t < 7.15) {
        stopW = 1;
      } else if (t < 7.34) {
        stopW = 1 - smoothstep(7.15, 7.24, t);
        dotsW = smoothstep(7.2, 7.32, t);
      } else if (t < 9.32) {
        dotsW = 1;
      } else if (t < 9.54) {
        dotsW = 1 - smoothstep(9.32, 9.42, t);
        micW = smoothstep(9.38, 9.52, t);
      } else {
        micW = 1;
      }
    } else {
      // Smooth 180ms scale+blur+opacity icon morphs in live microphone / controlled modes
      const tr = livePhaseTransitionRef.current;
      const elapsed = Math.max(0, t - tr.startSec);
      const iconForPhase = (p: DictationPhase): 'mic' | 'stop' | 'dots' =>
        p === 'listening' ? 'stop' : p === 'thinking' ? 'dots' : 'mic';
      const fromIcon = iconForPhase(tr.from);
      const toIcon = iconForPhase(phase);
      if (fromIcon === toIcon || elapsed >= 0.2) {
        micW = toIcon === 'mic' ? 1 : 0;
        stopW = toIcon === 'stop' ? 1 : 0;
        dotsW = toIcon === 'dots' ? 1 : 0;
      } else {
        const outW = 1 - smoothstep(0, 0.1, elapsed);
        const inW = smoothstep(0.06, 0.19, elapsed);
        micW = (fromIcon === 'mic' ? outW : 0) + (toIcon === 'mic' ? inW : 0);
        stopW = (fromIcon === 'stop' ? outW : 0) + (toIcon === 'stop' ? inW : 0);
        dotsW = (fromIcon === 'dots' ? outW : 0) + (toIcon === 'dots' ? inW : 0);
        if (fromIcon === 'mic' && toIcon === 'stop' && !s.reducedMotion) {
          btnPressScale = 1 - Math.sin(smoothstep(0, 0.16, elapsed) * Math.PI) * 0.045;
        }
      }
    }

    if (actionBtnRef.current) {
      actionBtnRef.current.style.transform =
        btnPressScale !== 1 ? `scale(${btnPressScale.toFixed(4)})` : '';
    }

    const applyMorphSlot = (el: HTMLSpanElement | null, weight: number) => {
      if (!el) return;
      el.style.opacity = weight.toFixed(3);
      const sc = 0.58 + 0.42 * weight;
      el.style.transform = s.reducedMotion ? 'none' : `scale(${sc.toFixed(3)})`;
      const b = (1 - weight) * 4;
      el.style.filter = !s.reducedMotion && b > 0.15 && weight > 0.01 ? `blur(${b.toFixed(2)}px)` : 'none';
    };

    applyMorphSlot(iconMicRef.current, micW);
    applyMorphSlot(iconStopRef.current, stopW);
    applyMorphSlot(iconDotsRef.current, dotsW);

    // Exact 1.00s-period, 0.15s-staggered L-to-R luminance wave (124 <-> 244) on `•••`
    if (dotsW > 0.01) {
      const waveOrigin = s.mode === 'demo' ? 7.15 : livePhaseTransitionRef.current.startSec;
      for (let d = 0; d < 3; d++) {
        const dotEl = waveDotRefs.current[d];
        if (!dotEl) continue;
        const phaseRad = (t - waveOrigin - d * 0.15) * Math.PI * 2;
        const wave = s.reducedMotion ? 0.7 : 0.5 + 0.5 * Math.sin(phaseRad);
        const lum = Math.round(124 + wave * 120); // 124..244
        dotEl.style.backgroundColor = `rgb(${lum}, ${lum}, ${lum})`;
      }
    }

    /* --------------------------------------------------------------------
     * 5. Render 60fps Canvas Layer (Waveform + Particles + 4x4 Glyphs)
     * ------------------------------------------------------------------ */
    ctx.save();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    renderDictationCanvas({
      ctx,
      assets: assetsRef.current,
      width: s.width,
      height: s.height,
      variant: s.variant,
      timeSec: t,
      waveAmp,
      frequencyBands: bands,
      words: activeWords,
      wordGlyphMap: glyphMapRef.current,
      reducedMotion: s.reducedMotion,
    });
    ctx.restore();

    const drawMs = performance.now() - drawStart;
    if (s.onFrameMetrics && lastRafTsRef.current !== null) {
      const dtMs = Math.max(0.1, nowMs - lastRafTsRef.current);
      s.onFrameMetrics({ dtMs, drawMs, fps: 1000 / dtMs });
    }
  }, []);

  // Main 60fps requestAnimationFrame loop (stable across renders; zero teardown on audio/prop updates)
  useEffect(() => {
    if (typeof window === 'undefined') return;

    // Deterministic time scrub mode: handled immediately without starting rAF loop
    if (mode === 'demo' && typeof demoTimeSeconds === 'number' && Number.isFinite(demoTimeSeconds)) {
      if (glyphMapRef.current.size === 0) {
        rebuildGlyphMasks();
      }
      paintFrame(performance.now(), demoTimeSeconds);
      return;
    }

    let rafId = 0;
    lastRafTsRef.current = null;

    const tick = (nowMs: number) => {
      if (!isSkippedRef.current) {
        if (lastRafTsRef.current !== null && mode === 'demo' && !demoPaused) {
          const dtSec = clamp((nowMs - lastRafTsRef.current) / 1000, 0, 0.1);
          const nextClock = demoClockRef.current + dtSec;
          demoClockRef.current = demoLoop
            ? nextClock % DEMO_LOOP_DURATION
            : Math.min(nextClock, DEMO_LOOP_DURATION);
        }
        paintFrame(nowMs, null);
        lastRafTsRef.current = nowMs;
      } else {
        lastRafTsRef.current = null;
      }
      rafId = window.requestAnimationFrame(tick);
    };

    rafId = window.requestAnimationFrame(tick);
    return () => window.cancelAnimationFrame(rafId);
  }, [mode, demoTimeSeconds, demoPaused, demoLoop, paintFrame, rebuildGlyphMasks]);

  // Repaint immediately in deterministic scrub mode when visual props change
  useEffect(() => {
    if (typeof window === 'undefined') return;
    if (mode === 'demo' && typeof demoTimeSeconds === 'number' && Number.isFinite(demoTimeSeconds)) {
      paintFrame(performance.now(), demoTimeSeconds);
    }
  }, [mode, demoTimeSeconds, variant, width, height, reducedMotion, demoLiveWords, thinkingLabel, paintFrame]);

  // Action button click behavior
  const handleActionClick = useCallback(() => {
    const customResult = onActionClick?.(uiPhase);
    if (customResult === false) return;

    if (mode === 'microphone') {
      if (mic.phase === 'idle' || mic.phase === 'completed') {
        void mic.start();
      } else if (mic.phase === 'listening') {
        mic.stop();
      }
    } else if (mode === 'demo') {
      // Interactive jump: restart dictation from trigger point (0.50s) or jump to thinking (7.15s)
      if (uiPhase === 'idle' || uiPhase === 'completed' || uiPhase === 'resetting') {
        demoClockRef.current = 0.5;
      } else if (uiPhase === 'listening') {
        demoClockRef.current = 7.15;
      }
      paintFrame(performance.now(), null);
    }
  }, [mode, mic, onActionClick, uiPhase, paintFrame]);

  // Accessible dynamic button name (disambiguated via optional ariaLabelPrefix)
  const actionAriaLabel = useMemo(() => {
    const action =
      uiPhase === 'listening'
        ? 'Stop voice dictation'
        : uiPhase === 'thinking'
          ? 'Finalizing voice dictation'
          : 'Start voice dictation';
    return ariaLabelPrefix ? `${action} (${ariaLabelPrefix})` : action;
  }, [uiPhase, ariaLabelPrefix]);

  // Group demo words by line for exact 2-line typography matching the showcase
  const groupedDemoLines = useMemo(() => {
    const lines: Array<Array<WordTimingSpec & { globalIdx: number }>> = [];
    demoWords.forEach((w, idx) => {
      if (!lines[w.line]) lines[w.line] = [];
      lines[w.line].push({ ...w, globalIdx: idx });
    });
    return lines;
  }, [demoWords]);

  const registerWordRef = useCallback(
    (key: string) => (el: HTMLSpanElement | null) => {
      if (el) {
        wordSpanRefs.current.set(key, el);
      } else {
        wordSpanRefs.current.delete(key);
      }
    },
    []
  );

  return (
    <div ref={shellRef} className={`pdc-shell${className ? ` ${className}` : ''}`} style={style}>
      <div
        ref={cardRef}
        className="pdc-card"
        data-variant={variant}
        data-phase={uiPhase}
        style={
          {
            width: `${width}px`,
            height: `${height}px`,
            '--pdc-scale': String(width / 878),
          } as React.CSSProperties
        }
      >
        {/* Decorative 60fps Canvas: Waveform + Flying Particles + 4x4 Bitmap Glyphs */}
        <canvas ref={canvasRef} className="pdc-canvas" aria-hidden="true" />

        {/* Semantic Transcript & Placeholders */}
        <div className="pdc-text-layer">
          <p ref={placeholderIdleRef} className="pdc-placeholder" aria-hidden="true">
            {placeholder}
          </p>
          <p ref={placeholderListenRef} className="pdc-placeholder" aria-hidden="true">
            {listeningPlaceholder}
          </p>

          <div className="pdc-transcript" aria-hidden="true">
            {mode === 'demo' ? (
              groupedDemoLines.map((lineWords, lIdx) => (
                <span key={lIdx} className="pdc-line">
                  {lineWords.map((w, wPos) => {
                    const key = `demo-${w.globalIdx}`;
                    return (
                      <React.Fragment key={key}>
                        <span
                          ref={registerWordRef(key)}
                          className="pdc-word"
                          data-word={w.text}
                          style={{ opacity: 0 }}
                        >
                          {w.text}
                        </span>
                        {wPos < lineWords.length - 1 ? ' ' : ''}
                      </React.Fragment>
                    );
                  })}
                </span>
              ))
            ) : (
              <span className="pdc-line">
                {liveWordsRef.current.map((w, idx) => (
                  <React.Fragment key={w.key}>
                    <span
                      ref={registerWordRef(w.key)}
                      className="pdc-word"
                      data-word={w.text}
                      style={{ opacity: 0 }}
                    >
                      {w.text}
                    </span>
                    {idx < liveWordsRef.current.length - 1 ? ' ' : ''}
                  </React.Fragment>
                ))}
              </span>
            )}
          </div>
        </div>

        {/* Dedicated polite ARIA live region (debounced to final transcript, avoids per-frame spam & AccName leak) */}
        <div id={transcriptId} className="pdc-visually-hidden" aria-live="polite" aria-atomic="true">
          {mode === 'demo' ? announcedTranscript : activeExternalTranscript}
        </div>

        {/* Top-Right Status Indicator (`• 0:00..0:06` or pulsing `• thinking`) */}
        <div ref={statusWrapRef} className="pdc-status" style={{ opacity: 0 }} aria-hidden="true">
          <span ref={statusDotRef} className="pdc-status-dot" />
          <span ref={statusTextRef}>0:00</span>
        </div>

        {/* Bottom-Right Morphing Circular Action Button */}
        <button
          ref={actionBtnRef}
          type="button"
          className="pdc-action-btn"
          aria-label={actionAriaLabel}
          aria-describedby={transcriptId}
          aria-disabled={uiPhase === 'thinking' ? true : undefined}
          onClick={handleActionClick}
        >
          {/* Microphone Outline Icon (capsule + U cradle + short stem) */}
          <span ref={iconMicRef} className="pdc-icon-slot" aria-hidden="true">
            <svg width="30" height="30" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <rect
                x="9"
                y="3.5"
                width="6"
                height="10.5"
                rx="3"
                stroke="#F0F0F0"
                strokeWidth="2.1"
              />
              <path
                d="M5.75 11.25a6.25 6.25 0 0 0 12.5 0"
                stroke="#F0F0F0"
                strokeWidth="2.1"
                strokeLinecap="round"
              />
              <line
                x1="12"
                y1="17.5"
                x2="12"
                y2="20.75"
                stroke="#F0F0F0"
                strokeWidth="2.1"
                strokeLinecap="round"
              />
            </svg>
          </span>

          {/* Stop Rounded Square Icon */}
          <span
            ref={iconStopRef}
            className="pdc-icon-slot"
            style={{ opacity: 0 }}
            aria-hidden="true"
          >
            <span className="pdc-stop-square" />
          </span>

          {/* Thinking 3-Dot Traveling Brightness Wave Icon */}
          <span
            ref={iconDotsRef}
            className="pdc-icon-slot"
            style={{ opacity: 0 }}
            aria-hidden="true"
          >
            <span className="pdc-dots-wave">
              <span
                ref={(el) => {
                  waveDotRefs.current[0] = el;
                }}
                className="pdc-wave-dot"
              />
              <span
                ref={(el) => {
                  waveDotRefs.current[1] = el;
                }}
                className="pdc-wave-dot"
              />
              <span
                ref={(el) => {
                  waveDotRefs.current[2] = el;
                }}
                className="pdc-wave-dot"
              />
            </span>
          </span>
        </button>
      </div>
    </div>
  );
};

export default ParticleDictationCard;
