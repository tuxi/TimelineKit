#if canImport(UIKit)
import SwiftUI

// MARK: - TransitionEditSheet

/// Bottom sheet for picking and adjusting a transition at a cut-point.
/// V7: preset-based UI (tabs + grid + duration slider).
/// Applies changes immediately on selection; "完成" dismisses.
struct TransitionEditSheet: View {

    let context: TransitionEditContext
    @Bindable var store: EditorStore

    // "none" sentinel string means no transition (删除 or 不添加).
    private static let noneID = "none"

    @State private var selectedPresetID: String
    @State private var selectedTab: TransitionCategory
    @State private var duration: Double

    init(context: TransitionEditContext, store: EditorStore) {
        self.context = context
        self.store   = store

        TransitionPresetRegistry.ensureDefaultsRegistered()

        let tl = store.timeline
        let leading  = tl.segment(id: context.leadingID)
        let trailing = tl.segment(id: context.trailingID)
        let maxD = Swift.min(3.0, Swift.min(leading?.targetRange.duration  ?? 3,
                                            trailing?.targetRange.duration ?? 3))
        let existingDur = context.existingTransition?.duration ?? 0.5
        let clamped = Swift.max(0.2, Swift.min(existingDur, maxD))

        let existingPresetID = context.existingTransition.flatMap { t in
            t.presetID ?? TransitionPresetRegistry.preset(
                for: TransitionPresetRegistry.presetID(for: t.type)
            ).map { $0.presetID }
        } ?? Self.noneID

        _selectedPresetID = State(initialValue: existingPresetID)
        _duration         = State(initialValue: clamped)

        // Open on the tab that owns the current preset, or 基础 by default.
        let initialTab: TransitionCategory = {
            if existingPresetID == Self.noneID { return .basic }
            return TransitionPresetRegistry.preset(for: existingPresetID)?.category ?? .basic
        }()
        _selectedTab = State(initialValue: initialTab)
    }

    // MARK: - Computed

    private var visibleTabs: [TransitionCategory] {
        TransitionPresetRegistry.byCategory.map { $0.category }
    }

    private var presetsForTab: [(id: String, name: String, icon: String)] {
        var items: [(String, String, String)] = []
        // "无" pinned first in 基础 tab.
        if selectedTab == .basic {
            items.append((Self.noneID, "无", "xmark.circle"))
        }
        if let entry = TransitionPresetRegistry.byCategory.first(where: { $0.category == selectedTab }) {
            for id in entry.ids {
                if let p = TransitionPresetRegistry.preset(for: id) {
                    items.append((p.presetID, p.displayName, p.iconName))
                }
            }
        }
        return items
    }

    private var durationRange: ClosedRange<Double> {
        let tl = store.timeline
        let leading  = tl.segment(id: context.leadingID)
        let trailing = tl.segment(id: context.trailingID)
        let maxD = Swift.min(3.0, Swift.min(leading?.targetRange.duration  ?? 3,
                                            trailing?.targetRange.duration ?? 3))
        return 0.2...Swift.max(0.2, maxD)
    }

    private var hasTransition: Bool { selectedPresetID != Self.noneID }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            header

            if visibleTabs.count > 1 {
                tabBar
                    .padding(.top, 10)
            }

            presetGrid
                .padding(.top, 12)

            if hasTransition {
                durationSlider
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.18), value: hasTransition)
        .background(Color(white: 0.13))
    }

    // MARK: - Sub-views

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.3))
            .frame(width: 36, height: 4)
            .padding(.top, 8)
    }

    private var header: some View {
        HStack {
            Text(context.existingTransition == nil ? "添加转场" : "编辑转场")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button("完成") { dismiss() }
                .foregroundStyle(.white)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleTabs, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selectedTab == tab ? Color.black : Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedTab == tab ? Color.white : Color.white.opacity(0.12))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var presetGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(presetsForTab, id: \.id) { item in
                    PresetCell(
                        id:         item.id,
                        name:       item.name,
                        icon:       item.icon,
                        isSelected: selectedPresetID == item.id
                    ) {
                        applyPreset(item.id)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: 200)
    }

    private var durationSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("时长")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f s", duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            if durationRange.upperBound - durationRange.lowerBound > 0.01 {
                Slider(value: $duration, in: durationRange, step: 0.1)
                    .tint(.white)
                    .onChange(of: duration) { _, newVal in
                        guard let existing = context.existingTransition
                              ?? currentTransition() else { return }
                        store.updateTransitionDuration(id: existing.id, duration: newVal)
                    }
            } else {
                Text("0.2 s（最短）")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Actions

    private func applyPreset(_ presetID: String) {
        selectedPresetID = presetID
        if presetID == Self.noneID {
            // Remove existing transition.
            if let t = context.existingTransition ?? currentTransition() {
                store.removeTransition(id: t.id)
            }
        } else if let existing = context.existingTransition ?? currentTransition() {
            // Update existing.
            store.updateTransitionPreset(id: existing.id, presetID: presetID, duration: duration)
        } else {
            // Add new.
            store.addTransition(between: context.leadingID, and: context.trailingID,
                                presetID: presetID, duration: duration)
        }
    }

    /// Look up the transition that may have been created in this sheet session
    /// (not in context.existingTransition, which is a snapshot from when the sheet opened).
    private func currentTransition() -> EditorTransition? {
        store.timeline.transitions.first {
            $0.leadingSegmentID == context.leadingID &&
            $0.trailingSegmentID == context.trailingID
        }
    }

    private func dismiss() {
        store.selection.editingTransitionContext = nil
    }
}

// MARK: - PresetCell

private struct PresetCell: View {
    let id:         String
    let name:       String
    let icon:       String
    let isSelected: Bool
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? Color.blue : Color.white)
                        .frame(width: 64, height: 44)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                        )
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                        .background(Circle().fill(Color.white).padding(2))
                        .offset(x: 4, y: -4)
                }
            }
        }
    }
}

// MARK: - TransitionType UI metadata (for legacy v2 sheet compat)

extension EditorTransition.TransitionType {
    /// Phase-1 types surfaced in the picker.
    static var phase1Types: [EditorTransition.TransitionType] { [.fade, .dissolve] }

    var displayName: String {
        switch self {
        case .fade:             return "叠化"
        case .dissolve:         return "溶解"
        case .slideLeft:        return "左滑"
        case .slideRight:       return "右滑"
        case .slideUp:          return "上滑"
        case .slideDown:        return "下滑"
        case .zoom:             return "缩放"
        case .wipe:             return "擦除"
        case .crossFade:        return "叠化"
        case .fadeThroughBlack: return "闪黑"
        case .pushLeft:         return "推进·左"
        case .pushRight:        return "推进·右"
        case .zoomIn:           return "放大"
        case .blurFade:         return "模糊叠化"
        }
    }

    var iconName: String {
        switch self {
        case .fade:             return "circle.lefthalf.filled"
        case .dissolve:         return "circle.dotted"
        case .slideLeft:        return "arrow.left"
        case .slideRight:       return "arrow.right"
        case .slideUp:          return "arrow.up"
        case .slideDown:        return "arrow.down"
        case .zoom:             return "arrow.up.left.and.arrow.down.right"
        case .wipe:             return "square.lefthalf.filled"
        case .crossFade:        return "circle.lefthalf.filled"
        case .fadeThroughBlack: return "moon.fill"
        case .pushLeft:         return "arrow.left.to.line"
        case .pushRight:        return "arrow.right.to.line"
        case .zoomIn:           return "plus.magnifyingglass"
        case .blurFade:         return "camera.filters"
        }
    }
}
#endif
