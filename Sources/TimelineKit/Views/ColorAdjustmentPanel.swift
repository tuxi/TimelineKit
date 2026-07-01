#if canImport(UIKit)
import SwiftUI

// MARK: - ColorAdjustmentPanel

/// Slide-up panel for per-segment color and tone adjustments.
/// Shown when the `.adjust` toolbar category is active and a main-track segment is selected.
struct ColorAdjustmentPanel: View {

    let segmentID: UUID
    @Bindable var store: EditorStore
    var onDismiss: (() -> Void)? = nil

    @State private var tab: Tab = .adjust

    private var adjustment: SegmentAdjustment {
        store.timeline.segment(id: segmentID)?.adjustment ?? .identity
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(Color.white.opacity(0.1))

            switch tab {
            case .adjust: adjustSliders
            case .filter: filterPicker
            }
        }
        .background(Color(white: 0.13))
    }

    // MARK: - Tab bar

    private enum Tab: String, CaseIterable {
        case adjust = "调节"
        case filter = "滤镜"
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

            // Reset button
            Button {
                store.resetAdjustment(segmentID: segmentID)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14))
                    .foregroundStyle(adjustment.isIdentity
                                     ? Color.white.opacity(0.25)
                                     : Color.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .disabled(adjustment.isIdentity)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    // MARK: - Adjust sliders

    private var adjustSliders: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                adjustRow("亮度",   value: adjustment.brightness,  range: -1...1,    format: "%+.2f") { v in
                    store.previewAdjustment(segmentID: segmentID, adjustment: adjusted(brightness: v))
                } onEnd: { v in
                    store.setAdjustment(segmentID: segmentID, adjustment: adjusted(brightness: v))
                }
                adjustRow("对比度",  value: adjustment.contrast - 1, range: -0.5...0.5, format: "%+.2f") { v in
                    store.previewAdjustment(segmentID: segmentID, adjustment: adjusted(contrast: v + 1))
                } onEnd: { v in
                    store.setAdjustment(segmentID: segmentID, adjustment: adjusted(contrast: v + 1))
                }
                adjustRow("饱和度",  value: adjustment.saturation - 1, range: -1...1,  format: "%+.2f") { v in
                    store.previewAdjustment(segmentID: segmentID, adjustment: adjusted(saturation: v + 1))
                } onEnd: { v in
                    store.setAdjustment(segmentID: segmentID, adjustment: adjusted(saturation: v + 1))
                }
                adjustRow("色温",   value: adjustment.temperature, range: 2000...9000, format: "%.0f K") { v in
                    store.previewAdjustment(segmentID: segmentID, adjustment: adjusted(temperature: v))
                } onEnd: { v in
                    store.setAdjustment(segmentID: segmentID, adjustment: adjusted(temperature: v))
                }
                adjustRow("色调",   value: adjustment.tint,        range: -150...150,  format: "%+.0f") { v in
                    store.previewAdjustment(segmentID: segmentID, adjustment: adjusted(tint: v))
                } onEnd: { v in
                    store.setAdjustment(segmentID: segmentID, adjustment: adjusted(tint: v))
                }
                adjustRow("高光",   value: adjustment.highlights,  range: -1...1,      format: "%+.2f") { v in
                    store.previewAdjustment(segmentID: segmentID, adjustment: adjusted(highlights: v))
                } onEnd: { v in
                    store.setAdjustment(segmentID: segmentID, adjustment: adjusted(highlights: v))
                }
                adjustRow("阴影",   value: adjustment.shadows,     range: -1...1,      format: "%+.2f") { v in
                    store.previewAdjustment(segmentID: segmentID, adjustment: adjusted(shadows: v))
                } onEnd: { v in
                    store.setAdjustment(segmentID: segmentID, adjustment: adjusted(shadows: v))
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 240)
    }

    // MARK: - Filter picker

    private var filterPicker: some View {
        VStack(spacing: 0) {
            // Category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    filterNoneChip
                    ForEach(PresetFilter.Category.allCases, id: \.self) { cat in
                        filterCategorySection(cat)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            // Intensity slider (shown when a filter is active)
            if adjustment.filterName != nil {
                IntensitySliderRow(
                    intensity:  adjustment.filterIntensity,
                    filterName: adjustment.filterName,
                    onPreview: { v in
                        store.previewAdjustment(segmentID: segmentID,
                                                adjustment: adjusted(filterIntensity: v))
                    },
                    onEnd: { v in
                        store.setAdjustment(segmentID: segmentID,
                                            adjustment: adjustedFilter(adjustment.filterName, intensity: v))
                    }
                )
            }
        }
    }

    private var filterNoneChip: some View {
        filterChip(label: "无", isSelected: adjustment.filterName == nil) {
            store.setAdjustment(segmentID: segmentID,
                                adjustment: adjustedFilter(nil, intensity: 1.0))
        }
    }

    @ViewBuilder
    private func filterCategorySection(_ category: PresetFilter.Category) -> some View {
        ForEach(PresetFilter.allCases.filter { $0.category == category }, id: \.self) { preset in
            filterChip(label: preset.displayName, isSelected: adjustment.filterName == preset) {
                store.setAdjustment(segmentID: segmentID,
                                    adjustment: adjustedFilter(preset))
            }
        }
    }

    private func filterChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.white : Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Adjust row

    private func adjustRow(
        _ label: String,
        value:   Double,
        range:   ClosedRange<Double>,
        format:  String,
        onPreview: @escaping (Double) -> Void,
        onEnd:     @escaping (Double) -> Void
    ) -> some View {
        AdjustSliderRow(
            label:     label,
            value:     value,
            range:     range,
            format:    format,
            onPreview: onPreview,
            onEnd:     onEnd
        )
    }

    // MARK: - Helpers: build SegmentAdjustment variants from current state

    private func adjusted(brightness: Double? = nil, contrast: Double? = nil,
                          saturation: Double? = nil, temperature: Double? = nil,
                          tint: Double? = nil, highlights: Double? = nil,
                          shadows: Double? = nil,
                          filterIntensity: Double? = nil) -> SegmentAdjustment {
        var a = adjustment
        if let v = brightness      { a.brightness      = v }
        if let v = contrast        { a.contrast        = v }
        if let v = saturation      { a.saturation      = v }
        if let v = temperature     { a.temperature     = v }
        if let v = tint            { a.tint            = v }
        if let v = highlights      { a.highlights      = v }
        if let v = shadows         { a.shadows         = v }
        if let v = filterIntensity { a.filterIntensity = v }
        return a
    }

    private func adjustedFilter(_ name: PresetFilter?, intensity: Double? = nil) -> SegmentAdjustment {
        var a = adjustment
        a.filterName      = name
        a.filterIntensity = intensity ?? a.filterIntensity
        return a
    }
}

