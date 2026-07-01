import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Type-specific content carried by an EditorSegment.
/// Each case maps to a distinct track kind and rendering path.
public enum SegmentContent: Sendable, Hashable {
    case video(VideoContent)
    case image(ImageContent)
    case text(TextContent)
    case subtitle(SubtitleContent)
    case audio(AudioContent)
}

// MARK: - Video

extension SegmentContent {
    public struct VideoContent: Sendable, Hashable, Codable {
        public var fit: ContentFit
        public var isMuted: Bool

        public init(fit: ContentFit = .cover, isMuted: Bool = false) {
            self.fit     = fit
            self.isMuted = isMuted
        }
    }
}

// MARK: - Image

extension SegmentContent {
    public struct ImageContent: Sendable, Hashable, Codable {
        public var fit: ContentFit
        public var motionPreset: ImageMotionPreset?
        /// Background blur radius (nil = no blur).
        public var blurRadius: Double?
        public var depthEffect: DepthEffect?
        /// v6: Keyframe animation tracks. nil = static image (identity transform).
        /// When non-nil, KeyframeEvaluator applies per-frame transforms in playback/export.
        /// Legacy drafts (nil) are expanded via AnimationMacro from motionPreset/depthEffect.
        public var keyframes: KeyframeSet?
        /// v6 P5: client-side preset identifier written by ImageAnimationPresetRegistry.
        /// UI-display hint only — the render path reads only `keyframes`.
        public var animationPresetID: String?

        public init(
            fit: ContentFit = .cover,
            motionPreset: ImageMotionPreset? = nil,
            blurRadius: Double? = nil,
            depthEffect: DepthEffect? = nil,
            keyframes: KeyframeSet? = nil,
            animationPresetID: String? = nil
        ) {
            self.fit               = fit
            self.motionPreset      = motionPreset
            self.blurRadius        = blurRadius
            self.depthEffect       = depthEffect
            self.keyframes         = keyframes
            self.animationPresetID = animationPresetID
        }

        // MARK: Codable (v6 backward compat: keyframes / animationPresetID are new)

        private enum CodingKeys: String, CodingKey {
            case fit, motionPreset, blurRadius, depthEffect, keyframes, animationPresetID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.fit               = try c.decodeIfPresent(ContentFit.self,          forKey: .fit)               ?? .cover
            self.motionPreset      = try c.decodeIfPresent(ImageMotionPreset?.self,  forKey: .motionPreset)      ?? nil
            self.blurRadius        = try c.decodeIfPresent(Double?.self,             forKey: .blurRadius)        ?? nil
            self.depthEffect       = try c.decodeIfPresent(DepthEffect?.self,        forKey: .depthEffect)       ?? nil
            self.keyframes         = try c.decodeIfPresent(KeyframeSet?.self,        forKey: .keyframes)         ?? nil
            self.animationPresetID = try c.decodeIfPresent(String.self,              forKey: .animationPresetID)
        }
    }

    public struct DepthEffect: Sendable, Hashable, Codable {
        public var moveDirection: String
        public var intensity: Double
        public var duration: Double

        public init(moveDirection: String, intensity: Double, duration: Double) {
            self.moveDirection = moveDirection
            self.intensity     = intensity
            self.duration      = duration
        }
    }
}

// MARK: - Text

extension SegmentContent {
    public struct TextContent: Sendable, Hashable, Codable {
        public var text: String
        public var style: TextStyle
        public var position: NormalizedPoint
        public var anchor: AnchorPoint
        public var enterAnimation: TextAnimation?
        public var exitAnimation: TextAnimation?

        public init(
            text: String,
            style: TextStyle = .default,
            position: NormalizedPoint = .center,
            anchor: AnchorPoint = .center,
            enterAnimation: TextAnimation? = nil,
            exitAnimation: TextAnimation? = nil
        ) {
            self.text           = text
            self.style          = style
            self.position       = position
            self.anchor         = anchor
            self.enterAnimation = enterAnimation
            self.exitAnimation  = exitAnimation
        }
    }
}

// MARK: - Subtitle

extension SegmentContent {
    public struct SubtitleContent: Sendable, Hashable, Codable {
        public var text: String
        public var segments: [SubtitleSegmentItem]?
        /// Unified style — same TextStyle as `.text` segments.  V3 final.
        public var style: TextStyle
        /// Vertical position (0=top, 1=bottom).  Moved from deprecated SubtitleStyle.
        public var positionY: Double?
        /// Max characters per line before wrapping.
        public var maxCharsPerLine: Int?

