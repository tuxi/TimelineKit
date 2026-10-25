#if DEBUG && canImport(UIKit)
import Foundation
import CoreGraphics
import TimelineKitUISharedViews

/// Injects synthetic reserved regions for simulator checks when Device Hub
/// folding is not available.
///
/// Launch arguments:
/// - `-TimelineKitDebugFoldVertical`
/// - `-TimelineKitDebugFoldHorizontal`
/// - `-TimelineKitDebugOcclusion`
enum EditorLayoutDebugRegions {
    static func synthetic(for size: CGSize) -> [EditorReservedRegion] {
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("-TimelineKitDebugFoldVertical") {
            let width = min(44, size.width * 0.08)
            return [
                EditorReservedRegion(
                    kind: .division,
                    frame: CGRect(
                        x: (size.width - width) / 2,
                        y: 0,
                        width: width,
                        height: size.height
                    ),
                    isActive: true
                )
            ]
        }

        if arguments.contains("-TimelineKitDebugFoldHorizontal") {
            let height = min(44, size.height * 0.08)
            return [
                EditorReservedRegion(
                    kind: .division,
                    frame: CGRect(
                        x: 0,
                        y: (size.height - height) / 2,
                        width: size.width,
                        height: height
                    ),
                    isActive: true
                )
            ]
        }

        if arguments.contains("-TimelineKitDebugOcclusion") {
            let side = min(88, min(size.width, size.height) * 0.12)
            return [
                EditorReservedRegion(
                    kind: .occlusion,
                    frame: CGRect(
                        x: size.width - side,
                        y: 0,
                        width: side,
                        height: side
                    ),
                    isActive: true
                )
            ]
        }

        return []
    }
}
#endif