// MARK: - AdjustSliderRow

private struct AdjustSliderRow: View {
    let label:     String
    let value:     Double
    let range:     ClosedRange<Double>
    let format:    String
    let onPreview: (Double) -> Void
    let onEnd:     (Double) -> Void

    @State private var liveValue: Double
    @State private var isDragging = false

    init(label: String, value: Double, range: ClosedRange<Double>,
         format: String, onPreview: @escaping (Double) -> Void, onEnd: @escaping (Double) -> Void) {
        self.label     = label
        self.value     = value
        self.range     = range
        self.format    = format
        self.onPreview = onPreview
        self.onEnd     = onEnd
        _liveValue = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 40, alignment: .leading)

            // onEditingChanged is the correct SwiftUI API for detecting drag start/end on a Slider.
            // Avoids the simultaneousGesture(DragGesture) anti-pattern that steals the Slider's gesture.
            Slider(value: $liveValue, in: range, onEditingChanged: { editing in
                isDragging = editing
                if !editing { onEnd(liveValue) }
            })
            .tint(.white)
            .onChange(of: liveValue) { _, v in
                if isDragging { onPreview(v) }
            }

            Text(String(format: format, liveValue))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onChange(of: value) { _, newValue in
            // Sync externally-driven changes (undo/redo) back to the slider.
            if !isDragging { liveValue = newValue }
        }
    }
}

// MARK: - IntensitySliderRow

private struct IntensitySliderRow: View {
    let intensity:  Double
    let filterName: PresetFilter?
    let onPreview:  (Double) -> Void
    let onEnd:      (Double) -> Void

    @State private var liveIntensity: Double
    @State private var isDragging = false

    init(intensity: Double, filterName: PresetFilter?,
         onPreview: @escaping (Double) -> Void, onEnd: @escaping (Double) -> Void) {
        self.intensity  = intensity
        self.filterName = filterName
        self.onPreview  = onPreview
        self.onEnd      = onEnd
        _liveIntensity  = State(initialValue: intensity)
    }

    var body: some View {
        HStack {
            Text("强度")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $liveIntensity, in: 0...1, step: 0.01, onEditingChanged: { editing in
                isDragging = editing
                if !editing { onEnd(liveIntensity) }
            })
            .tint(.white)
            .onChange(of: liveIntensity) { _, v in
                if isDragging { onPreview(v) }
            }
            Text(String(format: "%.0f%%", liveIntensity * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onChange(of: intensity) { _, newValue in
            if !isDragging { liveIntensity = newValue }
        }
    }
}
#endif
