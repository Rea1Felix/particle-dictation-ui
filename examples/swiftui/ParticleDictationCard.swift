//
//  ParticleDictationCard.swift
//  Voice-to-Text Particle Dictation Card (Variant A: ASCII & Variant B: Dot-Matrix)
//
//  Compatible with macOS 14.0+ and iOS 17.0+ (Swift 5.9+ / Swift 6 strict concurrency).
//  Implements the complete 60fps Voice-to-Text Particle Dictation Card architecture:
//    - Variant A (.ascii): Paul-Bourke ASCII density mountain waveform, square flying
//      particles with velocity-aligned comet trails, and 4x4 square bitmap glyph assembly.
//    - Variant B (.dotMatrix, default): 10x10 luminous dot-matrix waveform using 3 discrete
//      primitives (`.`, vertical `:`, glowing 8pt `●` with radial bloom), circular flying
//      particles with comet tails, and 4x4 circular bitmap glyph assembly.
//    - Real CoreText / CGContext offscreen bitmap glyph sampler (4x4 grid).
//    - Pluggable audio & transcript source protocol with both a deterministic 14.05s demo
//      driver and a live AVAudioEngine + Accelerate (vDSP FFT/RMS) speech-hook driver.
//    - Full Accessibility (VoiceOver labels/announcements & accessibilityReduceMotion).
//

import Accelerate
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import os
import SwiftUI

// MARK: - Visual Style & State Machine

/// Rendering aesthetic for the waveform, flying speech particles, and 4x4 glyph assembly mask.
public enum DictationVisualStyle: String, CaseIterable, Identifiable, Sendable {
    /// Variant A: Monospace Paul-Bourke ASCII density field + crisp square particles & 4x4 square mask.
    case ascii
    /// Variant B (default): 10x10 luminous dot-matrix (`.`, `:`, glowing `●`) + circular particles & 4x4 dot mask.
    case dotMatrix

    public var id: String { rawValue }

    public var badgeLetter: String {
        switch self {
        case .ascii: return "A"
        case .dotMatrix: return "B"
        }
    }
}

/// Complete 5-state dictation lifecycle matching the 60fps state machine.
public enum DictationPhase: String, CaseIterable, Sendable, Equatable {
    case idle
    case listening
    case thinking
    case completed
    case resetting

    public var accessibilityDescription: String {
        switch self {
        case .idle: return "Idle. Tap the microphone button to start dictating."
        case .listening: return "Listening for speech."
        case .thinking: return "Finalizing dictation."
        case .completed: return "Dictation complete."
        case .resetting: return "Clearing transcript."
        }
    }
}

// MARK: - Design Tokens & Responsive Geometry

/// Exact color palette measured from the reference dark-mode dictation card.
public struct DictationTheme: Sendable {
    public let canvasBackground: Color
    public let cardFill: Color
    public let cardBorderTop: Color
    public let cardBorderBottom: Color
    public let placeholderText: Color
    public let transcriptText: Color
    public let statusDot: Color
    public let statusText: Color
    public let buttonFill: Color
    public let buttonBorder: Color
    public let buttonIcon: Color

    public static let darkDefault = DictationTheme(
        canvasBackground: Color(red: 13.0 / 255.0, green: 13.0 / 255.0, blue: 13.0 / 255.0), // #0D0D0D
        cardFill: Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0),         // #1E1E1E
        cardBorderTop: Color(red: 46.0 / 255.0, green: 46.0 / 255.0, blue: 46.0 / 255.0),    // #2E2E2E
        cardBorderBottom: Color(red: 37.0 / 255.0, green: 37.0 / 255.0, blue: 37.0 / 255.0), // #252525
        placeholderText: Color(red: 116.0 / 255.0, green: 116.0 / 255.0, blue: 116.0 / 255.0), // #747474
        transcriptText: Color(red: 231.0 / 255.0, green: 231.0 / 255.0, blue: 231.0 / 255.0),  // #E7E7E7
        statusDot: Color(red: 253.0 / 255.0, green: 253.0 / 255.0, blue: 253.0 / 255.0),       // #FDFDFD
        statusText: Color(red: 120.0 / 255.0, green: 120.0 / 255.0, blue: 120.0 / 255.0),      // #787878
        buttonFill: Color(red: 52.0 / 255.0, green: 52.0 / 255.0, blue: 52.0 / 255.0),         // #343434
        buttonBorder: Color(red: 64.0 / 255.0, green: 64.0 / 255.0, blue: 64.0 / 255.0),       // #404040 (#3C3C3C-#424242)
        buttonIcon: Color(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 240.0 / 255.0)       // #F0F0F0
    )
}

/// Geometry metrics parameterized by scale (`1.0` = exact `878x270` reference coordinates).
public struct DictationCardMetrics: Sendable {
    public let scale: CGFloat

    public init(scale: CGFloat = 1.0) {
        self.scale = max(0.35, scale)
    }

    public static let reference1080p = DictationCardMetrics(scale: 1.0)
    public static let desktop = DictationCardMetrics(scale: 0.68)
    public static let compact = DictationCardMetrics(scale: 0.45)

    public var cardWidth: CGFloat { 878.0 * scale }
    public var cardHeight: CGFloat { 270.0 * scale }
    public var cornerRadius: CGFloat { 39.0 * scale }
    public var borderWidth: CGFloat { max(1.0, 1.25 * scale) }

    public var textLeading: CGFloat { 38.0 * scale }
    public var textTop: CGFloat { 34.0 * scale }
    public var textMaxWidth: CGFloat { 656.0 * scale }
    public var fontSize: CGFloat { 31.5 * scale }
    public var lineHeight: CGFloat { 41.0 * scale }

    public var statusTop: CGFloat { 40.0 * scale }
    public var statusTrailing: CGFloat { 34.0 * scale }
    public var statusFontSize: CGFloat { 21.0 * scale }
    public var statusDotDiameter: CGFloat { 8.5 * scale }
    public var statusSpacing: CGFloat { 9.0 * scale }

    public var buttonDiameter: CGFloat { 82.0 * scale }
    public var buttonTrailing: CGFloat { 28.0 * scale }
    public var buttonBottom: CGFloat { 40.0 * scale }

    // Waveform & particle primitives
    public var asciiCellWidth: CGFloat { 10.0 * scale }
    public var asciiCellHeight: CGFloat { 16.0 * scale }
    public var asciiFontSize: CGFloat { 15.0 * scale }

    public var dotCellSize: CGFloat { 10.0 * scale }
    public var dotSmallDiameter: CGFloat { 2.2 * scale }
    public var dotColonDiameter: CGFloat { 2.35 * scale }
    public var dotColonVerticalGap: CGFloat { 4.1 * scale }
    public var dotOrbDiameter: CGFloat { 7.8 * scale }
    public var dotOrbBloomRadius: CGFloat { 14.5 * scale }

    public var glyphSampleStep: CGFloat { 4.0 * scale }
    public var particleSize: CGFloat { 4.2 * scale }
}

// MARK: - CoreText 4x4 Offscreen Bitmap Glyph Sampler

/// A single sampled pixel/dot cell belonging to a word's rasterized glyph mask.
public struct GlyphSamplePoint: Sendable, Hashable {
    public let localX: CGFloat
    public let localY: CGFloat
    public let intensity: CGFloat
    public let seed: UInt64

    public init(localX: CGFloat, localY: CGFloat, intensity: CGFloat, seed: UInt64) {
        self.localX = localX
        self.localY = localY
        self.intensity = intensity
        self.seed = seed
    }
}

/// CoreText-measured word layout combined with its offscreen 4x4 bitmap glyph targets.
public struct LaidOutWord: Sendable, Identifiable {
    public let id: Int
    public let text: String
    public let origin: CGPoint
    public let size: CGSize
    public let ascent: CGFloat
    public let descent: CGFloat
    public let lineIndex: Int
    public let glyphSamples: [GlyphSamplePoint]
}

/// Rasterizes words with CoreText (`CTLine`) into an offscreen 8-bit grayscale `CGContext`
/// and samples them onto a `4x4` grid so particles target authentic typography strokes.
public final class CoreTextGlyphSampler: @unchecked Sendable {
    public static let shared = CoreTextGlyphSampler()

    private struct CacheKey: Hashable, Sendable {
        let word: String
        let fontSizeTenths: Int
        let stepTenths: Int
    }

    private struct LayoutCacheKey: Hashable, Sendable {
        let words: [String]
        let fontSizeTenths: Int
        let lineHeightTenths: Int
        let maxWidthTenths: Int
        let originXTenths: Int
        let originYTenths: Int
        let stepTenths: Int
    }

    private struct CachedWordMetrics: Sendable {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let samples: [GlyphSamplePoint]
    }

    private struct CachedFontEntry: @unchecked Sendable {
        let font: CTFont
        let spaceWidth: CGFloat
    }

    private struct CacheState: Sendable {
        var words: [CacheKey: CachedWordMetrics] = [:]
        var fonts: [Int: CachedFontEntry] = [:]
        var layouts: [LayoutCacheKey: [LaidOutWord]] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: CacheState())

    public init() {}

    /// Creates the canonical system sans-serif `CTFont` matched to SwiftUI `Font(ctFont)`.
    public static func makeSystemFont(size: CGFloat) -> CTFont {
        if let uiFont = CTFontCreateUIFontForLanguage(.system, size, nil) {
            return uiFont
        }
        return CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }

    /// Returns a cached `CTFont` + space advance for `size`, avoiding per-frame CoreText churn at 60fps.
    public func cachedSystemFont(size: CGFloat) -> CTFont {
        cachedFontEntry(for: size).font
    }

    private func cachedFontEntry(for size: CGFloat) -> CachedFontEntry {
        let key = Int((size * 10.0).rounded())
        if let cached = lock.withLock({ $0.fonts[key] }) {
            return cached
        }
        let ctFont = Self.makeSystemFont(size: size)
        let spaceAttr = CFAttributedStringCreate(
            kCFAllocatorDefault,
            " " as CFString,
            [kCTFontAttributeName: ctFont] as CFDictionary
        )!
        let spaceLine = CTLineCreateWithAttributedString(spaceAttr)
        let spaceWidth = CGFloat(CTLineGetTypographicBounds(spaceLine, nil, nil, nil))
        let entry = CachedFontEntry(font: ctFont, spaceWidth: spaceWidth)
        lock.withLock { $0.fonts[key] = entry }
        return entry
    }

    /// Measures and rasterizes a single word on a `sampleStep x sampleStep` (default `4x4`) grid.
    /// Returned sample coordinates are in top-down SwiftUI space relative to the word's top-left corner.
    public func sampleWord(
        _ word: String,
        fontSize: CGFloat,
        sampleStep: CGFloat = 4.0,
        alphaThreshold: CGFloat = 0.24,
        oversample: Int = 2
    ) -> (size: CGSize, ascent: CGFloat, descent: CGFloat, samples: [GlyphSamplePoint]) {
        let key = CacheKey(
            word: word,
            fontSizeTenths: Int((fontSize * 10.0).rounded()),
            stepTenths: Int((sampleStep * 10.0).rounded())
        )

        if let cached = lock.withLock({ $0.words[key] }) {
            return (
                CGSize(width: cached.width, height: cached.ascent + cached.descent),
                cached.ascent,
                cached.descent,
                cached.samples
            )
        }

        let ctFont = cachedFontEntry(for: fontSize).font
        let whiteColor = CGColor(gray: 1.0, alpha: 1.0)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: whiteColor
        ]
        let attrString = CFAttributedStringCreate(
            kCFAllocatorDefault,
            word as CFString,
            attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attrString)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let rawWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let fontAscent = max(ascent, CTFontGetAscent(ctFont))
        let fontDescent = max(descent, CTFontGetDescent(ctFont))
        let logicalWidth = max(1.0, ceil(rawWidth))
        let logicalHeight = max(1.0, ceil(fontAscent + fontDescent))

