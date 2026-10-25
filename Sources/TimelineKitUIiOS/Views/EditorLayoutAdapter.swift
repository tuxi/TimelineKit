#if canImport(UIKit)
import SwiftUI
import TimelineKitUISharedViews

/// Maps platform layout values into the pure `EditorLayoutPolicy` input.
@available(iOS 27.1, *)
public enum EditorLayoutAdapter {

    public static func sizeClass(_ sizeClass: UserInterfaceSizeClass?) -> EditorSizeClass {
        sizeClass == .regular ? .regular : .compact
    }

    public static func input(
        size: CGSize,
        safeAreaInsets: EdgeInsets,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        divisionRegions: [ReservedRegion],
        occlusionRegions: [ReservedRegion],
        keyboardHeight: CGFloat = 0,
        fixedChromeHeight: CGFloat = 120,
        metrics: EditorLayoutMetrics = EditorLayoutMetrics()
    ) -> EditorLayoutInput {
        EditorLayoutInput(
            horizontalSizeClass: self.sizeClass(horizontalSizeClass),
            verticalSizeClass: self.sizeClass(verticalSizeClass),
            containerSize: size,
            safeAreaInsets: EditorLayoutInsets(
                top: safeAreaInsets.top,
                leading: safeAreaInsets.leading,
                bottom: safeAreaInsets.bottom,
                trailing: safeAreaInsets.trailing
            ),
            keyboardHeight: keyboardHeight,
            fixedChromeHeight: fixedChromeHeight,
            reservedRegions: regions(division: divisionRegions, occlusion: occlusionRegions),
            metrics: metrics
        )
    }

    public static func regions(
        division: [ReservedRegion],
        occlusion: [ReservedRegion]
    ) -> [EditorReservedRegion] {
        division.map {
            EditorReservedRegion(
                kind: .division,
                frame: $0.frame,
                isActive: $0.isActive
            )
        } + occlusion.map {
            EditorReservedRegion(
                kind: .occlusion,
                frame: $0.frame,
                isActive: $0.isActive
            )
        }
    }
}
#endif
