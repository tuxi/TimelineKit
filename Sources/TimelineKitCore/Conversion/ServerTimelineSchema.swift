import Foundation

/// Codable mirror of the server-side VideoTimeline JSON format.
/// This type lives in TimelineKit so the package is self-contained and does not
/// depend on FeatureVideoGen. FeatureVideoGen can pass raw JSON Data directly.
///
/// Only the fields needed for import/export are modelled here.
/// Unknown fields are silently ignored by the decoder.
public struct ServerTimelineSchema: Codable, Sendable {
    public var version: String
    public var duration: Double
    public var fps: Int
    public var canvas: SCanvas
    public var scenes: [SScene]
    public var audio: SAudioTrack?
    public var subtitle: SSubtitleTrack?
    public var meta: SMeta?

    enum CodingKeys: String, CodingKey {
        case version, duration, fps, canvas, scenes, audio, subtitle, meta
    }
}

// MARK: - Canvas

public struct SCanvas: Codable, Sendable {
    public var width: Int
    public var height: Int
}

// MARK: - Scene

public struct SScene: Codable, Sendable {
    public var id: String
    public var shotIndex: Int
    public var start: Double
    public var duration: Double
    public var layers: [SLayer]
    public var transition: STransition?
    public var voice: SVoice?

    enum CodingKeys: String, CodingKey {
        case id, start, duration, layers, transition, voice
        case shotIndex = "shot_index"
    }
}

public struct STransition: Codable, Sendable {
    public var type: String
    public var duration: Double
    public var easing: String
    /// Optional directional hint — "left" / "right" / "up" / "down".
    /// Used by slide/push/wipe semantics to pick the correct preset.
    public var direction: String?
    /// Optional style qualifier (e.g. "cinematic", "soft") — reserved for future mapping.
    public var style: String?
    /// Optional intensity 0.0–1.0 — forwarded to EditorTransition.intensity.
    public var intensity: Double?
    /// V7 client preset identifier (e.g. "slideLeft", "blurFade").
    /// When present on reimport, this is used directly, bypassing the semantic layer.
    /// Written by TimelineExporter for all editor-created transitions.
    public var presetID: String?

    enum CodingKeys: String, CodingKey {
        case type, duration, easing, direction, style, intensity
        case presetID = "preset_id"
    }

    public init(
        type:      String,
        duration:  Double,
        easing:    String,
        direction: String? = nil,
        style:     String? = nil,
        intensity: Double? = nil,
        presetID:  String? = nil
    ) {
        self.type      = type
        self.duration  = duration
        self.easing    = easing
        self.direction = direction
        self.style     = style
        self.intensity = intensity
        self.presetID  = presetID
    }
}

// MARK: - Layers (polymorphic via type field)

/// Raw decoded layer — all possible fields are optional.
/// The `type` field drives which fields are meaningful.
/// Both image animations and text animations share the JSON key "animation",
/// so we decode into the appropriate Swift property based on `type`.
public struct SLayer: Codable, Sendable {
    public var type: String
    public var zIndex: Int?
    public var fit: String?

    // image_motion / image_3d
    public var src: String?
    public var blur: Double?
    public var imageAnimation: SImageAnimation?  // decoded when type != "text"

    // image_3d
    public var depthModel: SDepthModel?
    public var camera: SCamera?

    // ai_video
    public var videoURL: String?
    public var provider: String?
    public var model: String?

    // text
    public var content: String?
    public var startOffset: Double?
    public var endOffset: Double?
    public var position: STextPosition?
    public var style: STextStyle?
    public var textAnimation: STextAnimation?    // decoded when type == "text"

    /// V7: clip-level entrance/exit/combo animations from the server.
    /// Separate JSON key ("clip_animations") avoids collision with the
    /// existing "animation" key used for Ken Burns / text animation.
    public var clipAnimations: [SAnimation]?

