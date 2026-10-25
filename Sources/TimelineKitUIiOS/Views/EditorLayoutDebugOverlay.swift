#if DEBUG && canImport(UIKit)
import SwiftUI
import TimelineKitUISharedViews

/// Debug-only layout readout for the Duo/iPad adaptive workspace.
///
/// Enable it with the launch argument `-TimelineKitLayoutDebug`. It never
/// intercepts touches and does not affect the editor's layout.
struct EditorLayoutDebugOverlay: View {
    static let launchArgument = "-TimelineKitLayoutDebug"

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(Self.launchArgument) {
            GeometryReader { proxy in
                let input = makeInput(proxy)
                let decision = EditorLayoutPolicy.decide(input)

                VStack(alignment: .leading, spacing: 2) {
                    Text("layout: \(decision.form.rawValue)")
                        .fontWeight(.semibold)
                    Text("container: \(sizeText(input.containerSize))")
                    Text("content: \(sizeText(decision.contentSize))")
                    Text("preview: \(sizeText(decision.previewSize))")
                    Text("timeline: \(sizeText(decision.timelineSize)) · \(decision.timelineDensity.rawValue)")
                    Text("class: \(input.horizontalSizeClass.rawValue)/\(input.verticalSizeClass.rawValue)")
                    Text("fold: \(decision.foldAxis.rawValue) · \(rectText(decision.activeFoldFrame))")
                    Text("occlusion: \(decision.activeOcclusionFrames.count) active")
                    Text("panels: aux \(decision.showsAuxiliaryPanel ? "on" : "off") · inspector \(decision.showsInspector ? "on" : "off")")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.8), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            }
            .allowsHitTesting(false)
        }
    }

    private func makeInput(_ proxy: GeometryProxy) -> EditorLayoutInput {
        if #available(iOS 27.1, *) {
            return EditorLayoutAdapter.input(
                size: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                divisionRegions: proxy.reservedRegions(
                    kind: .division,
                    options: .includeInactive
                ),
                occlusionRegions: proxy.reservedRegions(
                    kind: .occlusion,
                    options: .includeInactive
                )
            )
        }

        return EditorLayoutInput(
            horizontalSizeClass: horizontalSizeClass == .regular ? .regular : .compact,
            verticalSizeClass: verticalSizeClass == .regular ? .regular : .compact,
            containerSize: proxy.size,
            safeAreaInsets: EditorLayoutInsets(
                top: proxy.safeAreaInsets.top,
                leading: proxy.safeAreaInsets.leading,
                bottom: proxy.safeAreaInsets.bottom,
                trailing: proxy.safeAreaInsets.trailing
            )
        )
    }

    private func sizeText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    private func rectText(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(sizeText(rect.size))"
    }
}
#endif
