import Foundation

// MARK: - SegmentAdjustment

/// Per-segment color and tone adjustment parameters.
///
/// All values default to "no effect" (identity). The compositor skips the CIFilter
/// chain entirely when `isIdentity` returns true, preserving v1 performance.
public struct SegmentAdjustment: Sendable, Hashable, Codable {

    // MARK: - Tone

    /// CIColorControls.inputBrightness   — range: -1.0 … +1.0, default: 0
    public var brightness:  Double
    /// CIColorControls.inputContrast     — range: 0.5 … 1.5,  default: 1.0
    public var contrast:    Double
    /// CIColorControls.inputSaturation   — range: 0.0 … 2.0,  default: 1.0
    public var saturation:  Double

    // MARK: - Color Temperature

    /// CITemperatureAndTint (Kelvin)     — range: 2000 … 9000, default: 6500
    public var temperature: Double
    /// CITemperatureAndTint green/magenta — range: -150 … +150, default: 0
    public var tint:        Double

    // MARK: - Highlight / Shadow

    /// CIHighlightShadowAdjust highlight — range: -1.0 … +1.0, default: 0
    public var highlights:  Double
    /// CIHighlightShadowAdjust shadow    — range: -1.0 … +1.0, default: 0
    public var shadows:     Double

    // MARK: - Preset Filter

    /// System CIPhotoEffect filter name, or nil for no preset.
    public var filterName:      PresetFilter?
    /// Mix intensity with original frame  — range: 0.0 … 1.0, default: 1.0
    public var filterIntensity: Double

    // MARK: - Init

    public init(
        brightness:      Double = 0,
        contrast:        Double = 1.0,
        saturation:      Double = 1.0,
        temperature:     Double = 6500,
        tint:            Double = 0,
        highlights:      Double = 0,
        shadows:         Double = 0,
        filterName:      PresetFilter? = nil,
        filterIntensity: Double = 1.0
    ) {
        self.brightness      = brightness
        self.contrast        = contrast
        self.saturation      = saturation
        self.temperature     = temperature
        self.tint            = tint
        self.highlights      = highlights
        self.shadows         = shadows
        self.filterName      = filterName
        self.filterIntensity = filterIntensity
    }

    /// All parameters at their default (no-op) values.
    public static let identity = SegmentAdjustment()

    /// True when every parameter is at its identity value → compositor short-circuits.
    public var isIdentity: Bool {
        brightness  == 0    &&
        contrast    == 1.0  &&
        saturation  == 1.0  &&
        temperature == 6500 &&
        tint        == 0    &&
        highlights  == 0    &&
        shadows     == 0    &&
        filterName  == nil
    }
}

// MARK: - PresetFilter

/// Built-in CIPhotoEffect presets surfaced in the adjustment panel.
/// Raw value = stable case name (used for serialization).
/// Use `ciFilterName` to get the Core Image filter identifier.
public enum PresetFilter: String, Sendable, Hashable, Codable, CaseIterable {

    // Natural
    case naturalVivid
    case naturalWarm
    case naturalCool
    case naturalSoft

    // Cinematic
    case cinemaChrome
    case cinemaNoir
    case cinemaInstant
    case cinemaMono

    // Retro (some share a CIFilter name with Natural — intentional, different UI category)
    case retroTransfer
    case retroFade
    case retroProcess
    case retroSepia

    // MARK: - Core Image filter name

    public var ciFilterName: String {
        switch self {
        case .naturalVivid:   return "CIVibrance"
        case .naturalWarm:    return "CIPhotoEffectProcess"
        case .naturalCool:    return "CIPhotoEffectFade"
        case .naturalSoft:    return "CIPhotoEffectTonal"
        case .cinemaChrome:   return "CIPhotoEffectChrome"
        case .cinemaNoir:     return "CIPhotoEffectNoir"
        case .cinemaInstant:  return "CIPhotoEffectInstant"
        case .cinemaMono:     return "CIPhotoEffectMono"
        case .retroTransfer:  return "CIPhotoEffectTransfer"
        case .retroFade:      return "CIPhotoEffectFade"
        case .retroProcess:   return "CIPhotoEffectProcess"
        case .retroSepia:     return "CISepiaTone"
        }
    }

    // MARK: - UI metadata

    public var displayName: String {
        switch self {
        case .naturalVivid:   return "鲜艳"
        case .naturalWarm:    return "暖调"
        case .naturalCool:    return "冷调"
        case .naturalSoft:    return "柔和"
        case .cinemaChrome:   return "铬黄"
        case .cinemaNoir:     return "黑白"
        case .cinemaInstant:  return "拍立得"
        case .cinemaMono:     return "单色"
        case .retroTransfer:  return "转印"
        case .retroFade:      return "褪色"
        case .retroProcess:   return "冲印"
        case .retroSepia:     return "棕褐"
        }
    }

    public var category: Category {
        switch self {
        case .naturalVivid, .naturalWarm, .naturalCool, .naturalSoft: return .natural
        case .cinemaChrome, .cinemaNoir, .cinemaInstant, .cinemaMono: return .cinematic
        case .retroTransfer, .retroFade, .retroProcess, .retroSepia:  return .retro
        }
    }

    public enum Category: String, CaseIterable {
        case natural   = "自然"
        case cinematic = "电影"
        case retro     = "复古"
    }
}