    enum CodingKeys: String, CodingKey {
        case type, fit, src, blur, animation, camera, content, position, style
        case zIndex         = "z_index"
        case depthModel     = "depth_model"
        case videoURL       = "video_url"
        case provider, model
        case startOffset    = "start_offset"
        case endOffset      = "end_offset"
        case clipAnimations = "clip_animations"
        // `animation` is the single JSON key for both image and text animations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type        = try c.decode(String.self, forKey: .type)
        zIndex      = try c.decodeIfPresent(Int.self,         forKey: .zIndex)
        fit         = try c.decodeIfPresent(String.self,      forKey: .fit)
        src         = try c.decodeIfPresent(String.self,      forKey: .src)
        blur        = try c.decodeIfPresent(Double.self,      forKey: .blur)
        depthModel  = try c.decodeIfPresent(SDepthModel.self, forKey: .depthModel)
        camera      = try c.decodeIfPresent(SCamera.self,     forKey: .camera)
        videoURL    = try c.decodeIfPresent(String.self,      forKey: .videoURL)
        provider    = try c.decodeIfPresent(String.self,      forKey: .provider)
        model       = try c.decodeIfPresent(String.self,      forKey: .model)
        content     = try c.decodeIfPresent(String.self,      forKey: .content)
        startOffset = try c.decodeIfPresent(Double.self,      forKey: .startOffset)
        endOffset   = try c.decodeIfPresent(Double.self,      forKey: .endOffset)
        position    = try c.decodeIfPresent(STextPosition.self, forKey: .position)
        style       = try c.decodeIfPresent(STextStyle.self,    forKey: .style)

        if type == "text" {
            imageAnimation = nil
            textAnimation  = try c.decodeIfPresent(STextAnimation.self,  forKey: .animation)
        } else {
            imageAnimation = try c.decodeIfPresent(SImageAnimation.self, forKey: .animation)
            textAnimation  = nil
        }
        clipAnimations = try c.decodeIfPresent([SAnimation].self, forKey: .clipAnimations)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(zIndex,      forKey: .zIndex)
        try c.encodeIfPresent(fit,         forKey: .fit)
        try c.encodeIfPresent(src,         forKey: .src)
        try c.encodeIfPresent(blur,        forKey: .blur)
        try c.encodeIfPresent(depthModel,  forKey: .depthModel)
        try c.encodeIfPresent(camera,      forKey: .camera)
        try c.encodeIfPresent(videoURL,    forKey: .videoURL)
        try c.encodeIfPresent(provider,    forKey: .provider)
        try c.encodeIfPresent(model,       forKey: .model)
        try c.encodeIfPresent(content,     forKey: .content)
        try c.encodeIfPresent(startOffset, forKey: .startOffset)
        try c.encodeIfPresent(endOffset,   forKey: .endOffset)
        try c.encodeIfPresent(position,    forKey: .position)
        try c.encodeIfPresent(style,       forKey: .style)
        if let a = imageAnimation { try c.encode(a, forKey: .animation) }
        if let a = textAnimation  { try c.encode(a, forKey: .animation) }
        try c.encodeIfPresent(clipAnimations, forKey: .clipAnimations)
    }
}

public struct SImageAnimation: Codable, Sendable {
    public var type: String?
    public var duration: Double?
    public var easing: String?
    public var scaleFrom: Double?
    public var scaleTo: Double?
    public var translateXFrom: Double?
    public var opacityTo: Double?

    enum CodingKeys: String, CodingKey {
        case type, duration, easing
        case scaleFrom     = "scale_from"
        case scaleTo       = "scale_to"
        case translateXFrom = "translate_x_from"
        case opacityTo     = "opacity_to"
    }
    
   public init(type: String? = nil, duration: Double? = nil, easing: String? = nil, scaleFrom: Double? = nil, scaleTo: Double? = nil, translateXFrom: Double? = nil, opacityTo: Double? = nil) {
        self.type = type
        self.duration = duration
        self.easing = easing
        self.scaleFrom = scaleFrom
        self.scaleTo = scaleTo
        self.translateXFrom = translateXFrom
        self.opacityTo = opacityTo
    }
    
   public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        self.easing = try container.decodeIfPresent(String.self, forKey: .easing)
        self.scaleFrom = try container.decodeIfPresent(Double.self, forKey: .scaleFrom)
        self.scaleTo = try container.decodeIfPresent(Double.self, forKey: .scaleTo)
        self.translateXFrom = try container.decodeIfPresent(Double.self, forKey: .translateXFrom)
        self.opacityTo = try container.decodeIfPresent(Double.self, forKey: .opacityTo)
    }
}

public struct SDepthModel: Codable, Sendable {
    public var type: String?
    public var centerX: Double?
    public var centerY: Double?
    public var innerRadius: Double?
    public var outerRadius: Double?
    public var nearValue: Double?
    public var farValue: Double?
    public var falloff: String?