        public init(
            text: String,
            segments: [SubtitleSegmentItem]? = nil,
            style: TextStyle = .default,
            positionY: Double? = nil,
            maxCharsPerLine: Int? = nil
        ) {
            self.text            = text
            self.segments        = segments
            self.style           = style
            self.positionY       = positionY
            self.maxCharsPerLine = maxCharsPerLine
        }

        // MARK: Codable (backward compat with old SubtitleStyle)

        private enum CodingKeys: String, CodingKey {
            case text, segments, style, positionY, maxCharsPerLine
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.text     = try c.decode(String.self, forKey: .text)
            self.segments = try c.decodeIfPresent([SubtitleSegmentItem].self, forKey: .segments)

            // New-format direct fields (decoded regardless so they win when present).
            self.positionY       = try c.decodeIfPresent(Double.self, forKey: .positionY)
            self.maxCharsPerLine = try c.decodeIfPresent(Int.self,    forKey: .maxCharsPerLine)

            // Backward compat: old SubtitleStyle? → TextStyle migration.
            if let old = try c.decodeIfPresent(SubtitleStyle.self, forKey: .style) {
                if self.positionY       == nil { self.positionY       = old.positionY }
                if self.maxCharsPerLine == nil { self.maxCharsPerLine = old.maxCharsPerLine }
                self.style = TextStyle(
                    fontSize:        old.fontSize        ?? 34,
                    fontWeight:      old.fontWeight      ?? .regular,
                    color:           old.color           ?? "#FFFFFF",
                    backgroundColor: old.backgroundColor
                )
            } else {
                self.style = try c.decodeIfPresent(TextStyle.self, forKey: .style) ?? .default
            }
        }
    }

    public struct SubtitleSegmentItem: Sendable, Hashable, Codable {
        public var text: String
        public var isHighlighted: Bool
        public var color: String?
        public var fontWeight: FontWeight?

        public init(text: String, isHighlighted: Bool = false, color: String? = nil, fontWeight: FontWeight? = nil) {
            self.text          = text
            self.isHighlighted = isHighlighted
            self.color         = color
            self.fontWeight    = fontWeight
        }
    }
}

// MARK: - Audio

extension SegmentContent {
    public struct AudioContent: Sendable, Hashable, Codable {
        public var volume: Double
        public var fadeInDuration: Double
        public var fadeOutDuration: Double
        public var isLooping: Bool
        public var isMuted: Bool
        /// v3 tts-spec §3.1: when non-nil, this audio segment was generated by
        /// the client-side TTS engine and points back to its source `.text` or
        /// `.subtitle` segment. EditorStore uses `textHash` to detect when the
        /// source text was edited so it can offer "重新生成" via a toast.
        public var ttsSource: TTSSource?

        public init(
            volume: Double = 1.0,
            fadeInDuration: Double = 0,
            fadeOutDuration: Double = 0,
            isLooping: Bool = false,
            isMuted: Bool = false,
            ttsSource: TTSSource? = nil
        ) {
            self.volume          = volume
            self.fadeInDuration  = fadeInDuration
            self.fadeOutDuration = fadeOutDuration
            self.isLooping       = isLooping
            self.isMuted         = isMuted
            self.ttsSource       = ttsSource
        }

        // MARK: - Codable (custom for v1/v2 backward compat)

        private enum CodingKeys: String, CodingKey {
            case volume, fadeInDuration, fadeOutDuration, isLooping, isMuted, ttsSource
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.volume          = try c.decode(Double.self, forKey: .volume)
            self.fadeInDuration  = try c.decode(Double.self, forKey: .fadeInDuration)
            self.fadeOutDuration = try c.decode(Double.self, forKey: .fadeOutDuration)
            self.isLooping       = try c.decode(Bool.self,   forKey: .isLooping)
            self.isMuted         = try c.decode(Bool.self,   forKey: .isMuted)
            // v3 field — missing in v1/v2 drafts; default nil.
            self.ttsSource       = try c.decodeIfPresent(TTSSource.self, forKey: .ttsSource)
        }
    }

