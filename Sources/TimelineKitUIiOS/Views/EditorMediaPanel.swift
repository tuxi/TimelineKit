#if canImport(UIKit)
import SwiftUI

/// Left-side material browser for regular layouts.
///
/// P2.1 provides the Media / Audio / Text groups and routes to the existing
/// import and creation actions. Asset thumbnails and canvas preview land in P2.2.
struct EditorMediaPanel: View {
    @Binding var isCollapsed: Bool
    var width: CGFloat = 220
    var onPhotos: () -> Void
    var onFiles: () -> Void
    var onAudioTools: () -> Void
    var onCreateText: () -> Void
    var onCreateSubtitle: () -> Void
    var onDropURLs: ([URL]) -> Void
    var onClose: (() -> Void)? = nil

    @State private var selectedTab: Tab = .media
    @State private var isTargeted = false

    private enum Tab: String, CaseIterable, Identifiable {
        case media = "媒体"
        case audio = "音频"
        case text = "文字"

        var id: String { rawValue }
    }

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
                    if let onClose {
                        onClose()
                    } else {
                        withAnimation(.spring(duration: 0.25)) {
                            isCollapsed = true
                        }
                    }
                } label: {
                    Image(systemName: onClose == nil ? "sidebar.left" : "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(onClose == nil ? "收起素材区" : "关闭素材")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider().background(Color.white.opacity(0.08))

            tabBar

            Divider().background(Color.white.opacity(0.08))

            Group {
                switch selectedTab {
                case .media:
                    mediaContent
                case .audio:
                    audioContent
                case .text:
                    textContent
                }
            }
            .padding(10)

            Spacer(minLength: 0)
        }
        .frame(width: width)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(
                            isSelected
                            ? Color.black
                            : Color.white.opacity(0.7)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    isSelected
                                    ? Color.white
                                    : Color.white.opacity(0.06)
                                )
                        )
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var mediaContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            entryButton(
                "照片与视频",
                icon: "photo.on.rectangle",
                action: onPhotos
            )
            entryButton("文件", icon: "folder", action: onFiles)

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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            entryButton(
                "音频工具",
                icon: "waveform",
                action: onAudioTools
            )

            Text("提取音频、本地音乐\n以及后续的录音和 TTS")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            entryButton(
                "新建文字",
                icon: "textformat",
                action: onCreateText
            )
            entryButton(
                "新建字幕",
                icon: "text.bubble",
                action: onCreateSubtitle
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entryButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
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
