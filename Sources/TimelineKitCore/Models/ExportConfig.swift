import Foundation
import CoreGraphics

/// V5 导出参数配置。挂在 `EditorMetadata.exportConfig`；为 nil 时按
/// `EditorTimeline.canvas` 派生默认（见 `default(for:)`）。
///
/// 读取统一走 `EditorTimeline.effectiveExportConfig`（不要直接读 `metadata.exportConfig`，
/// 它在新工程/旧草稿上为 nil）。
public struct ExportConfig: Codable, Sendable, Hashable {

    // MARK: - Resolution

    public enum Resolution: String, Codable, Sendable, CaseIterable, Hashable {
        case p480, p720, p1080, k2, k4

        public var label: String {
            switch self {
            case .p480:  "480P"
            case .p720:  "720P"
            case .p1080: "1080P"
            case .k2:    "2K"
            case .k4:    "4K"
            }
        }

        /// 16:9 像素尺寸（视频导出主流比例）。CompositionBuilder 接收时按
        /// canvas 宽高比缩放——这里给出"短边目标"参考尺寸即可。
        public var size: CGSize {
            switch self {
            case .p480:  CGSize(width:  854, height:  480)
            case .p720:  CGSize(width: 1280, height:  720)
            case .p1080: CGSize(width: 1920, height: 1080)
            case .k2:    CGSize(width: 2560, height: 1440)
            case .k4:    CGSize(width: 3840, height: 2160)
            }
        }

        /// 短边像素数（用于派生匹配 + 编码参数选择）
        public var shortSide: Int {
            switch self {
            case .p480:  480
            case .p720:  720
            case .p1080: 1080
            case .k2:    1440
            case .k4:    2160
            }
        }

        /// 按画布短边匹配最接近档位（平局取更高分辨率，优先保画质）
        public static func matching(canvasShortSide shortSide: Int) -> Self {
            allCases.min { a, b in
                let da = abs(a.shortSide - shortSide)
                let db = abs(b.shortSide - shortSide)
                if da != db { return da < db }
                return a.shortSide > b.shortSide   // 平局优先取更高
            }!
        }
    }

    // MARK: - FrameRate

    public enum FrameRate: Int, Codable, Sendable, CaseIterable, Hashable {
        case fps24 = 24
        case fps25 = 25
        case fps30 = 30
        case fps50 = 50
        case fps60 = 60
        case fps120 = 120

        public var label: String { "\(rawValue)" }
        public var value: Double { Double(rawValue) }

        /// 按 canvas.fps 匹配最接近档位（平局取更高帧率）
        public static func matching(canvasFPS fps: Int) -> Self {
            allCases.min { a, b in
                let da = abs(a.rawValue - fps)
                let db = abs(b.rawValue - fps)
                if da != db { return da < db }
                return a.rawValue > b.rawValue
            }!
        }
    }

    // MARK: - BitrateTier

    public enum BitrateTier: String, Codable, Sendable, CaseIterable, Hashable {
        case low, recommended, high

        public var label: String {
            switch self {
            case .low:         "较低"
            case .recommended: "推荐"
            case .high:        "较高"
            }
        }
    }

    // MARK: - Fields

    public var resolution:  Resolution
    public var fps:         FrameRate
    public var bitrateTier: BitrateTier
    public var hdrEnabled:  Bool

    public init(
        resolution:  Resolution  = .p1080,
        fps:         FrameRate   = .fps30,
        bitrateTier: BitrateTier = .recommended,
        hdrEnabled:  Bool        = true
    ) {
        self.resolution  = resolution
        self.fps         = fps
        self.bitrateTier = bitrateTier
        self.hdrEnabled  = hdrEnabled
    }

    // MARK: - Defaults

    /// 按画布派生默认配置（V5 推荐方式）：
    /// 分辨率按 canvas 短边匹配最接近档位；帧率按 canvas.fps 匹配最接近档位；
    /// 码率取「推荐」；HDR 默认开。
    public static func `default`(for canvas: EditorCanvas) -> ExportConfig {
        ExportConfig(
            resolution:  Resolution.matching(canvasShortSide: min(canvas.width, canvas.height)),
            fps:         FrameRate.matching(canvasFPS: canvas.fps),
            bitrateTier: .recommended,
            hdrEnabled:  true
        )
    }

    /// 无 canvas 上下文时的兜底常量（仅用于单元测试 / 异常 fallback；
    /// 主流程一律走 `EditorTimeline.effectiveExportConfig` → `default(for: canvas)`）。
    public static let factoryDefault = ExportConfig(
        resolution:  .p1080,
        fps:         .fps30,
        bitrateTier: .recommended,
        hdrEnabled:  true
    )
}