    /// v3 tts-spec §3.1: single-direction link from a TTS-generated audio segment
    /// back to its source `.text` / `.subtitle` segment. `textHash` enables stale
    /// detection on text edits without scanning every segment.
    public struct TTSSource: Sendable, Hashable, Codable {
        /// UUID of the source `.text` or `.subtitle` segment.
        public var sourceSegmentID: UUID
        /// SHA-1 of the trimmed source text at synthesis time.
        public var textHash: String
        /// `AVSpeechSynthesisVoice.identifier` used for synthesis.
        public var voice: String
        /// User-facing playback rate, 0.5...2.0 (1.0 = natural).
        public var rate: Double

        public init(sourceSegmentID: UUID, textHash: String, voice: String, rate: Double) {
            self.sourceSegmentID = sourceSegmentID
            self.textHash        = textHash
            self.voice           = voice
            self.rate            = rate
        }
    }
}

// MARK: - Supporting Style Types

public enum TextAlignment: String, Sendable, Hashable, Codable, CaseIterable {
    case leading  = "leading"
    case center   = "center"
    case trailing = "trailing"

    #if canImport(UIKit)
    public var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading:  return .left
        case .center:   return .center
        case .trailing: return .right
        }
    }
    #endif
}

public enum ContentFit: String, Sendable, Hashable, Codable, CaseIterable {
    case cover, contain, fill
}

public enum ImageMotionPreset: String, Sendable, Hashable, Codable, CaseIterable {
    case zoomIn     = "zoom_in"
    case zoomInSlow = "zoom_in_slow"
    case zoomOut    = "zoom_out"
    case panLeft    = "pan_left"
    case panRight   = "pan_right"
    case panUp      = "pan_up"
    case panDown    = "pan_down"
    case fade
    case still
}

public struct TextStyle: Sendable, Hashable, Codable {
    public var fontSize: Double
    public var fontWeight: FontWeight
    /// Hex color string: #RRGGBB or #RRGGBBAA
    public var color: String
    public var backgroundColor: String?
    public var backgroundRadius: Double
    public var paddingH: Double
    public var paddingV: Double
    /// v3 P1 (text-entry-spec §9): UIFont family name (e.g. "PingFang SC", "Songti SC").
    /// nil = default PingFang SC. Resolved at render time via `SystemFontCatalog`.
    public var fontName: String?

    // MARK: - v3 P4 (text-entry-spec §11): full style attributes

    /// Stroke (outline) color hex. nil = no stroke.
    public var strokeColor: String?
    /// Stroke width in pt (0...10). 0 = no stroke. Used regardless of strokeColor
    /// being set, but a non-zero width without color renders as default black.
    public var strokeWidth: Double

    /// Shadow color hex. nil = no shadow.
    public var shadowColor: String?
    /// Shadow horizontal offset in pt (-10...10).
    public var shadowOffsetX: Double
    /// Shadow vertical offset in pt (-10...10).
    public var shadowOffsetY: Double
    /// Shadow blur radius in pt (0...20).
    public var shadowRadius: Double

    /// Character spacing in pt (-5...20). 0 = system default.
    public var kerning: Double
    /// Extra space between lines in pt (0...30).
    public var lineSpacing: Double
    /// Italic emphasis. CJK fonts use matrix-shear fallback (v4 §4).
    public var isItalic: Bool
    /// v4: text alignment for both preview and export rendering. Default .center
    /// ensures zero visual diff for v1/v2/v3 legacy drafts.
    public var alignment: TextAlignment

    public init(
        fontSize: Double = 34,
        fontWeight: FontWeight = .regular,
        color: String = "#FFFFFF",
        backgroundColor: String? = nil,
        backgroundRadius: Double = 0,
        paddingH: Double = 0,
        paddingV: Double = 0,
        fontName: String? = nil,
        strokeColor: String? = nil,
        strokeWidth: Double = 0,
        shadowColor: String? = nil,
        shadowOffsetX: Double = 0,
        shadowOffsetY: Double = 0,
        shadowRadius: Double = 0,
        kerning: Double = 0,
        lineSpacing: Double = 0,
        isItalic: Bool = false,
        alignment: TextAlignment = .center
    ) {
        self.fontSize         = fontSize
        self.fontWeight       = fontWeight
        self.color            = color
        self.backgroundColor  = backgroundColor
        self.backgroundRadius = backgroundRadius
        self.paddingH         = paddingH
        self.paddingV         = paddingV
        self.fontName         = fontName
        self.strokeColor      = strokeColor
        self.strokeWidth      = strokeWidth
        self.shadowColor      = shadowColor
        self.shadowOffsetX    = shadowOffsetX
        self.shadowOffsetY    = shadowOffsetY
        self.shadowRadius     = shadowRadius
        self.kerning          = kerning
        self.lineSpacing      = lineSpacing
        self.isItalic         = isItalic
        self.alignment        = alignment
    }

