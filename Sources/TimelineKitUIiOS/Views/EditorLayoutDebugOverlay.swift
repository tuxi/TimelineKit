#if DEBUG && canImport(UIKit)
import SwiftUI
import TimelineKitUISharedViews

/// Debug-only layout readout for the Duo/iPad adaptive workspace.
///
/// Enable it with the launch argument `-TimelineKitLayoutDebug`. It never
/// intercepts touches and does not affect the editor's layout.
struct EditorLayoutDebugOverlay: View {
    static let launchArgument = "-TimelineKitLayoutDebug"

    private let fixedChromeHeight: CGFloat
    private let minTimelineHeight: CGFloat

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.editorLayoutMode) private var layoutMode

    init(fixedChromeHeight: CGFloat = 120, minTimelineHeight: CGFloat = 140) {
        self.fixedChromeHeight = fixedChromeHeight
        self.minTimelineHeight = minTimelineHeight
    }

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(Self.launchArgument) {
            GeometryReader { proxy in
                let input = makeInput(proxy)
                let decision = EditorLayoutPolicy.decide(input)

                VStack(alignment: .leading, spacing: 2) {
                    Text("layout: \(decision.form.rawValue)")
                        .fontWeight(.semibold)
                    Text("mode: \(layoutMode.rawValue)")
                    Text("container: \(sizeText(input.containerSize))")
                    Text("safe: \(insetsText(proxy.safeAreaInsets))")
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
        var metrics = EditorLayoutMetrics()
        metrics.minTimelineHeight = minTimelineHeight

        // Match the editor's input: the proxy is already inside the navigation
        // content, so safe-area insets must not be applied twice.
        if #available(iOS 27.1, *) {
            return EditorLayoutAdapter.input(
                size: proxy.size,
                safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                divisionRegions: proxy.reservedRegions(
                    kind: .division,
                    options: .includeInactive
                ),
                occlusionRegions: proxy.reservedRegions(
                    kind: .occlusion,
                    options: .includeInactive
                ),
                fixedChromeHeight: fixedChromeHeight,
                metrics: metrics
            )
        }

        return EditorLayoutInput(
            horizontalSizeClass: horizontalSizeClass == .regular ? .regular : .compact,
            verticalSizeClass: verticalSizeClass == .regular ? .regular : .compact,
            containerSize: proxy.size,
            safeAreaInsets: .zero,
            fixedChromeHeight: fixedChromeHeight,
            metrics: metrics
        )
    }

    private func insetsText(_ insets: EdgeInsets) -> String {
        "t\(Int(insets.top.rounded())) l\(Int(insets.leading.rounded())) b\(Int(insets.bottom.rounded())) r\(Int(insets.trailing.rounded()))"
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