        let pad: CGFloat = 2.0
        let scale = max(1, oversample)
        let pixelW = Int(ceil((logicalWidth + pad * 2.0) * CGFloat(scale)))
        let pixelH = Int(ceil((logicalHeight + pad * 2.0) * CGFloat(scale)))

        var samples: [GlyphSamplePoint] = []
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = pixelW
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * pixelH)

        buffer.withUnsafeMutableBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: pixelW,
                    height: pixelH,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return }

            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(false)
            ctx.setFillColor(gray: 0.0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

            // Draw in Quartz bottom-left coordinates; buffer memory row 0 corresponds to top of image.
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.textMatrix = .identity
            // Baseline sits `fontDescent + pad` above bottom so ascender top aligns with `pad` from top.
            ctx.textPosition = CGPoint(x: pad, y: fontDescent + pad)
            CTLineDraw(line, ctx)
        }

        // Sample the rasterized grayscale buffer on a strict `sampleStep x sampleStep` logical grid.
        let step = max(1.0, sampleStep)
        let cols = Int(ceil(logicalWidth / step))
        let rows = Int(ceil(logicalHeight / step))
        let wordHash = Self.fnv1a64(word)

        for row in 0..<rows {
            let cellTop = CGFloat(row) * step
            let pyStart = max(0, Int(floor((cellTop + pad) * CGFloat(scale))))
            let pyEnd = min(pixelH, Int(ceil((cellTop + step + pad) * CGFloat(scale))))
            guard pyEnd > pyStart else { continue }

            for col in 0..<cols {
                let cellLeft = CGFloat(col) * step
                let pxStart = max(0, Int(floor((cellLeft + pad) * CGFloat(scale))))
                let pxEnd = min(pixelW, Int(ceil((cellLeft + step + pad) * CGFloat(scale))))
                guard pxEnd > pxStart else { continue }

                var sum: Int = 0
                var maxVal: UInt8 = 0
                var count: Int = 0
                for py in pyStart..<pyEnd {
                    let rowOffset = py * bytesPerRow
                    for px in pxStart..<pxEnd {
                        let v = buffer[rowOffset + px]
                        sum += Int(v)
                        if v > maxVal { maxVal = v }
                        count += 1
                    }
                }

                guard count > 0 else { continue }
                let meanNorm = CGFloat(sum) / (CGFloat(count) * 255.0)
                let peakNorm = CGFloat(maxVal) / 255.0
                // Favor true cell mean coverage so letter counters ('e', 'o', 'd', 'a') stay open and legible on 4x4 grid.
                let coverage = meanNorm * 0.90 + peakNorm * 0.10
                if coverage >= alphaThreshold {
                    let seed = Self.mixHash(wordHash, col: col, row: row)
                    samples.append(
                        GlyphSamplePoint(
                            localX: cellLeft + step * 0.5,
                            localY: cellTop + step * 0.5,
                            intensity: min(1.0, pow(meanNorm, 0.85) * 1.15),
                            seed: seed
                        )
                    )
                }
            }
        }

        let entry = CachedWordMetrics(
            width: rawWidth,
            ascent: fontAscent,
            descent: fontDescent,
            samples: samples
        )
        lock.withLock { $0.words[key] = entry }

        return (
            CGSize(width: rawWidth, height: fontAscent + fontDescent),
            fontAscent,
            fontDescent,
            samples
        )
    }

    /// Lays out an ordered word sequence across wrapped lines using cached CoreText metrics,
    /// guaranteeing 1:1 pixel alignment between the 4x4 glyph mask and SwiftUI `Text` words
    /// with O(1) cache hits on steady-state 60fps ticks.
    public func layoutWords(
        _ words: [String],
        fontSize: CGFloat,
        lineHeight: CGFloat,
        maxWidth: CGFloat,
        originOffset: CGPoint,
        sampleStep: CGFloat
    ) -> [LaidOutWord] {
        guard !words.isEmpty else { return [] }

        let layoutKey = LayoutCacheKey(
            words: words,
            fontSizeTenths: Int((fontSize * 10.0).rounded()),
            lineHeightTenths: Int((lineHeight * 10.0).rounded()),
            maxWidthTenths: Int((maxWidth * 10.0).rounded()),
            originXTenths: Int((originOffset.x * 10.0).rounded()),
            originYTenths: Int((originOffset.y * 10.0).rounded()),
            stepTenths: Int((sampleStep * 10.0).rounded())
        )
        if let cached = lock.withLock({ $0.layouts[layoutKey] }) {
            return cached
        }

        let spaceWidth = cachedFontEntry(for: fontSize).spaceWidth

        var cursorX: CGFloat = 0
        var lineIndex: Int = 0
        var laidOut: [LaidOutWord] = []
        laidOut.reserveCapacity(words.count)

        for (idx, word) in words.enumerated() {
            let sampled = sampleWord(word, fontSize: fontSize, sampleStep: sampleStep)
            if cursorX > 0 && (cursorX + sampled.size.width) > maxWidth {
                lineIndex += 1
                cursorX = 0
            }

            let wordOrigin = CGPoint(
                x: originOffset.x + cursorX,
                y: originOffset.y + CGFloat(lineIndex) * lineHeight
            )
            laidOut.append(
                LaidOutWord(
                    id: idx,
                    text: word,
                    origin: wordOrigin,
                    size: sampled.size,
                    ascent: sampled.ascent,
                    descent: sampled.descent,
                    lineIndex: lineIndex,
                    glyphSamples: sampled.samples
                )
            )
            cursorX += sampled.size.width + spaceWidth
        }

        let finalLayout = laidOut
        lock.withLock { state in
            if state.layouts.count >= 64 {
                state.layouts.removeAll(keepingCapacity: true)
            }
            state.layouts[layoutKey] = finalLayout
        }
        return finalLayout
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private static func mixHash(_ base: UInt64, col: Int, row: Int) -> UInt64 {
        var h = base ^ (UInt64(bitPattern: Int64(col)) &* 0x9E3779B97F4A7C15)
        h ^= (UInt64(bitPattern: Int64(row)) &* 0xBF58476D1CE4E5B9)
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
        return h ^ (h >> 31)
    }
}

// MARK: - Waveform Field Generator (Shared Underlying 2D Heightfield)

/// Discrete primitive for Variant B's `10x10` luminous dot-matrix waveform.
public enum DotMatrixPrimitive: Equatable, Sendable {
    case empty
    /// Faint single bottom-aligned dot (`.`).
    case singleDot(opacity: Double)
    /// Vertical two-dot colon (`:`).
    case verticalColon(opacity: Double)
    /// Bright glowing 8pt solid circle (`●`) with radial bloom.
    case glowingOrb(intensity: Double)
}

/// Evaluates the shared 2D mountain waveform field for both Variant A (Paul-Bourke ASCII)
/// and Variant B (3-primitive 10x10 dot-matrix), ensuring identical acoustic motion.
public struct WaveformFieldGenerator: Sendable {
    /// Classic Paul-Bourke-style 70-character luminance density ramp (sparse -> dense).
    public static let paulBourkeRamp: [Character] = Array(
        " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B$@"
    )

    public init() {}

    /// Computes normalized column height (`0...1`) at normalized horizontal offset `u ∈ [-1, 1]`.
    public func columnHeight(
        u: Double,
        time: TimeInterval,
        audio: DictationAudioSnapshot,
        envelope: Double
    ) -> Double {
        guard envelope > 0.002 else { return 0.0 }

        // Central mountain peak + natural wide base skirt matching reference silhouette.
        let coreBell = exp(-pow(u * 2.35, 2.0))
        let midShoulder = exp(-pow(u * 1.55, 2.0)) * 0.34
        let skirtBell = exp(-pow(u * 1.12, 2.0)) * 0.22
        let spatialShape = min(1.0, coreBell * 0.78 + midShoulder + skirtBell)

        // Map |u| into live spectrum bands (low/mid voice formants concentrated at peak).
        let bandEnergy: Double
        if audio.spectrumBands.isEmpty {
            bandEnergy = audio.rmsLevel
        } else {
            let normFreq = min(0.999, abs(u) * 0.82)
            let exactIdx = normFreq * Double(audio.spectrumBands.count - 1)
            let i0 = Int(exactIdx)
            let i1 = min(audio.spectrumBands.count - 1, i0 + 1)
            let frac = exactIdx - Double(i0)
            bandEnergy = audio.spectrumBands[i0] * (1.0 - frac) + audio.spectrumBands[i1] * frac
        }

        // Gentle multi-harmonic travelling surface waves keeping a cohesive central mountain crest.
        let wave1 = 0.5 + 0.5 * sin(u * 5.8 - time * 4.9)
        let wave2 = 0.5 + 0.5 * cos(u * 11.2 + time * 7.6 + 0.9)
        let wave3 = 0.5 + 0.5 * sin(u * 18.5 - time * 10.4)
        let organicRipple = 0.78 + 0.12 * wave1 + 0.06 * wave2 + 0.04 * wave3

        let energyDrive = 0.34 + 0.66 * min(1.0, audio.rmsLevel * 0.55 + bandEnergy * 0.60)
        return min(1.0, spatialShape * energyDrive * organicRipple * envelope)
    }

    /// Evaluates local cell energy (`0...1`) at `(col, row)` where `row = 0` is the bottom edge.
    public func cellEnergy(
        col: Int,
        totalCols: Int,
        row: Int,
        maxRows: Int,
        time: TimeInterval,
        audio: DictationAudioSnapshot,
        envelope: Double
    ) -> Double {
        guard totalCols > 1, maxRows > 0, envelope > 0.002 else { return 0.0 }
        let u = (Double(col) / Double(totalCols - 1)) * 2.0 - 1.0
        let colH = columnHeight(u: u, time: time, audio: audio, envelope: envelope)
        let heightInRows = colH * Double(maxRows)
        let rowPos = Double(row) + 0.38
        guard heightInRows > 0.18 else { return 0.0 }

        if rowPos > heightInRows + 0.55 {
            return 0.0
        }

        let verticalRatio = max(0.0, rowPos / max(0.35, heightInRows))
        let verticalFade = verticalRatio <= 1.0
            ? pow(max(0.0, 1.0 - verticalRatio * 0.78), 0.58)
            : max(0.0, 1.0 - (rowPos - heightInRows) / 0.55) * 0.20

        // Horizontal core concentration: dense core in center, soft punctuation/dots along outer skirt.
        let horizontalCore = 0.38 + 0.62 * exp(-pow(u * 1.48, 2.0))
        // Preserve vibrant core intensity even during low 3-row simmering `.thinking` ripples.
        let heightSupport = min(1.0, 0.55 + heightInRows * 0.18)
        let baseEnergy = verticalFade * horizontalCore * heightSupport
        return min(1.0, max(0.0, baseEnergy))
    }