    enum CodingKeys: String, CodingKey {
        case type, falloff
        case centerX      = "center_x"
        case centerY      = "center_y"
        case innerRadius  = "inner_radius"
        case outerRadius  = "outer_radius"
        case nearValue    = "near_value"
        case farValue     = "far_value"
    }
}

public struct SCamera: Codable, Sendable {
    public var move: String
    public var intensity: Double
    public var duration: Double
    public var easing: String?
}

public struct STextPosition: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var anchor: String?
}

public struct STextStyle: Codable, Sendable {
    public var fontSize: Int?
    public var fontWeight: String?
    public var color: String?
    public var backgroundColor: String?
    public var backgroundRadius: Int?
    public var padding: [Int]?

    enum CodingKeys: String, CodingKey {
        case fontSize         = "font_size"
        case fontWeight       = "font_weight"
        case color
        case backgroundColor  = "background_color"
        case backgroundRadius = "background_radius"
        case padding
    }
}

public struct STextAnimation: Codable, Sendable {
    public var enter: String?
    public var exit: String?
    public var enterDuration: Double?
    public var exitDuration: Double?

    enum CodingKeys: String, CodingKey {
        case enter, exit
        case enterDuration = "enter_duration"
        case exitDuration  = "exit_duration"
    }
}

/// V7: server-side clip animation descriptor.
/// Decoded from the `"clip_animations"` array on each layer.
/// The server sends semantic intent only — never a client presetID.
public struct SAnimation: Codable, Sendable {
    public var type: String
    public var timing: String?
    public var duration: Double?
    public var direction: String?
    public var intensity: Float?
}

// MARK: - Audio

public struct SAudioTrack: Codable, Sendable {
    public var bgm: SBGM?
    public var voice: SVoice?
}

public struct SBGM: Codable, Sendable {
    public var url: String
    public var volume: Double
    public var loop: Bool
    public var fadeOutDuration: Double?

    enum CodingKeys: String, CodingKey {
        case url, volume, loop
        case fadeOutDuration = "fade_out_duration"
    }
}

public struct SVoice: Codable, Sendable {
    public var url: String
    public var volume: Double
    public var startOffset: Double?
    public var duration: Double?

    enum CodingKeys: String, CodingKey {
        case url, volume, duration
        case startOffset = "start_offset"
    }
}

// MARK: - Subtitle

public struct SSubtitleTrack: Codable, Sendable {
    public var version: Int?
    public var layoutMode: String?
    public var style: SSubtitleStyle?
    public var items: [SSubtitleItem]

    enum CodingKeys: String, CodingKey {
        case version, style, items
        case layoutMode = "layout_mode"
    }
}

public struct SSubtitleItem: Codable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var segments: [SSubtitleSegment]?
    public var style: SSubtitleStyle?
}

public struct SSubtitleSegment: Codable, Sendable {
    public var text: String
    public var highlight: Bool?
    public var style: SSubtitleSegmentStyle?
}

public struct SSubtitleSegmentStyle: Codable, Sendable {
    public var typography: STypography?
}

public struct STypography: Codable, Sendable {
    public var fontSize: Int?
    public var fontWeight: String?
    public var color: String?

    enum CodingKeys: String, CodingKey {
        case fontSize   = "font_size"
        case fontWeight = "font_weight"
        case color
    }
}

public struct SSubtitleStyle: Codable, Sendable {
    public var typography: STypography?
    public var background: SBackground?
    public var positionY: Double?
    public var maxCharsPerLine: Int?

    enum CodingKeys: String, CodingKey {
        case typography, background
        case positionY       = "position_y"
        case maxCharsPerLine = "max_chars_per_line"
    }
}

public struct SBackground: Codable, Sendable {
    public var color: String?
    public var radius: Int?
    public var paddingVertical: Int?
    public var paddingHorizontal: Int?

    enum CodingKeys: String, CodingKey {
        case color, radius
        case paddingVertical   = "padding_vertical"
        case paddingHorizontal = "padding_horizontal"
    }
}

// MARK: - Meta

public struct SMeta: Codable, Sendable {
    public var workflowName: String?
    public var mode: String?
    public var totalScenes: Int?
    public var renderType: String?
    public var productName: String?
    public var aspectRatio: String?
    public var resolution: String?

    enum CodingKeys: String, CodingKey {
        case mode, resolution
        case workflowName  = "workflow_name"
        case totalScenes   = "total_scenes"
        case renderType    = "render_type"
        case productName   = "product_name"
        case aspectRatio   = "aspect_ratio"
    }
}
