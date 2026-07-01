#if canImport(UIKit)
import SwiftUI

// MARK: - AnimationPickerSheet

/// Bottom overlay panel for picking entrance / exit / combo animations on a clip.
/// V7 Am4 — three tabs (入场 / 出场 / 组合), preset grid, duration slider.
///
/// Presentation: overlay panel driven by `activeToolCategory == .animation` in ClipEditorView.
/// Changes apply immediately via `store.setClipAnimation` (undo-tracked); the slider uses
/// `previewClipAnimation` for continuous drag updates.
struct AnimationPickerSheet: View {

    let segmentID: UUID
    @Bindable var store: EditorStore
    var onDismiss: (() -> Void)? = nil

    @State private var selectedTab: AnimationTiming
    @State private var showConflictAlert = false
    @State private var pendingComboSemantic: AnimationSemantic? = nil

    init(segmentID: UUID, store: EditorStore, onDismiss: (() -> Void)? = nil) {
        self.segmentID = segmentID
        self.store     = store
        self.onDismiss = onDismiss
        AnimationPresetRegistry.ensureDefaultsRegistered()

        // Open on the tab that already has an animation, or .in by default.
        let seg = store.timeline.segment(id: segmentID)
        if seg?.comboAnimation != nil         { _selectedTab = State(initialValue: .combo) }
        else if seg?.outAnimation != nil      { _selectedTab = State(initialValue: .out) }
        else                                  { _selectedTab = State(initialValue: .in) }
    }

    // MARK: - Derived state

    private var segment: EditorSegment? {
        store.timeline.segment(id: segmentID)
    }

    private var segmentDuration: Double {
        segment?.targetRange.duration ?? 3.0
    }

    private var currentAnimation: ClipAnimation? {
        switch selectedTab {
        case .in:    return segment?.inAnimation
        case .out:   return segment?.outAnimation
        case .combo: return segment?.comboAnimation
        }
    }

    private var currentSemantic: AnimationSemantic? { currentAnimation?.semantic }

    private var currentDuration: Double { currentAnimation?.duration ?? 0.5 }

    private var sliderMax: Double {
        let segDur   = segmentDuration
        let maxHalf  = min(2.0, segDur * 0.5)
        switch selectedTab {
        case .in:
            var cap = maxHalf
            if let outDur = segment?.outAnimation?.duration, outDur > 0 {
                cap = min(cap, segDur - outDur)
            }
            return max(0.1, cap)
        case .out:
            var cap = maxHalf
            if let inDur = segment?.inAnimation?.duration, inDur > 0 {
                cap = min(cap, segDur - inDur)
            }
            return max(0.1, cap)
        case .combo:
            return segmentDuration
        }
    }

    private var showDurationSlider: Bool {
        currentSemantic != nil && selectedTab != .combo
    }

    private var durationOverflow: Bool {
        let inDur  = segment?.inAnimation?.duration  ?? 0
        let outDur = segment?.outAnimation?.duration ?? 0
        return inDur + outDur > segmentDuration
    }

    // MARK: - Preset list

    private struct PresetItem: Identifiable {
        let id: String
        let name: String
        let icon: String
        let semantic: AnimationSemantic?
    }