    /// Maps local energy to a Variant A Paul-Bourke ASCII glyph + opacity.
    public func asciiCell(
        col: Int,
        totalCols: Int,
        row: Int,
        maxRows: Int,
        time: TimeInterval,
        audio: DictationAudioSnapshot,
        envelope: Double
    ) -> (character: Character, opacity: Double)? {
        let energy = cellEnergy(
            col: col,
            totalCols: totalCols,
            row: row,
            maxRows: maxRows,
            time: time,
            audio: audio,
            envelope: envelope
        )
        guard energy > 0.075 else { return nil }

        // Subtle 18Hz-bucketed organic shimmer so adjacent dense cells look authentically alive.
        let timeBucket = Int(floor(time * 18.0))
        let jitter = (Self.cellHash(col: col, row: row, bucket: timeBucket) - 0.5) * 0.22
        let modulated = min(1.0, max(0.04, pow(energy, 0.85) + jitter))

        let ramp = Self.paulBourkeRamp
        let idx = min(ramp.count - 1, max(1, Int((modulated * Double(ramp.count - 1)).rounded())))
        let opacity = min(0.92, 0.22 + pow(energy, 0.70) * 0.72)
        return (ramp[idx], opacity)
    }

    /// Maps local energy to one of Variant B's 3 discrete dot-matrix primitives (`.`, `:`, `●`).
    /// Uses genuine energy-weighted halftone dithering so even the bottom core dynamically mixes `●`, `:`, and `.`.
    public func dotMatrixCell(
        col: Int,
        totalCols: Int,
        row: Int,
        maxRows: Int,
        time: TimeInterval,
        audio: DictationAudioSnapshot,
        envelope: Double
    ) -> DotMatrixPrimitive {
        let energy = cellEnergy(
            col: col,
            totalCols: totalCols,
            row: row,
            maxRows: maxRows,
            time: time,
            audio: audio,
            envelope: envelope
        )
        guard energy > 0.06 else { return .empty }

        // Stochastic halftone dither (14Hz bucketed) matching reference `crop_B_dots_ultra_t2_5s.png`:
        // even dense core mixes ~48% glowing `●` orbs with ~36% vertical `:` colons and ~16% faint `.` dots.
        let timeBucket = Int(floor(time * 14.0))
        let h = Self.cellHash(col: col, row: row, bucket: timeBucket)

        // Slight crest/base orb clustering bias for authentic LED/phosphor highlight pockets.
        let baseBoost = (row == 0 && energy > 0.35) ? 0.10 : 0.0
        let probOrb = min(0.56, pow(energy, 1.35) * 0.58 + baseBoost)
        let probColon = min(0.90, pow(energy, 0.68) * 0.88)

        if h < probOrb && energy >= 0.22 {
            let orbIntensity = min(1.0, 0.82 + energy * 0.22)
            return .glowingOrb(intensity: orbIntensity)
        } else if h < probColon && energy >= 0.13 {
            let opacity = min(0.84, 0.32 + energy * 0.56)
            return .verticalColon(opacity: opacity)
        } else {
            let opacity = min(0.64, 0.20 + energy * 0.48)
            return .singleDot(opacity: opacity)
        }
    }

    /// Deterministic spatial-temporal pseudo-random hash in `[0, 1)`.
    public static func cellHash(col: Int, row: Int, bucket: Int) -> Double {
        var h = UInt64(bitPattern: Int64(col &* 374761393))
        h &+= UInt64(bitPattern: Int64(row &* 668265263))
        h &+= UInt64(bitPattern: Int64(bucket &* 1442695041))
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= (h >> 16)
        return Double(h & 0xFFFF) / 65536.0
    }
}

// MARK: - Pluggable Audio & Transcript Source Protocol

/// Real-time or synthesized audio energy & spectrum frame driving the 2D waveform heightfield.
public struct DictationAudioSnapshot: Sendable, Equatable {
    public let rmsLevel: Double
    public let spectrumBands: [Double]
    public let timestamp: TimeInterval

    public init(rmsLevel: Double, spectrumBands: [Double], timestamp: TimeInterval) {
        self.rmsLevel = min(1.0, max(0.0, rmsLevel))
        self.spectrumBands = spectrumBands
        self.timestamp = timestamp
    }

    public static let silent = DictationAudioSnapshot(
        rmsLevel: 0.0,
        spectrumBands: Array(repeating: 0.0, count: 24),
        timestamp: 0.0
    )
}

/// An incoming dictated word anchored to its arrival timestamp so particle trajectories remain deterministic.
public struct DictationWordEvent: Sendable, Equatable, Identifiable {
    public let id: Int
    public let word: String
    public let launchTime: TimeInterval

    public init(id: Int, word: String, launchTime: TimeInterval) {
        self.id = id
        self.word = word
        self.launchTime = launchTime
    }
}

/// Complete frame snapshot evaluated by `ParticleDictationCard` at 60fps.
public struct DictationFrameState: Sendable {
    public let time: TimeInterval
    public let phase: DictationPhase
    /// Elapsed seconds since entering the current `phase` (used for source-agnostic icon morphs).
    public let phaseElapsed: TimeInterval
    public let elapsedRecordingTime: TimeInterval
    public let waveformEnvelope: Double
    public let audio: DictationAudioSnapshot
    public let words: [DictationWordEvent]
    public let idlePlaceholderOpacity: Double
    public let idlePlaceholderBlur: Double
    public let listeningPlaceholderOpacity: Double
    public let listeningPlaceholderBlur: Double
    public let statusOpacity: Double
    public let resetElapsed: TimeInterval?

    public init(
        time: TimeInterval,
        phase: DictationPhase,
        phaseElapsed: TimeInterval = 0.0,
        elapsedRecordingTime: TimeInterval,
        waveformEnvelope: Double,
        audio: DictationAudioSnapshot,
        words: [DictationWordEvent],
        idlePlaceholderOpacity: Double,
        idlePlaceholderBlur: Double,
        listeningPlaceholderOpacity: Double,
        listeningPlaceholderBlur: Double,
        statusOpacity: Double,
        resetElapsed: TimeInterval?
    ) {
        self.time = time
        self.phase = phase
        self.phaseElapsed = max(0.0, phaseElapsed)
        self.elapsedRecordingTime = elapsedRecordingTime
        self.waveformEnvelope = waveformEnvelope
        self.audio = audio
        self.words = words
        self.idlePlaceholderOpacity = idlePlaceholderOpacity
        self.idlePlaceholderBlur = idlePlaceholderBlur
        self.listeningPlaceholderOpacity = listeningPlaceholderOpacity
        self.listeningPlaceholderBlur = listeningPlaceholderBlur
        self.statusOpacity = statusOpacity
        self.resetElapsed = resetElapsed
    }
}

/// Pluggable data/control source driving `ParticleDictationCard` (either deterministic demo or live microphone/ASR).
@MainActor
public protocol DictationSource: AnyObject {
    func frameState(at wallTime: TimeInterval) -> DictationFrameState
    func handlePrimaryButtonTap(at wallTime: TimeInterval)
    func teardown()
}

public extension DictationSource {
    func teardown() {}
}

// MARK: - Deterministic Demo Source (Matches Reference 14.05s Showcase)

/// Deterministic 14.05s choreographed dictation driver faithfully reproducing every state transition,
/// timer tick (`0:00..0:06`), word arrival schedule, thinking simmer, and 530ms L-to-R reset sweep.
@MainActor
public final class DemoDictationSource: DictationSource {
    public nonisolated static let loopDuration: TimeInterval = 14.05
    public nonisolated static let resetSweepDuration: TimeInterval = 0.53

    /// Verbatim 17-word transcript with frame-accurate launch timestamps matching the reference showcase
    /// (`Remind` landed in crisp 4x4 matrix at t=2.50s as `me` arrives; `river.` arcing up during `• thinking` at t=7.50s).
    public nonisolated static let referenceWords: [DictationWordEvent] = [
        DictationWordEvent(id: 0, word: "Remind", launchTime: 1.76),
        DictationWordEvent(id: 1, word: "me", launchTime: 2.18),
        DictationWordEvent(id: 2, word: "to", launchTime: 2.52),
        DictationWordEvent(id: 3, word: "call", launchTime: 2.94),
        DictationWordEvent(id: 4, word: "Maya", launchTime: 3.26),
        DictationWordEvent(id: 5, word: "tomorrow", launchTime: 3.58),
        DictationWordEvent(id: 6, word: "morning,", launchTime: 4.14),
        DictationWordEvent(id: 7, word: "then", launchTime: 4.60),
        DictationWordEvent(id: 8, word: "book", launchTime: 4.94),
        DictationWordEvent(id: 9, word: "a", launchTime: 5.22),
        DictationWordEvent(id: 10, word: "quiet", launchTime: 5.42),
        DictationWordEvent(id: 11, word: "table", launchTime: 5.72),
        DictationWordEvent(id: 12, word: "for", launchTime: 6.02),
        DictationWordEvent(id: 13, word: "two", launchTime: 6.26),
        DictationWordEvent(id: 14, word: "by", launchTime: 6.46),
        DictationWordEvent(id: 15, word: "the", launchTime: 6.76),
        DictationWordEvent(id: 16, word: "river.", launchTime: 7.14)
    ]

    public var autoLoop: Bool
    private var startWallTime: TimeInterval?
    private var fixedTime: TimeInterval?
    private var isPaused: Bool = false
    private var pausedAtCycleTime: TimeInterval = 0.0

    public init(autoLoop: Bool = true, fixedTime: TimeInterval? = nil) {
        self.autoLoop = autoLoop
        self.fixedTime = fixedTime
    }

    public func seek(to cycleTime: TimeInterval?) {
        self.fixedTime = cycleTime
    }

    public func handlePrimaryButtonTap(at wallTime: TimeInterval) {
        if fixedTime != nil {
            fixedTime = nil
            startWallTime = wallTime - 0.50
            return
        }
        let current = evaluateCycleTime(at: wallTime)
        if current < 0.50 || current >= 9.32 {
            // Jump straight to start-recording trigger.
            startWallTime = wallTime - 0.50
            isPaused = false
        } else if current < 7.15 {
            // Jump straight to thinking / finalize phase.
            startWallTime = wallTime - 7.15
            isPaused = false
        } else {
            // Allow restarting from idle.
            startWallTime = wallTime
            isPaused = false
        }
    }

    private func evaluateCycleTime(at wallTime: TimeInterval) -> TimeInterval {
        if let fixedTime {
            return max(0.0, fixedTime)
        }
        if startWallTime == nil {
            startWallTime = wallTime
        }
        let raw = max(0.0, wallTime - (startWallTime ?? wallTime))
        if autoLoop {
            return raw.truncatingRemainder(dividingBy: Self.loopDuration)
        } else {
            return min(Self.loopDuration, raw)
        }
    }