    public static let `default` = TextStyle()

    // MARK: - Codable (custom for backward compatibility)
    //
    // Auto-synthesized decoder requires every stored property to be present in
    // the JSON. Drafts created before v3 P4 lack the new style fields, so we
    // hand-roll `init(from:)` using `decodeIfPresent` with the same default
    // values as `init`. Encoder is auto-synthesized (always writes all fields).

    private enum CodingKeys: String, CodingKey {
        case fontSize, fontWeight, color, backgroundColor, backgroundRadius
        case paddingH, paddingV, fontName
        case strokeColor, strokeWidth
        case shadowColor, shadowOffsetX, shadowOffsetY, shadowRadius
        case kerning, lineSpacing, isItalic
        case alignment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fontSize         = try c.decodeIfPresent(Double.self,     forKey: .fontSize)         ?? 34
        self.fontWeight       = try c.decodeIfPresent(FontWeight.self, forKey: .fontWeight)       ?? .regular
        self.color            = try c.decodeIfPresent(String.self,     forKey: .color)            ?? "#FFFFFF"
        self.backgroundColor  = try c.decodeIfPresent(String.self,     forKey: .backgroundColor)
        self.backgroundRadius = try c.decodeIfPresent(Double.self,     forKey: .backgroundRadius) ?? 0
        self.paddingH         = try c.decodeIfPresent(Double.self,     forKey: .paddingH)         ?? 0
        self.paddingV         = try c.decodeIfPresent(Double.self,     forKey: .paddingV)         ?? 0
        self.fontName         = try c.decodeIfPresent(String.self,     forKey: .fontName)
        self.strokeColor      = try c.decodeIfPresent(String.self,     forKey: .strokeColor)
        self.strokeWidth      = try c.decodeIfPresent(Double.self,     forKey: .strokeWidth)      ?? 0
        self.shadowColor      = try c.decodeIfPresent(String.self,     forKey: .shadowColor)
        self.shadowOffsetX    = try c.decodeIfPresent(Double.self,     forKey: .shadowOffsetX)    ?? 0
        self.shadowOffsetY    = try c.decodeIfPresent(Double.self,     forKey: .shadowOffsetY)    ?? 0
        self.shadowRadius     = try c.decodeIfPresent(Double.self,     forKey: .shadowRadius)     ?? 0
        self.kerning          = try c.decodeIfPresent(Double.self,        forKey: .kerning)          ?? 0
        self.lineSpacing      = try c.decodeIfPresent(Double.self,        forKey: .lineSpacing)      ?? 0
        self.isItalic         = try c.decodeIfPresent(Bool.self,          forKey: .isItalic)         ?? false
        self.alignment        = try c.decodeIfPresent(TextAlignment.self, forKey: .alignment)        ?? .center
    }
}

public enum FontWeight: String, Sendable, Hashable, Codable, CaseIterable {
    case thin, light, regular, medium, semibold, bold, heavy, black
}

public struct TextAnimation: Sendable, Hashable, Codable {
    public var type: AnimationType
    public var duration: Double

    public init(type: AnimationType, duration: Double) {
        self.type     = type
        self.duration = duration
    }

    public enum AnimationType: String, Sendable, Hashable, Codable, CaseIterable {
        case none
        case fadeIn    = "fade_in"
        case fadeOut   = "fade_out"
        case slideUp   = "slide_up"
        case slideDown = "slide_down"
        case slideLeft = "slide_left"
        case slideRight = "slide_right"
        case scale
        case typewriter
    }
}

public struct SubtitleStyle: Sendable, Hashable, Codable {
    public var fontSize: Double?
    public var fontWeight: FontWeight?
    public var color: String?
    public var backgroundColor: String?
    public var positionY: Double?
    public var maxCharsPerLine: Int?

    public init(
        fontSize: Double? = nil,
        fontWeight: FontWeight? = nil,
        color: String? = nil,
        backgroundColor: String? = nil,
        positionY: Double? = nil,
        maxCharsPerLine: Int? = nil
    ) {
        self.fontSize         = fontSize
        self.fontWeight       = fontWeight
        self.color            = color
        self.backgroundColor  = backgroundColor
        self.positionY        = positionY
        self.maxCharsPerLine  = maxCharsPerLine
    }
}
