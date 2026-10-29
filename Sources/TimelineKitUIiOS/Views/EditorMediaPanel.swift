#if canImport(UIKit)
import SwiftUI
import AVFoundation
import UIKit

/// A library media item shown in the material browser.
struct EditorBrowserMediaItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case image
        case video
        case audio
    }

    let id: UUID
    let url: URL
    let title: String
    let kind: Kind
    let duration: Double?
}

/// A date-grouped browser section, mirroring the library media manifest.
struct EditorBrowserMediaGroup: Equatable {
    let date: Date
    let items: [EditorBrowserMediaItem]
}

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
    var mediaGroups: [EditorBrowserMediaGroup] = []
    var selectedMediaID: UUID?
    var onSelectMedia: (EditorBrowserMediaItem) -> Void = { _ in }
    var onInsertMedia: (EditorBrowserMediaItem) -> Void = { _ in }

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

            ScrollView(showsIndicators: false) {
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
            }
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
            Text("最近素材")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            if mediaGroups.isEmpty {
                Text("还没有最近素材")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(mediaGroups, id: \.date) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(groupTitle(group.date))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4))

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)
                                ],
                                spacing: 8
                            ) {
                                ForEach(group.items) { item in
                                    BrowserMediaCard(
                                        item: item,
                                        isSelected: selectedMediaID == item.id,
                                        onSelect: { onSelectMedia(item) },
                                        onInsert: { onInsertMedia(item) }
                                    )
                                }
                            }
                        }
                    }
                }
            }

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

    private func groupTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        }
        return Self.groupFormatter.string(from: date)
    }

    private static let groupFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

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

private struct BrowserMediaCard: View {
    let item: EditorBrowserMediaItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onInsert: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 4) {
                    BrowserMediaThumbnail(item: item)

                    Text(item.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)

                    if let duration = item.duration {
                        Text(timeString(duration))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isSelected
                            ? Color.white.opacity(0.16)
                            : Color.white.opacity(0.05)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected ? Color.yellow : Color.clear,
                            lineWidth: 1.5
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onInsert) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .background(
                        Circle().fill(Color.black.opacity(0.55))
                    )
            }
            .buttonStyle(.plain)
            .padding(3)
            .accessibilityLabel("添加 \(item.title) 到时间线")
        }
        .draggable(item.url) {
            Label(item.title, systemImage: "photo")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(8)
                .background(
                    Color.black.opacity(0.8),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct BrowserMediaThumbnail: View {
    let item: EditorBrowserMediaItem

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item.id) {
            await loadThumbnail()
        }
    }

    private var icon: String {
        switch item.kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }

    private func loadThumbnail() async {
        image = nil

        switch item.kind {
        case .image:
            image = UIImage(contentsOfFile: item.url.path)

        case .video:
            let asset = AVURLAsset(url: item.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if let result = try? await generator.image(
                at: CMTime(seconds: 0.1, preferredTimescale: 600)
            ) {
                image = UIImage(cgImage: result.image)
            }

        case .audio:
            break
        }
    }
}
#endif