    /// Pure deterministic state evaluator for any cycle timestamp `t ∈ [0, 14.05]`.
    public nonisolated static func evaluate(at t: TimeInterval) -> DictationFrameState {
        // Phase boundaries (frame-accurate @ 60fps):
        //   0.00 - 0.50: idle
        //   0.50 - 7.15: listening (timer 0:00..0:06, words stream 1.98..7.15)
        //   7.15 - 9.32: thinking (pulsing `• thinking`, 3-dot wave, simmering wave)
        //   9.32 - 12.53: completed (wave collapses by 10.00s, holds crisp transcript)
        //  12.53 - 14.05: resetting (530ms L-to-R blur sweep -> 630ms blank -> 200ms placeholder in)
        let phase: DictationPhase
        let phaseElapsed: TimeInterval
        if t < 0.50 {
            phase = .idle
            phaseElapsed = max(0.0, t)
        } else if t < 7.15 {
            phase = .listening
            phaseElapsed = t - 0.50
        } else if t < 9.32 {
            phase = .thinking
            phaseElapsed = t - 7.15
        } else if t < 12.53 {
            phase = .completed
            phaseElapsed = t - 9.32
        } else {
            phase = .resetting
            phaseElapsed = t - 12.53
        }

        // Elapsed recording timer: starts at 0.50s, ticks up to 0:06 before thinking at 7.15s.
        let elapsedRecordingTime: TimeInterval
        if t < 0.50 {
            elapsedRecordingTime = 0.0
        } else if t < 7.15 {
            elapsedRecordingTime = t - 0.50
        } else {
            elapsedRecordingTime = 6.65
        }

        // Idle placeholder ("Tap the key and speak") visibility & blur.
        let idleOpacity: Double
        let idleBlur: Double
        if t < 0.50 {
            idleOpacity = 1.0
            idleBlur = 0.0
        } else if t < 0.70 {
            let p = smoothstep((t - 0.50) / 0.20)
            idleOpacity = 1.0 - p
            idleBlur = p * 5.5
        } else if t >= 13.70 {
            let p = smoothstep((t - 13.70) / 0.20)
            idleOpacity = p
            idleBlur = (1.0 - p) * 5.5
        } else {
            idleOpacity = 0.0
            idleBlur = 5.5
        }

        // Listening placeholder ("Listening...") visibility & blur.
        let listeningOpacity: Double
        let listeningBlur: Double
        if t < 0.50 {
            listeningOpacity = 0.0
            listeningBlur = 5.5
        } else if t < 0.70 {
            let p = smoothstep((t - 0.50) / 0.20)
            listeningOpacity = p
            listeningBlur = (1.0 - p) * 5.5
        } else if t < 1.70 {
            listeningOpacity = 1.0
            listeningBlur = 0.0
        } else if t < 1.92 {
            let p = smoothstep((t - 1.70) / 0.22)
            listeningOpacity = 1.0 - p
            listeningBlur = p * 6.5
        } else {
            listeningOpacity = 0.0
            listeningBlur = 6.5
        }

        // Top-right status opacity (`• 0:00` .. `• thinking`).
        let statusOpacity: Double
        if t < 0.50 {
            statusOpacity = 0.0
        } else if t < 0.70 {
            statusOpacity = smoothstep((t - 0.50) / 0.20)
        } else if t < 9.32 {
            statusOpacity = 1.0
        } else if t < 9.50 {
            statusOpacity = 1.0 - smoothstep((t - 9.32) / 0.18)
        } else {
            statusOpacity = 0.0
        }

        // Waveform mountain height envelope.
        let waveformEnvelope: Double
        if t < 0.55 {
            waveformEnvelope = 0.0
        } else if t < 1.05 {
            // Rises from bottom edge with a low murmur then swells into speech burst.
            let p = smoothstep((t - 0.55) / 0.50)
            waveformEnvelope = 0.18 * p + 0.82 * pow(p, 1.5)
        } else if t < 7.15 {
            waveformEnvelope = 1.0
        } else if t < 7.55 {
            // Drops smoothly into low simmering ripple (2-3 rows in A, 3-4 rows in B).
            let p = smoothstep((t - 7.15) / 0.40)
            waveformEnvelope = 1.0 - p * 0.66
        } else if t < 9.32 {
            waveformEnvelope = 0.34
        } else if t < 10.00 {
            // Collapses gracefully down to zero by 10.00s.
            let p = smoothstep((t - 9.32) / 0.68)
            waveformEnvelope = 0.34 * (1.0 - p)
        } else {
            waveformEnvelope = 0.0
        }

        // Synthesized speech-like RMS & 24-band spectrum envelope synchronized to words.
        let audio = synthesizeSpeechAudio(at: t, phase: phase, envelope: waveformEnvelope)

        // Active words (all words whose launchTime <= t, cleared after reset completes).
        let activeWords: [DictationWordEvent]
        if t < 1.74 || t >= 13.15 {
            activeWords = []
        } else {
            activeWords = referenceWords.filter { $0.launchTime <= t }
        }

        let resetElapsed: TimeInterval? = t >= 12.53 ? (t - 12.53) : nil

        return DictationFrameState(
            time: t,
            phase: phase,
            phaseElapsed: phaseElapsed,
            elapsedRecordingTime: elapsedRecordingTime,
            waveformEnvelope: waveformEnvelope,
            audio: audio,
            words: activeWords,
            idlePlaceholderOpacity: idleOpacity,
            idlePlaceholderBlur: idleBlur,
            listeningPlaceholderOpacity: listeningOpacity,
            listeningPlaceholderBlur: listeningBlur,
            statusOpacity: statusOpacity,
            resetElapsed: resetElapsed
        )
    }

    public func frameState(at wallTime: TimeInterval) -> DictationFrameState {
        let t = evaluateCycleTime(at: wallTime)
        return Self.evaluate(at: t)
    }

    private nonisolated static func synthesizeSpeechAudio(
        at t: TimeInterval,
        phase: DictationPhase,
        envelope: Double
    ) -> DictationAudioSnapshot {
        guard envelope > 0.002 else { return .silent }

        // Speech syllables pulse energetically around word launches during `.listening`.
        var syllablePulse: Double = 0.48
        if phase == .listening {
            let speechWave = 0.55
                + 0.22 * sin(t * 6.4)
                + 0.14 * cos(t * 11.3 + 0.7)
                + 0.09 * sin(t * 17.8)
            var wordBurst: Double = 0.0
            for w in referenceWords {
                let dt = t - (w.launchTime - 0.12)
                if dt > -0.25 && dt < 0.35 {
                    wordBurst = max(wordBurst, exp(-pow(dt / 0.16, 2.0)) * 0.42)
                }
            }
            syllablePulse = min(1.0, max(0.30, speechWave + wordBurst))
        } else if phase == .thinking {
            syllablePulse = 0.62 + 0.14 * sin(t * 3.8)
        } else {
            syllablePulse = 0.35
        }

        var bands = [Double](repeating: 0.0, count: 24)
        for i in 0..<24 {
            let f = Double(i) / 23.0
            let formant = exp(-pow((f - 0.08) * 2.2, 2.0)) * 0.72
                + exp(-pow((f - 0.38) * 3.0, 2.0)) * 0.28
            let mod = 0.72 + 0.28 * sin(t * (4.2 + Double(i) * 0.42) + Double(i) * 0.8)
            bands[i] = min(1.0, max(0.0, syllablePulse * (0.42 + 0.58 * formant) * mod))
        }

        return DictationAudioSnapshot(
            rmsLevel: min(1.0, syllablePulse),
            spectrumBands: bands,
            timestamp: t
        )
    }
}

// MARK: - Real AVAudioEngine + Accelerate (vDSP FFT/RMS) Live Source

/// Signal-processing engine computing real-time RMS loudness and logarithmic FFT frequency bands
/// from raw floating-point PCM audio frames using Apple's `Accelerate` (`vDSP`) framework.
/// All scratch buffers and smoothing state are pre-allocated and guarded by `OSAllocatedUnfairLock`
/// for thread-safe, low-overhead invocation from CoreAudio render/tap callbacks.
public final class AudioSpectrumAnalyzer: @unchecked Sendable {
    public let fftSize: Int
    public let bandCount: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?
    private let window: [Float]
    private let bandBinRanges: [(lower: Int, upper: Int)]

    private struct AnalyzerState: Sendable {
        var windowed: [Float]
        var realp: [Float]
        var imagp: [Float]
        var magnitudes: [Float]
        var smoothedBands: [Double]
        var smoothedRMS: Double = 0.0
    }

    private let stateLock: OSAllocatedUnfairLock<AnalyzerState>

    public init(fftSize: Int = 1024, bandCount: Int = 24) {
        let clampedFFT = max(256, 1 << Int(round(log2(Double(fftSize)))))
        let clampedBands = max(4, bandCount)
        let halfN = clampedFFT / 2

        self.fftSize = clampedFFT
        self.bandCount = clampedBands
        self.log2n = vDSP_Length(round(log2(Double(clampedFFT))))
        self.fftSetup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))

        var hann = [Float](repeating: 0, count: clampedFFT)
        vDSP_hann_window(&hann, vDSP_Length(clampedFFT), Int32(vDSP_HANN_NORM))
        self.window = hann

        let minBin = 2
        let maxBin = max(minBin + 1, min(halfN - 1, halfN / 2))
        let logMin = log(Double(minBin))
        let logMax = log(Double(maxBin))
        var ranges: [(lower: Int, upper: Int)] = []
        ranges.reserveCapacity(clampedBands)
        for b in 0..<clampedBands {
            let t0 = Double(b) / Double(clampedBands)
            let t1 = Double(b + 1) / Double(clampedBands)
            let b0 = max(minBin, Int(floor(exp(logMin + (logMax - logMin) * t0))))
            let b1 = min(maxBin, max(b0 + 1, Int(ceil(exp(logMin + (logMax - logMin) * t1)))))
            ranges.append((b0, b1))
        }
        self.bandBinRanges = ranges

        let initialState = AnalyzerState(
            windowed: [Float](repeating: 0, count: clampedFFT),
            realp: [Float](repeating: 0, count: halfN),
            imagp: [Float](repeating: 0, count: halfN),
            magnitudes: [Float](repeating: 0, count: halfN),
            smoothedBands: [Double](repeating: 0.0, count: clampedBands),
            smoothedRMS: 0.0
        )
        self.stateLock = OSAllocatedUnfairLock(initialState: initialState)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    /// Processes a slice of mono float32 PCM samples and returns normalized RMS + spectrum bands.
    public func analyze(samples: UnsafePointer<Float>, count: Int, timestamp: TimeInterval) -> DictationAudioSnapshot {
        guard count > 0 else { return .silent }

        // 1. RMS loudness via vDSP_rmsqv.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        let dbRMS = 20.0 * log10(max(Double(rms), 1e-5))
        // Map typical speech range [-52 dBFS ... -10 dBFS] to [0 ... 1].
        let normalizedRMS = min(1.0, max(0.0, (dbRMS + 52.0) / 42.0))

        let n = fftSize
        let halfN = n / 2
        let copyCount = min(count, n)
        let normScale = Float(1.0 / Double(n * n))
        let setup = fftSetup
        let log2nVal = log2n
        let win = window
        let ranges = bandBinRanges

        return stateLock.withLockUnchecked { state in
            state.smoothedRMS = state.smoothedRMS * 0.55 + normalizedRMS * 0.45

            // 2. Real-to-complex FFT magnitude spectrum into pre-allocated scratch buffers (zero heap churn).
            for i in 0..<copyCount {
                state.windowed[i] = samples[i] * win[i]
            }
            if copyCount < n {
                for i in copyCount..<n {
                    state.windowed[i] = 0
                }
            }

            if let setup {
                state.windowed.withUnsafeBytes { rawBytes in
                    let complexPtr = rawBytes.bindMemory(to: DSPComplex.self)
                    state.realp.withUnsafeMutableBufferPointer { realBuf in
                        state.imagp.withUnsafeMutableBufferPointer { imagBuf in
                            var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                            if let base = complexPtr.baseAddress {
                                vDSP_ctoz(base, 2, &split, 1, vDSP_Length(halfN))
                            }
                            vDSP_fft_zrip(setup, &split, 1, log2nVal, FFTDirection(FFT_FORWARD))
                            vDSP_zvmags(&split, 1, &state.magnitudes, 1, vDSP_Length(halfN))
                        }
                    }
                }
            }

            // 3. Aggregate FFT bins logarithmically into `bandCount` speech-weighted frequency bands.
            for b in 0..<ranges.count {
                let (b0, b1) = ranges[b]
                var powerSum: Float = 0
                for k in b0..<b1 {
                    powerSum += state.magnitudes[k] * normScale
                }
                let avgPower = powerSum / Float(max(1, b1 - b0))
                let db = 10.0 * log10(max(Double(avgPower), 1e-8))
                let norm = min(1.0, max(0.0, (db + 68.0) / 52.0))
                state.smoothedBands[b] = state.smoothedBands[b] * 0.58 + norm * 0.42
            }

            return DictationAudioSnapshot(
                rmsLevel: state.smoothedRMS,
                spectrumBands: state.smoothedBands,
                timestamp: timestamp
            )
        }
    }
}

