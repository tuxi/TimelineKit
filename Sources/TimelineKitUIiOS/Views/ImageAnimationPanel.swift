#if canImport(UIKit)
import SwiftUI
import TimelineKitCore
import TimelineKitUIShared

// MARK: - ImageAnimationPanel

/// Bottom sheet for choosing a Ken Burns / depth animation template on an image segment.
/// Shown when the user taps "动画" in the clip edit panel for an image segment.
struct ImageAnimationPanel: View {

    let segmentID: UUID
    @Bindable var store: EditorStore
    var onDismiss: (() -> Void)? = nil

    @State private var tab: Tab = .motion

    private var appliedPresetID: String? {
        guard let seg = store.timeline.segment(id: segmentID),
              case .image(let c) = seg.content else { return nil }
        return c.animationPresetID
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(Color.white.opacity(0.1))
            presetRow
        }
        .background(Color(white: 0.13))
    }

    // MARK: - Tab bar

    private enum Tab: String, CaseIterable {
        case motion = "基础动画"
        case depth  = "景深动画"
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { tab = t }
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Color.white : Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            if tab == t {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
        }
        .frame(height: 40)
    }

    // MARK: - Preset row

    private var presetRow: some View {
        let presets = tab == .motion
            ? ImageAnimationPreset.motionPresets
            : ImageAnimationPreset.depthPresets

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(presets, id: \.self) { preset in
                    presetCell(preset)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(height: 90)
    }

    private func presetCell(_ preset: ImageAnimationPreset) -> some View {
        let isSelected = appliedPresetID == preset.rawValue
            || (preset == .none && appliedPresetID == nil)

        return Button {
            store.applyImageAnimation(segmentID: segmentID, preset: preset)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected
                              ? Color.yellow.opacity(0.25)
                              : Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.yellow : Color.clear, lineWidth: 1.5)
                        )
                        .frame(width: 44, height: 36)

                    Image(systemName: preset.sfSymbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.85))
                }

                Text(preset.displayName)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
    }
}
#endif