    private var presetsForTab: [PresetItem] {
        switch selectedTab {
        case .in:
            return [
                .init(id: "none",        name: "无",    icon: "xmark.circle",          semantic: nil),
                .init(id: "fadeIn",      name: "渐显",   icon: "sun.horizon",           semantic: .fadeIn),
                .init(id: "slideInL",    name: "向右滑入", icon: "arrow.right.to.line",  semantic: .slideInLeft),
                .init(id: "slideInR",    name: "向左滑入", icon: "arrow.left.to.line",   semantic: .slideInRight),
                .init(id: "slideInU",    name: "向下滑入", icon: "arrow.down.to.line",   semantic: .slideInUp),
                .init(id: "slideInD",    name: "向上滑入", icon: "arrow.up.to.line",     semantic: .slideInDown),
                .init(id: "zoomIn",      name: "放大",   icon: "plus.magnifyingglass",  semantic: .zoomIn),
            ]
        case .out:
            return [
                .init(id: "none",        name: "无",    icon: "xmark.circle",           semantic: nil),
                .init(id: "fadeOut",     name: "渐隐",   icon: "moon",                  semantic: .fadeOut),
                .init(id: "slideOutL",   name: "向右退出", icon: "arrow.right.to.line",  semantic: .slideOutLeft),
                .init(id: "slideOutR",   name: "向左退出", icon: "arrow.left.to.line",   semantic: .slideOutRight),
                .init(id: "zoomOut",     name: "缩小",   icon: "minus.magnifyingglass",  semantic: .zoomOut),
            ]
        case .combo:
            return [
                .init(id: "none",            name: "无",    icon: "xmark.circle",             semantic: nil),
                // Ken Burns 基础动画
                .init(id: "slowZoom",        name: "缓慢放大", icon: "plus.magnifyingglass",   semantic: .slowZoom),
                .init(id: "slowZoomOut",     name: "缓慢缩小", icon: "minus.magnifyingglass",  semantic: .slowZoomOut),
                .init(id: "panLeft",         name: "向左平移", icon: "arrow.left",             semantic: .panLeft),
                .init(id: "panRight",        name: "向右平移", icon: "arrow.right",            semantic: .panRight),
                .init(id: "drift",           name: "漂移",   icon: "wind",                    semantic: .drift),
                .init(id: "float",           name: "漂浮",   icon: "cloud",                   semantic: .float),
                // 景深动画（从 ImageAnimationPreset 迁移）
                .init(id: "depthPush",       name: "景深推进", icon: "arrow.up.forward.circle",   semantic: .depthPush),
                .init(id: "depthPull",       name: "景深后退", icon: "arrow.down.backward.circle", semantic: .depthPull),
                .init(id: "depthOrbitLeft",  name: "环绕左",  icon: "arrow.counterclockwise",    semantic: .depthOrbitLeft),
                .init(id: "depthOrbitRight", name: "环绕右",  icon: "arrow.clockwise",           semantic: .depthOrbitRight),
            ]
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            header
            tabBar.padding(.top, 10)
            presetGrid.padding(.top, 12)

            if selectedTab == .combo && currentSemantic != nil {
                comboFullDurationNote
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }

            if showDurationSlider {
                durationSlider
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)
        }
        .frame(height: 320)
        .animation(.easeInOut(duration: 0.18), value: showDurationSlider)
        .background(Color(white: 0.13))
        .alert("切换到组合动画", isPresented: $showConflictAlert, presenting: pendingComboSemantic) { sem in
            Button("确认", role: .destructive) {
                commitAnimation(semantic: sem, timing: .combo)
                pendingComboSemantic = nil
            }
            Button("取消", role: .cancel) { pendingComboSemantic = nil }
        } message: { _ in
            Text("设置组合动画将清除已有的入场和出场动画")
        }
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
            Text("动画")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button("完成") { onDismiss?() }
                .foregroundStyle(.white)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach([AnimationTiming.in, .out, .combo], id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tabLabel(tab))
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
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var presetGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(presetsForTab) { item in
                    AnimPresetCell(
                        name:       item.name,
                        icon:       item.icon,
                        isSelected: isSelected(item)
                    ) {
                        handlePresetTap(item)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: 200)
    }

    private var comboFullDurationNote: some View {
        HStack {
            Text(String(format: "全程 %.1fs", segmentDuration))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
    }

    private var durationSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("时长")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f s", currentDuration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(durationOverflow ? Color.red : Color.white)
            }
            if sliderMax > 0.1 {
                Slider(
                    value: Binding(
                        get: { currentDuration },
                        set: { updateDuration($0) }
                    ),
                    in: 0.1...sliderMax,
                    step: 0.1
                )
                .tint(durationOverflow ? .red : .white)
            }
            if durationOverflow {
                Text("动画时长过长，已自动压缩")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
    }

    // MARK: - Helpers

    private func tabLabel(_ timing: AnimationTiming) -> String {
        switch timing {
        case .in:    return "入场"
        case .out:   return "出场"
        case .combo: return "组合"
        }
    }

    private func isSelected(_ item: PresetItem) -> Bool {
        item.semantic == nil ? currentSemantic == nil : currentSemantic == item.semantic
    }

    // MARK: - Actions

    private func handlePresetTap(_ item: PresetItem) {
        guard let sem = item.semantic else {
            // "无" — remove animation for this tab
            store.removeClipAnimation(segmentID: segmentID, timing: selectedTab)
            return
        }

        if selectedTab == .combo {
            let hasInOut = segment?.inAnimation != nil || segment?.outAnimation != nil
            if hasInOut {
                pendingComboSemantic = sem
                showConflictAlert = true
                return
            }
        }
        commitAnimation(semantic: sem, timing: selectedTab)
    }

    private func commitAnimation(semantic: AnimationSemantic, timing: AnimationTiming) {
        let dur  = max(0.1, currentDuration)
        let anim = ClipAnimation(semantic: semantic, timing: timing, duration: dur)
        store.setClipAnimation(segmentID: segmentID, animation: anim)
        // Live Preview: seek to the segment's start so the animation is visible
        if let seg = segment {
            store.seek(to: seg.targetRange.start)
        }
    }

    private func updateDuration(_ newDur: Double) {
        guard let sem = currentSemantic else { return }
        let anim = ClipAnimation(semantic: sem, timing: selectedTab, duration: newDur)
        store.previewClipAnimation(segmentID: segmentID, animation: anim)
    }
}

// MARK: - AnimPresetCell

private struct AnimPresetCell: View {
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
        .buttonStyle(.plain)
    }
}
#endif