/// Optional adapter hook for plugging Apple `SFSpeechRecognizer`, WhisperKit, or cloud streaming ASR
/// into `LiveAudioEngineDictationSource`.
public protocol DictationSpeechRecognizerAdapter: AnyObject, Sendable {
    func startStreaming(
        onPartialTranscript: @escaping @Sendable (_ fullTranscript: String) -> Void,
        onFinalTranscript: @escaping @Sendable (_ fullTranscript: String) -> Void
    ) throws
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer)
    func finishStreaming()
}

/// Production live audio source powered by `AVAudioEngine` microphone capture, `vDSP` FFT/RMS
/// metering, and a pluggable speech-recognition hook.
/// All timestamps use the unified `Date().timeIntervalSinceReferenceDate` epoch matching SwiftUI `TimelineView`.
@MainActor
public final class LiveAudioEngineDictationSource: DictationSource {
    private let engine = AVAudioEngine()
    private let analyzer = AudioSpectrumAnalyzer(fftSize: 1024, bandCount: 24)
    private let speechAdapter: (any DictationSpeechRecognizerAdapter)?
    private let latestAudio = OSAllocatedUnfairLock(initialState: DictationAudioSnapshot.silent)

    private var phase: DictationPhase = .idle
    private var phaseChangedAt: TimeInterval = Date().timeIntervalSinceReferenceDate
    private var recordingStartedAt: TimeInterval = Date().timeIntervalSinceReferenceDate
    private var lastRecordingDuration: TimeInterval = 0.0
    private var isEngineRunning: Bool = false
    private var words: [DictationWordEvent] = []
    private var firstWordArrivedAt: TimeInterval?

    public init(speechAdapter: (any DictationSpeechRecognizerAdapter)? = nil) {
        self.speechAdapter = speechAdapter
    }

    public func startListening(at wallTime: TimeInterval = Date().timeIntervalSinceReferenceDate) throws {
        guard phase == .idle || phase == .completed else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw NSError(
                domain: "ParticleDictationCard",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No valid microphone input format available."]
            )
        }

        let audioLock = latestAudio
        let spectrumAnalyzer = analyzer
        let adapter = speechAdapter

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if let channelData = buffer.floatChannelData?[0] {
                let snapshot = spectrumAnalyzer.analyze(
                    samples: channelData,
                    count: Int(buffer.frameLength),
                    timestamp: Date().timeIntervalSinceReferenceDate
                )
                audioLock.withLock { $0 = snapshot }
            }
            adapter?.appendAudioBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isEngineRunning = true

            words.removeAll()
            firstWordArrivedAt = nil
            recordingStartedAt = wallTime
            phaseChangedAt = wallTime
            phase = .listening

            try speechAdapter?.startStreaming(
                onPartialTranscript: { [weak self] transcript in
                    let arrival = Date().timeIntervalSinceReferenceDate
                    Task { @MainActor [weak self] in
                        self?.ingestRecognizedTranscript(transcript, isFinal: false, at: arrival)
                    }
                },
                onFinalTranscript: { [weak self] transcript in
                    let arrival = Date().timeIntervalSinceReferenceDate
                    Task { @MainActor [weak self] in
                        self?.ingestRecognizedTranscript(transcript, isFinal: true, at: arrival)
                    }
                }
            )
        } catch {
            // Roll back audio tap, engine, session, and phase cleanly if startup fails mid-way.
            stopAudioEngine()
            words.removeAll()
            firstWordArrivedAt = nil
            phase = .idle
            phaseChangedAt = wallTime
            throw error
        }
    }

    public func stopListening(at wallTime: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard phase == .listening else { return }
        stopAudioEngine()
        lastRecordingDuration = max(0.0, wallTime - recordingStartedAt)
        phaseChangedAt = wallTime
        phase = .thinking
        speechAdapter?.finishStreaming()
    }

    /// Feeds incremental or finalized ASR text into the particle launcher, preserving launch timestamps
    /// for already-emitted words so particles never restart mid-flight.
    public func ingestRecognizedTranscript(
        _ fullTranscript: String,
        isFinal: Bool,
        at wallTime: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        let tokens = fullTranscript
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        for (index, token) in tokens.enumerated() {
            if index < words.count {
                if words[index].word != token {
                    words[index] = DictationWordEvent(
                        id: index,
                        word: token,
                        launchTime: words[index].launchTime
                    )
                }
            } else {
                if firstWordArrivedAt == nil {
                    firstWordArrivedAt = wallTime
                }
                words.append(DictationWordEvent(id: index, word: token, launchTime: wallTime))
            }
        }
        if tokens.count < words.count {
            words.removeSubrange(tokens.count..<words.count)
        }

        if isFinal {
            stopAudioEngine()
            if phase == .listening {
                lastRecordingDuration = max(0.0, wallTime - recordingStartedAt)
            }
            phaseChangedAt = wallTime
            phase = .completed
        }
    }

    public func beginReset(at wallTime: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        stopAudioEngine()
        phaseChangedAt = wallTime
        phase = .resetting
    }

    public func teardown() {
        stopAudioEngine()
        speechAdapter?.finishStreaming()
    }

    public func handlePrimaryButtonTap(at wallTime: TimeInterval) {
        switch phase {
        case .idle, .completed:
            try? startListening(at: wallTime)
        case .listening:
            stopListening(at: wallTime)
        case .thinking:
            phaseChangedAt = wallTime
            phase = .completed
        case .resetting:
            break
        }
    }

    public func frameState(at wallTime: TimeInterval) -> DictationFrameState {
        let dt = max(0.0, wallTime - phaseChangedAt)
        let snapshot = latestAudio.withLock { $0 }

        // Automatically transition from `.resetting` back to `.idle` after full 1.36s sweep + blank + fade-in.
        if phase == .resetting && dt >= 1.36 {
            words.removeAll()
            firstWordArrivedAt = nil
            phase = .idle
            phaseChangedAt = wallTime
        }

        let waveformEnvelope: Double
        let idleOpacity: Double
        let idleBlur: Double
        let listeningOpacity: Double
        let listeningBlur: Double
        let statusOpacity: Double
        let resetElapsed: TimeInterval?

        switch phase {
        case .idle:
            waveformEnvelope = 0.0
            idleOpacity = 1.0
            idleBlur = 0.0
            listeningOpacity = 0.0
            listeningBlur = 5.5
            statusOpacity = 0.0
            resetElapsed = nil

        case .listening:
            let pIn = smoothstep(dt / 0.22)
            waveformEnvelope = smoothstep(dt / 0.35)
            idleOpacity = 1.0 - pIn
            idleBlur = pIn * 5.5
            if let firstAt = firstWordArrivedAt {
                let clearP = smoothstep((wallTime - firstAt) / 0.20)
                listeningOpacity = pIn * (1.0 - clearP)
                listeningBlur = clearP * 6.0
            } else {
                listeningOpacity = pIn
                listeningBlur = (1.0 - pIn) * 5.5
            }
            statusOpacity = pIn
            resetElapsed = nil

        case .thinking:
            let settle = smoothstep(dt / 0.40)
            waveformEnvelope = 1.0 - settle * 0.66
            idleOpacity = 0.0
            idleBlur = 5.5
            listeningOpacity = 0.0
            listeningBlur = 6.0
            statusOpacity = 1.0
            resetElapsed = nil

        case .completed:
            let collapse = smoothstep(dt / 0.68)
            waveformEnvelope = 0.34 * (1.0 - collapse)
            idleOpacity = 0.0
            idleBlur = 5.5
            listeningOpacity = 0.0
            listeningBlur = 6.0
            statusOpacity = 1.0 - smoothstep(dt / 0.18)
            resetElapsed = nil

        case .resetting:
            waveformEnvelope = 0.0
            listeningOpacity = 0.0
            listeningBlur = 6.0
            statusOpacity = 0.0
            resetElapsed = dt
            if dt >= 1.16 {
                let fadeIn = smoothstep((dt - 1.16) / 0.20)
                idleOpacity = fadeIn
                idleBlur = (1.0 - fadeIn) * 5.5
            } else {
                idleOpacity = 0.0
                idleBlur = 5.5
            }
        }

        let elapsedRec = phase == .listening
            ? max(0.0, wallTime - recordingStartedAt)
            : lastRecordingDuration

        return DictationFrameState(
            time: wallTime,
            phase: phase,
            phaseElapsed: dt,
            elapsedRecordingTime: elapsedRec,
            waveformEnvelope: waveformEnvelope,
            audio: phase == .thinking
                ? DictationAudioSnapshot(
                    rmsLevel: 0.60 + 0.14 * sin(wallTime * 3.8),
                    spectrumBands: Array(repeating: 0.55, count: 24),
                    timestamp: wallTime
                )
                : snapshot,
            words: (phase == .resetting && dt > 0.65) ? [] : words,
            idlePlaceholderOpacity: idleOpacity,
            idlePlaceholderBlur: idleBlur,
            listeningPlaceholderOpacity: listeningOpacity,
            listeningPlaceholderBlur: listeningBlur,
            statusOpacity: statusOpacity,
            resetElapsed: resetElapsed
        )
    }

    private func stopAudioEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }
        latestAudio.withLock { $0 = .silent }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - Math Utilities

@inline(__always)
internal func smoothstep(_ x: Double) -> Double {
    let t = min(1.0, max(0.0, x))
    return t * t * (3.0 - 2.0 * t)
}

