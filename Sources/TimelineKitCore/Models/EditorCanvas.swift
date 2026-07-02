import Foundation

public struct EditorCanvas: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(width: Int, height: Int, fps: Int = 30) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    public var aspectRatio: Double { Double(width) / Double(height) }

    public enum Preset: String, Sendable, CaseIterable {
        case portrait_9_16 = "9:16"
        case landscape_16_9 = "16:9"
        case square_1_1 = "1:1"
        case portrait_3_4 = "3:4"

        public var canvas: EditorCanvas {
            switch self {
            case .portrait_9_16:  return EditorCanvas(width: 720,  height: 1280)
            case .landscape_16_9: return EditorCanvas(width: 1280, height: 720)
            case .square_1_1:     return EditorCanvas(width: 720,  height: 720)
            case .portrait_3_4:   return EditorCanvas(width: 720,  height: 960)
            }
        }

        public static func detect(width: Int, height: Int) -> Preset? {
            allCases.first { $0.canvas.width == width && $0.canvas.height == height }
        }
    }
}
