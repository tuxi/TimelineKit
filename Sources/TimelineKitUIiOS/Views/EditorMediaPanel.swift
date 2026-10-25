#if canImport(UIKit)
import SwiftUI

/// Material entry panel for the wide workspace.
///
/// The full media browser is deferred; this panel provides the two import
/// entries and a file drop target while keeping the preview and inspector
/// visible.
struct EditorMediaPanel: View {
    @Binding var isCollapsed: Bool
    var width: CGFloat = 180
    var onPhotos: () -> Void
    var onFiles: () -> Void
    var onDropURLs: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        Group {
            if isCollapsed {
                collapsedRail
            } else {
                expanded
            }
        }
        .background(Color(white: 0.10))
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("素材")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))

                Spacer(minLength: 8)

                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        isCollapsed = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("收起素材区")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider().background(Color.white.opacity(0.08))

            VStack(spacing: 10) {
                Button(action: onPhotos) {
                    Label("照片与视频", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .hoverEffect(.highlight)

                Button(action: onFiles) {
                    Label("文件", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .hoverEffect(.highlight)

                Text("拖入视频或图片\n添加到时间线")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isTargeted ? Color.yellow : Color.white.opacity(0.15),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
            }
            .padding(10)

            Spacer(minLength: 0)
        }
        .frame(width: width)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.yellow, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            onDropURLs(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var collapsedRail: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    isCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("展开素材区")

            Text("素材")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(width: 14, height: 44)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: 44)
    }
}
#endif