@inline(__always)
internal func clamp01(_ x: Double) -> Double {
    min(1.0, max(0.0, x))
}

/// Evaluates the 3-dot horizontal thinking wave grayscale brightness (`124/255 ... 244/255`,
/// `1.00s` period, `0.15s` phase lag per dot).
public func thinkingDotLuminance(dotIndex: Int, time: TimeInterval) -> Double {
    let period = 1.00
    let phaseLag = Double(dotIndex) * 0.15
    let angle = 2.0 * Double.pi * ((time - phaseLag) / period)
    let wave = 0.5 + 0.5 * cos(angle)
    let shaped = pow(wave, 1.35)
    return (124.0 + 120.0 * shaped) / 255.0
}

/// Evaluates per-word blur radius and opacity during the `530ms` L-to-R staggered reset sweep.
public func resetSweepWordState(
    wordIndex: Int,
    totalWords: Int,
    resetElapsed: TimeInterval,
    maxBlur: CGFloat
) -> (opacity: Double, blur: CGFloat) {
    let staggerSpan = 0.34
    let wordDuration = 0.19 // 0.34 + 0.19 = 0.53s (530ms exact sweep)
    let wordDelay = totalWords > 1
        ? (Double(wordIndex) / Double(totalWords - 1)) * staggerSpan
        : 0.0
    let p = smoothstep((resetElapsed - wordDelay) / wordDuration)
    return (opacity: 1.0 - p, blur: CGFloat(p) * maxBlur)
}

/// Evaluates per-word materialization crossfade (4x4 glyph mask -> blurred -> crisp vector text).
public func wordResolveProgress(wordLaunchTime: TimeInterval, currentTime: TimeInterval) -> Double {
    let resolveStart = wordLaunchTime + 0.72
    let resolveDuration = 0.34
    return smoothstep((currentTime - resolveStart) / resolveDuration)
}

/// Evaluates source-agnostic button icon morph weights (`~160–180ms` crossfade) from `phase` & `phaseElapsed`.
public func dictationButtonMorphWeights(
    phase: DictationPhase,
    phaseElapsed: TimeInterval
) -> (mic: Double, stop: Double, dots: Double) {
    switch phase {
    case .idle, .resetting:
        return (1.0, 0.0, 0.0)
    case .listening:
        let p = smoothstep(phaseElapsed / 0.18)
        return (1.0 - p, p, 0.0)
    case .thinking:
        let p = smoothstep(phaseElapsed / 0.16)
        return (0.0, 1.0 - p, p)
    case .completed:
        let p = smoothstep(phaseElapsed / 0.18)
        return (p, 0.0, 1.0 - p)
    }
}

/// Formats elapsed recording time into tabular `M:SS` (`0:00` .. `0:06`).
public func formatDictationTimer(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(floor(seconds)))
    let mins = total / 60
    let secs = total % 60
    return "\(mins):\(secs < 10 ? "0" : "")\(secs)"
}

// MARK: - Main SwiftUI Component

/// Production SwiftUI Voice-to-Text Particle Dictation Card supporting both Variant A (`.ascii`)
/// and Variant B (`.dotMatrix`, default), driven at 60fps by `TimelineView(.animation)`.
public struct ParticleDictationCard: View {
    public let style: DictationVisualStyle
    public let metrics: DictationCardMetrics
    public let theme: DictationTheme
    public let source: any DictationSource
    /// Optional fixed timestamp for deterministic snapshot rendering (`ImageRenderer` / previews).
    public let overrideTime: TimeInterval?
    /// Optional override for `@Environment(\.accessibilityReduceMotion)` (useful for previews/testing).
    public let reduceMotionOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var lastAnnouncedPhase: DictationPhase = .idle

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private let waveformGenerator = WaveformFieldGenerator()
    private let glyphSampler = CoreTextGlyphSampler.shared

    public init(
        style: DictationVisualStyle = .dotMatrix,
        metrics: DictationCardMetrics = .reference1080p,
        theme: DictationTheme = .darkDefault,
        source: (any DictationSource)? = nil,
        overrideTime: TimeInterval? = nil,
        reduceMotionOverride: Bool? = nil
    ) {
        self.style = style
        self.metrics = metrics
        self.theme = theme
        self.source = source ?? DemoDictationSource(autoLoop: true, fixedTime: overrideTime)
        self.overrideTime = overrideTime
        self.reduceMotionOverride = reduceMotionOverride
    }

    public var body: some View {
        Group {
            if let overrideTime {
                cardContent(frame: source.frameState(at: overrideTime))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let frame = source.frameState(at: t)
                    cardContent(frame: frame)
                        .onChange(of: frame.phase) { _, newPhase in
                            announcePhaseChangeIfNeeded(newPhase, words: frame.words)
                        }
                }
            }
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight)
        .onDisappear {
            source.teardown()
        }
    }

    @ViewBuilder
    private func cardContent(frame: DictationFrameState) -> some View {
        let ctFont = glyphSampler.cachedSystemFont(size: metrics.fontSize)
        let swiftUIFont = Font(ctFont)
        let laidOutWords = glyphSampler.layoutWords(
            frame.words.map(\.word),
            fontSize: metrics.fontSize,
            lineHeight: metrics.lineHeight,
            maxWidth: metrics.textMaxWidth,
            originOffset: CGPoint(x: metrics.textLeading, y: metrics.textTop),
            sampleStep: metrics.glyphSampleStep
        )
        let cardShape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)

        ZStack(alignment: .topLeading) {
            // 1. Card Surface
            cardShape
                .fill(theme.cardFill)

            // 2. Live 60fps Canvas: Mountain Waveform + Flying Particles + 4x4 Glyph Assembly Mask
            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, size in
                if reduceMotion {
                    drawReducedMotionWaveform(in: &context, size: size, frame: frame)
                } else {
                    drawWaveform(in: &context, size: size, frame: frame)
                    drawParticlesAndGlyphMasks(
                        in: &context,
                        size: size,
                        frame: frame,
                        laidOutWords: laidOutWords
                    )
                }
            }
            .allowsHitTesting(false)

            // 3. Placeholders ("Tap the key and speak" <-> "Listening...")
            if frame.idlePlaceholderOpacity > 0.005 {
                Text("Tap the key and speak")
                    .font(swiftUIFont)
                    .foregroundStyle(theme.placeholderText)
                    .blur(radius: reduceMotion ? 0 : CGFloat(frame.idlePlaceholderBlur) * metrics.scale)
                    .opacity(frame.idlePlaceholderOpacity)
                    .offset(x: metrics.textLeading, y: metrics.textTop)
                    .allowsHitTesting(false)
            }

            if frame.listeningPlaceholderOpacity > 0.005 {
                Text("Listening...")
                    .font(swiftUIFont)
                    .foregroundStyle(theme.placeholderText)
                    .blur(radius: reduceMotion ? 0 : CGFloat(frame.listeningPlaceholderBlur) * metrics.scale)
                    .opacity(frame.listeningPlaceholderOpacity)
                    .offset(x: metrics.textLeading, y: metrics.textTop)
                    .allowsHitTesting(false)
            }

            // 4. Resolved Vector Words (aligned 1:1 with CoreText 4x4 glyph sample origins)
            ForEach(laidOutWords) { word in
                let wordEvent = frame.words[word.id]
                let resolveP = reduceMotion
                    ? smoothstep((frame.time - wordEvent.launchTime) / 0.18)
                    : wordResolveProgress(wordLaunchTime: wordEvent.launchTime, currentTime: frame.time)

                let baseOpacity = resolveP
                let baseBlur = reduceMotion ? 0.0 : CGFloat(1.0 - resolveP) * 7.5 * metrics.scale

                let resetFactor: (opacity: Double, blur: CGFloat) = {
                    guard let resetElapsed = frame.resetElapsed else {
                        return (1.0, 0.0)
                    }
                    if reduceMotion {
                        let fade = 1.0 - smoothstep(resetElapsed / DemoDictationSource.resetSweepDuration)
                        return (fade, 0.0)
                    }
                    return resetSweepWordState(
                        wordIndex: word.id,
                        totalWords: laidOutWords.count,
                        resetElapsed: resetElapsed,
                        maxBlur: 9.0 * metrics.scale
                    )
                }()

                let finalOpacity = baseOpacity * resetFactor.opacity
                let finalBlur = baseBlur + resetFactor.blur

                if finalOpacity > 0.004 {
                    Text(word.text)
                        .font(swiftUIFont)
                        .foregroundStyle(theme.transcriptText)
                        .blur(radius: finalBlur)
                        .opacity(finalOpacity)
                        .offset(x: word.origin.x, y: word.origin.y)
                        .allowsHitTesting(false)
                }
            }

            // 5. Top-Right Status Indicator (`• 0:00..0:06` / pulsing `• thinking`)
            statusBadge(frame: frame)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, metrics.statusTop)
                .padding(.trailing, metrics.statusTrailing)
                .allowsHitTesting(false)

            // 6. Bottom-Right Interactive Action Button (Mic <-> Stop Square <-> 3-Dot Wave)
            actionButton(frame: frame)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, metrics.buttonTrailing)
                .padding(.bottom, metrics.buttonBottom)
        }
        .clipShape(cardShape)
        .overlay(
            cardShape
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.cardBorderTop, theme.cardBorderBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: metrics.borderWidth
                )
        )
        .shadow(
            color: Color.black.opacity(0.55),
            radius: 22.0 * metrics.scale,
            x: 0,
            y: 12.0 * metrics.scale
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice dictation card")
        .accessibilityValue(accessibilityTranscriptSummary(for: frame))
    }

    // MARK: - Top-Right Status Badge

    @ViewBuilder
    private func statusBadge(frame: DictationFrameState) -> some View {
        let isThinking = frame.phase == .thinking || frame.phase == .completed
        let dotPulse: Double = {
            guard frame.phase == .thinking && !reduceMotion else { return 1.0 }
            let wave = 0.5 + 0.5 * sin(frame.time * 2.0 * Double.pi / 1.15)
            return 0.58 + 0.42 * wave
        }()

        HStack(spacing: metrics.statusSpacing) {
            Circle()
                .fill(theme.statusDot)
                .frame(width: metrics.statusDotDiameter, height: metrics.statusDotDiameter)
                .opacity(dotPulse)

            Text(isThinking ? "thinking" : formatDictationTimer(frame.elapsedRecordingTime))
                .font(.system(size: metrics.statusFontSize, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(theme.statusText)
        }
        .opacity(frame.statusOpacity)
        .accessibilityHidden(frame.statusOpacity < 0.1)
    }

    // MARK: - Bottom-Right Action Button & Morphs

    @ViewBuilder
    private func actionButton(frame: DictationFrameState) -> some View {
        let buttonState = buttonMorphWeights(for: frame)

        Button {
            source.handlePrimaryButtonTap(at: Date().timeIntervalSinceReferenceDate)
        } label: {
            ZStack {
                Circle()
                    .fill(theme.buttonFill)
                    .overlay(
                        Circle()
                            .strokeBorder(theme.buttonBorder, lineWidth: max(1.0, 1.0 * metrics.scale))
                    )

                // Mic outline icon (idle / completed / resetting)
                if buttonState.mic > 0.01 {
                    MicrophoneOutlineIcon(lineWidth: 2.3 * metrics.scale)
                        .stroke(
                            theme.buttonIcon,
                            style: StrokeStyle(lineWidth: 2.3 * metrics.scale, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 24.0 * metrics.scale, height: 28.0 * metrics.scale)
                        .scaleEffect(reduceMotion ? 1.0 : (0.55 + 0.45 * buttonState.mic))
                        .blur(radius: reduceMotion ? 0 : CGFloat(1.0 - buttonState.mic) * 4.0 * metrics.scale)
                        .opacity(buttonState.mic)
                }

                // Rounded stop square icon (listening)
                if buttonState.stop > 0.01 {
                    RoundedRectangle(cornerRadius: 5.0 * metrics.scale, style: .continuous)
                        .fill(theme.buttonIcon)
                        .frame(width: 18.5 * metrics.scale, height: 18.5 * metrics.scale)
                        .scaleEffect(reduceMotion ? 1.0 : (0.55 + 0.45 * buttonState.stop))
                        .blur(radius: reduceMotion ? 0 : CGFloat(1.0 - buttonState.stop) * 4.0 * metrics.scale)
                        .opacity(buttonState.stop)
                }

                // Three horizontal dots with 1.00s L-to-R brightness wave (thinking)
                if buttonState.dots > 0.01 {
                    HStack(spacing: 5.5 * metrics.scale) {
                        ForEach(0..<3, id: \.self) { index in
                            let lum = reduceMotion
                                ? 0.78
                                : thinkingDotLuminance(dotIndex: index, time: frame.time)
                            Circle()
                                .fill(Color(white: lum))
                                .frame(width: 6.2 * metrics.scale, height: 6.2 * metrics.scale)
                        }
                    }
                    .scaleEffect(reduceMotion ? 1.0 : (0.55 + 0.45 * buttonState.dots))
                    .blur(radius: reduceMotion ? 0 : CGFloat(1.0 - buttonState.dots) * 4.0 * metrics.scale)
                    .opacity(buttonState.dots)
                }
            }
            .frame(width: metrics.buttonDiameter, height: metrics.buttonDiameter)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(buttonAccessibilityLabel(for: frame.phase))
        .accessibilityHint(frame.phase.accessibilityDescription)
    }

    private func buttonMorphWeights(for frame: DictationFrameState) -> (mic: Double, stop: Double, dots: Double) {
        dictationButtonMorphWeights(phase: frame.phase, phaseElapsed: frame.phaseElapsed)
    }

    // MARK: - Canvas Waveform Rendering (Variant A & Variant B)

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize, frame: DictationFrameState) {
        guard frame.waveformEnvelope > 0.002 else { return }

        // Soft ambient white mountain glow behind both Variant A and Variant B waveforms.
        let peakHeight = size.height * 0.62 * frame.waveformEnvelope * (0.45 + 0.55 * frame.audio.rmsLevel)
        let glowCenter = CGPoint(x: size.width * 0.50, y: size.height + peakHeight * 0.15)
        let glowRadius = max(40.0 * metrics.scale, peakHeight * 1.85)
        let ambientGlow = Gradient(colors: [
            Color.white.opacity(0.16 * frame.waveformEnvelope),
            Color.white.opacity(0.06 * frame.waveformEnvelope),
            Color.white.opacity(0.0)
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                ambientGlow,
                center: glowCenter,
                startRadius: 0,
                endRadius: glowRadius
            )
        )

        switch style {
        case .ascii:
            drawASCIIWaveform(in: &context, size: size, frame: frame)
        case .dotMatrix:
            drawDotMatrixWaveform(in: &context, size: size, frame: frame)
        }
    }

    private func drawASCIIWaveform(in context: inout GraphicsContext, size: CGSize, frame: DictationFrameState) {
        let cellW = metrics.asciiCellWidth
        let cellH = metrics.asciiCellHeight
        let cols = min(65, max(12, Int(floor((size.width * 0.78) / cellW))))
        let maxRows = 10
        let gridWidth = CGFloat(cols) * cellW
        let startX = (size.width - gridWidth) * 0.5
        let bottomY = size.height - 4.0 * metrics.scale

        let monoFont = Font.system(size: metrics.asciiFontSize, weight: .regular, design: .monospaced)
        // Per-frame glyph resolution cache: resolves each distinct ASCII character at most once!
        var resolvedGlyphs: [Character: GraphicsContext.ResolvedText] = [:]
        resolvedGlyphs.reserveCapacity(WaveformFieldGenerator.paulBourkeRamp.count)

        for row in 0..<maxRows {
            let cy = bottomY - (CGFloat(row) + 0.5) * cellH
            guard cy > 0 else { continue }

            for col in 0..<cols {
                guard let cell = waveformGenerator.asciiCell(
                    col: col,
                    totalCols: cols,
                    row: row,
                    maxRows: maxRows,
                    time: frame.time,
                    audio: frame.audio,
                    envelope: frame.waveformEnvelope
                ) else { continue }

                let resolved: GraphicsContext.ResolvedText
                if let cached = resolvedGlyphs[cell.character] {
                    resolved = cached
                } else {
                    let r = context.resolve(
                        Text(String(cell.character))
                            .font(monoFont)
                            .foregroundStyle(Color.white)
                    )
                    resolvedGlyphs[cell.character] = r
                    resolved = r
                }

                let cx = startX + (CGFloat(col) + 0.5) * cellW
                context.opacity = cell.opacity
                context.draw(resolved, at: CGPoint(x: cx, y: cy), anchor: .center)
            }
        }
        context.opacity = 1.0
    }

    private func drawDotMatrixWaveform(in context: inout GraphicsContext, size: CGSize, frame: DictationFrameState) {
        let cellSize = metrics.dotCellSize
        let cols = min(65, max(14, Int(floor((size.width * 0.78) / cellSize))))
        let maxRows = 16
        let gridWidth = CGFloat(cols) * cellSize
        let startX = (size.width - gridWidth) * 0.5
        let bottomY = size.height - 5.0 * metrics.scale

        let smallR = metrics.dotSmallDiameter * 0.5
        let colonR = metrics.dotColonDiameter * 0.5
        let colonHalfGap = metrics.dotColonVerticalGap * 0.5
        let orbR = metrics.dotOrbDiameter * 0.5
        let bloomR = metrics.dotOrbBloomRadius

        // Pass 1: Soft radial bloom halos beneath glowing `●` orbs so cores sit cleanly on top.
        var glowingOrbs: [(center: CGPoint, intensity: Double)] = []
        glowingOrbs.reserveCapacity(128)

        for row in 0..<maxRows {
            let cy = bottomY - (CGFloat(row) + 0.5) * cellSize
            guard cy > 0 else { continue }

            for col in 0..<cols {
                let primitive = waveformGenerator.dotMatrixCell(
                    col: col,
                    totalCols: cols,
                    row: row,
                    maxRows: maxRows,
                    time: frame.time,
                    audio: frame.audio,
                    envelope: frame.waveformEnvelope
                )
                let cx = startX + (CGFloat(col) + 0.5) * cellSize

                switch primitive {
                case .empty:
                    continue

                case .singleDot(let opacity):
                    let rect = CGRect(
                        x: cx - smallR,
                        y: cy + cellSize * 0.16 - smallR,
                        width: smallR * 2.0,
                        height: smallR * 2.0
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(opacity)))

                case .verticalColon(let opacity):
                    let topDot = CGRect(
                        x: cx - colonR,
                        y: cy - colonHalfGap - colonR,
                        width: colonR * 2.0,
                        height: colonR * 2.0
                    )
                    let bottomDot = CGRect(
                        x: cx - colonR,
                        y: cy + colonHalfGap - colonR,
                        width: colonR * 2.0,
                        height: colonR * 2.0
                    )
                    let color = GraphicsContext.Shading.color(Color.white.opacity(opacity))
                    context.fill(Path(ellipseIn: topDot), with: color)
                    context.fill(Path(ellipseIn: bottomDot), with: color)

                case .glowingOrb(let intensity):
                    glowingOrbs.append((CGPoint(x: cx, y: cy), intensity))
                }
            }
        }

        // Draw radial bloom halos first, then crisp white 8pt orb cores.
        for orb in glowingOrbs {
            let bloomRect = CGRect(
                x: orb.center.x - bloomR,
                y: orb.center.y - bloomR,
                width: bloomR * 2.0,
                height: bloomR * 2.0
            )
            let halo = Gradient(colors: [
                Color.white.opacity(0.32 * orb.intensity),
                Color.white.opacity(0.10 * orb.intensity),
                Color.white.opacity(0.0)
            ])
            context.fill(
                Path(ellipseIn: bloomRect),
                with: .radialGradient(halo, center: orb.center, startRadius: orbR * 0.35, endRadius: bloomR)
            )
        }

        for orb in glowingOrbs {
            let coreRect = CGRect(
                x: orb.center.x - orbR,
                y: orb.center.y - orbR,
                width: orbR * 2.0,
                height: orbR * 2.0
            )
            context.fill(
                Path(ellipseIn: coreRect),
                with: .color(Color.white.opacity(min(1.0, orb.intensity)))
            )
        }
    }

    private func drawReducedMotionWaveform(
        in context: inout GraphicsContext,
        size: CGSize,
        frame: DictationFrameState
    ) {
        guard frame.waveformEnvelope > 0.01 else { return }
        let barCount = 19
        let totalWidth = size.width * 0.42
        let spacing = totalWidth / CGFloat(barCount)
        let startX = (size.width - totalWidth) * 0.5
        let baseY = size.height - 20.0 * metrics.scale

        for i in 0..<barCount {
            let u = (Double(i) / Double(barCount - 1)) * 2.0 - 1.0
            let bell = exp(-pow(u * 2.0, 2.0))
            let level = bell * frame.waveformEnvelope * (0.35 + 0.65 * frame.audio.rmsLevel)
            let h = max(3.0 * metrics.scale, CGFloat(level) * 44.0 * metrics.scale)
            let rect = CGRect(
                x: startX + CGFloat(i) * spacing,
                y: baseY - h,
                width: 4.0 * metrics.scale,
                height: h
            )
            let path = style == .ascii
                ? Path(rect)
                : Path(roundedRect: rect, cornerRadius: 2.0 * metrics.scale)
            context.fill(path, with: .color(Color.white.opacity(0.28 + 0.50 * level)))
        }
    }

    // MARK: - Flying Speech Particles & 4x4 Bitmap Glyph Mask Assembly

    private func drawParticlesAndGlyphMasks(
        in context: inout GraphicsContext,
        size: CGSize,
        frame: DictationFrameState,
        laidOutWords: [LaidOutWord]
    ) {
        guard !laidOutWords.isEmpty else { return }

        let waveCrestY = size.height
            - max(26.0 * metrics.scale, size.height * 0.48 * max(0.25, frame.waveformEnvelope))
        let particleSize = metrics.particleSize
        let glyphCellDrawSize = metrics.glyphSampleStep * 0.64

        for word in laidOutWords {
            let wordEvent = frame.words[word.id]
            let resolveP = wordResolveProgress(wordLaunchTime: wordEvent.launchTime, currentTime: frame.time)
            let maskAlpha = 1.0 - resolveP

            // Skip completely settled words whose vector typography is already 100% crisp.
            if maskAlpha <= 0.004 && (frame.time - wordEvent.launchTime) > 1.25 {
                continue
            }

            let wordWidth = max(1.0, word.size.width)

            for sample in word.glyphSamples {
                let r1 = Double(sample.seed & 0xFFFF) / 65535.0
                let r2 = Double((sample.seed >> 16) & 0xFFFF) / 65535.0
                let r3 = Double((sample.seed >> 32) & 0xFFFF) / 65535.0

                let normX = Double(sample.localX / wordWidth)
                let launchDelay = normX * 0.16 + r1 * 0.12
                let flightDuration = 0.34 + r2 * 0.12
                let elapsed = frame.time - (wordEvent.launchTime + launchDelay)
                if elapsed < 0 { continue }

                let target = CGPoint(
                    x: word.origin.x + sample.localX,
                    y: word.origin.y + sample.localY
                )

                if elapsed < flightDuration {
                    // Stage 1: Particle flying from waveform crest along curved quadratic Bézier arc.
                    let rawP = clamp01(elapsed / flightDuration)
                    let u = 1.0 - pow(1.0 - rawP, 1.65)
                    // Taper head size, flight halo, and comet tail smoothly on final approach so adjacent
                    // 4x4 glyph cells never over-bloom into a bright bar upon landing.
                    let landingTaper = smoothstep((rawP - 0.66) / 0.34)
                    let haloFactor = 1.0 - landingTaper
                    let currentHeadSize = particleSize * CGFloat(1.0 - landingTaper)
                        + glyphCellDrawSize * CGFloat(landingTaper)

                    let spawn = CGPoint(
                        x: size.width * 0.50 + CGFloat(r3 - 0.5) * size.width * 0.22,
                        y: waveCrestY + CGFloat(r1 - 0.25) * 44.0 * metrics.scale
                    )
                    let lateralBias: CGFloat = target.x < spawn.x ? -24.0 : 24.0
                    let control = CGPoint(
                        x: (spawn.x + target.x) * 0.5 + (lateralBias + CGFloat(r2 - 0.5) * 46.0) * metrics.scale,
                        y: max(
                            18.0 * metrics.scale,
                            target.y + (spawn.y - target.y) * 0.20 - CGFloat(20.0 + 30.0 * r1) * metrics.scale
                        )
                    )

                    let head = quadBezier(p0: spawn, p1: control, p2: target, t: u)
                    let tailSpan = 0.092 * sin(rawP * Double.pi) * (1.0 - landingTaper * 0.90)
                    let tail = quadBezier(p0: spawn, p1: control, p2: target, t: max(0.0, u - tailSpan))

                    // Velocity-aligned tapered comet trail (fades cleanly before entering the 4x4 glyph grid).
                    if tailSpan > 0.005 {
                        var trailPath = Path()
                        trailPath.move(to: head)
                        trailPath.addLine(to: tail)
                        let trailGradient = Gradient(colors: [
                            Color.white.opacity(0.54 * (1.0 - landingTaper * 0.75)),
                            Color.white.opacity(0.0)
                        ])
                        context.stroke(
                            trailPath,
                            with: .linearGradient(trailGradient, startPoint: head, endPoint: tail),
                            style: StrokeStyle(
                                lineWidth: (style == .ascii ? 1.75 : 2.0) * metrics.scale,
                                lineCap: .round
                            )
                        )
                    }

                    // Particle head sprite (Variant A = crisp square, Variant B = glowing circle).
                    let fadeIn = smoothstep(rawP / 0.12)
                    let headRect = CGRect(
                        x: head.x - currentHeadSize * 0.5,
                        y: head.y - currentHeadSize * 0.5,
                        width: currentHeadSize,
                        height: currentHeadSize
                    )
                    let headAlpha = (0.96 * (1.0 - landingTaper)
                        + (0.18 + 0.72 * Double(sample.intensity)) * landingTaper) * fadeIn

                    switch style {
                    case .ascii:
                        if haloFactor > 0.02 {
                            let softRect = headRect.insetBy(dx: -1.4 * metrics.scale, dy: -1.4 * metrics.scale)
                            context.fill(
                                Path(softRect),
                                with: .color(Color.white.opacity(0.16 * haloFactor * fadeIn))
                            )
                        }
                        context.fill(Path(headRect), with: .color(Color.white.opacity(headAlpha)))

                    case .dotMatrix:
                        if haloFactor > 0.02 {
                            let haloR = currentHeadSize * 1.40
                            let haloRect = CGRect(
                                x: head.x - haloR,
                                y: head.y - haloR,
                                width: haloR * 2.0,
                                height: haloR * 2.0
                            )
                            let halo = Gradient(colors: [
                                Color.white.opacity(0.30 * haloFactor * fadeIn),
                                Color.white.opacity(0.0)
                            ])
                            context.fill(
                                Path(ellipseIn: haloRect),
                                with: .radialGradient(halo, center: head, startRadius: 0, endRadius: haloR)
                            )
                        }
                        context.fill(Path(ellipseIn: headRect), with: .color(Color.white.opacity(headAlpha)))
                    }
                } else if maskAlpha > 0.004 {
                    // Stage 2: Landed particle locked into crisp, separated 4x4 bitmap glyph matrix.
                    let sinceLand = elapsed - flightDuration
                    let arrivalSpark = max(0.0, 1.0 - sinceLand / 0.10) * 0.12
                    let lum = min(0.92, (0.16 + 0.72 * Double(sample.intensity)) + arrivalSpark) * maskAlpha

                    let cellRect = CGRect(
                        x: target.x - glyphCellDrawSize * 0.5,
                        y: target.y - glyphCellDrawSize * 0.5,
                        width: glyphCellDrawSize,
                        height: glyphCellDrawSize
                    )

                    switch style {
                    case .ascii:
                        context.fill(Path(cellRect), with: .color(Color.white.opacity(lum)))

                    case .dotMatrix:
                        let glowRect = cellRect.insetBy(dx: -0.55 * metrics.scale, dy: -0.55 * metrics.scale)
                        context.fill(Path(ellipseIn: glowRect), with: .color(Color.white.opacity(lum * 0.08)))
                        context.fill(Path(ellipseIn: cellRect), with: .color(Color.white.opacity(lum)))
                    }
                }
            }
        }
    }

    @inline(__always)
    private func quadBezier(p0: CGPoint, p1: CGPoint, p2: CGPoint, t: Double) -> CGPoint {
        let u = CGFloat(1.0 - t)
        let tt = CGFloat(t)
        let x = u * u * p0.x + 2.0 * u * tt * p1.x + tt * tt * p2.x
        let y = u * u * p0.y + 2.0 * u * tt * p1.y + tt * tt * p2.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Accessibility Helpers

    private func buttonAccessibilityLabel(for phase: DictationPhase) -> String {
        switch phase {
        case .idle, .completed, .resetting: return "Start dictation"
        case .listening: return "Stop dictation"
        case .thinking: return "Finalizing dictation"
        }
    }

    private func accessibilityTranscriptSummary(for frame: DictationFrameState) -> String {
        let text = frame.words.map(\.word).joined(separator: " ")
        if text.isEmpty {
            return frame.phase.accessibilityDescription
        }
        return "\(frame.phase.accessibilityDescription) Transcript: \(text)"
    }

    private func announcePhaseChangeIfNeeded(_ newPhase: DictationPhase, words: [DictationWordEvent]) {
        guard newPhase != lastAnnouncedPhase else { return }
        lastAnnouncedPhase = newPhase
        let message: String
        if newPhase == .completed, !words.isEmpty {
            message = "Dictation complete: \(words.map(\.word).joined(separator: " "))"
        } else {
            message = newPhase.accessibilityDescription
        }
        AccessibilityNotification.Announcement(message).post()
    }
}

// MARK: - Custom Stroked Microphone Vector Icon

/// Crisp outline microphone shape matching the idle/completed button glyph across macOS & iOS.
public struct MicrophoneOutlineIcon: Shape {
    public let lineWidth: CGFloat

    public init(lineWidth: CGFloat = 2.3) {
        self.lineWidth = lineWidth
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX

        // Capsule body
        let capW = w * 0.44
        let capH = h * 0.52
        let capRect = CGRect(x: cx - capW * 0.5, y: h * 0.06, width: capW, height: capH)
        path.addRoundedRect(in: capRect, cornerSize: CGSize(width: capW * 0.5, height: capW * 0.5))

        // Lower cradle U-arc
        let arcR = w * 0.40
        let arcCenterY = h * 0.48
        path.move(to: CGPoint(x: cx - arcR, y: arcCenterY))
        path.addArc(
            center: CGPoint(x: cx, y: arcCenterY),
            radius: arcR,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Vertical stem
        let stemTop = arcCenterY + arcR
        let stemBottom = h * 0.94
        path.move(to: CGPoint(x: cx, y: stemTop))
        path.addLine(to: CGPoint(x: cx, y: stemBottom))

        // Base horizontal foot
        let footHalf = w * 0.22
        path.move(to: CGPoint(x: cx - footHalf, y: stemBottom))
        path.addLine(to: CGPoint(x: cx + footHalf, y: stemBottom))

        return path
    }
}

// MARK: - Side-by-Side (Top/Bottom) A/B Comparison Showcase View

/// Reproduces the reference 1080x1080 stacked A/B comparison canvas with synchronized Variant A & B cards.
public struct ParticleDictationComparisonShowcase: View {
    public let theme: DictationTheme
    public let source: any DictationSource
    public let overrideTime: TimeInterval?

    public init(
        theme: DictationTheme = .darkDefault,
        source: (any DictationSource)? = nil,
        overrideTime: TimeInterval? = nil
    ) {
        self.theme = theme
        self.source = source ?? DemoDictationSource(autoLoop: true, fixedTime: overrideTime)
        self.overrideTime = overrideTime
    }

    public var body: some View {
        ZStack {
            theme.canvasBackground

            VStack(spacing: 30) {
                badge("A")
                ParticleDictationCard(
                    style: .ascii,
                    metrics: .reference1080p,
                    theme: theme,
                    source: source,
                    overrideTime: overrideTime
                )

                Spacer().frame(height: 86)

                badge("B")
                ParticleDictationCard(
                    style: .dotMatrix,
                    metrics: .reference1080p,
                    theme: theme,
                    source: source,
                    overrideTime: overrideTime
                )
            }
        }
        .frame(width: 1080, height: 1080)
    }

    private func badge(_ letter: String) -> some View {
        ZStack {
            Circle()
                .fill(Color(red: 239.0 / 255.0, green: 239.0 / 255.0, blue: 239.0 / 255.0))
                .frame(width: 56, height: 56)
            Text(letter)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color(red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 18.0 / 255.0))
        }
    }
}

#if DEBUG
#Preview("A/B Comparison (t=2.5s)") {
    ParticleDictationComparisonShowcase(overrideTime: 2.50)
        .scaleEffect(0.6)
        .frame(width: 648, height: 648)
}

#Preview("Live Loop (Variant B Default)") {
    ZStack {
        DictationTheme.darkDefault.canvasBackground.ignoresSafeArea()
        ParticleDictationCard(style: .dotMatrix, metrics: .desktop)
    }
    .frame(width: 680, height: 280)
}
#endif
