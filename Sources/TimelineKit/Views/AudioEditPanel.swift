#if canImport(UIKit)
import SwiftUI

/// v3 P3 (audio-feature-spec §10): dedicated edit panel for a selected `.audio`
/// segment. Hosts volume / mute / speed controls in one place so users don't
/// have to hunt through different categories.
///
/// Dispatched from ClipEditorView when `selection.singleSelectedID` is an
/// `.audio` segment — supersedes the temp speed slider that P0 parked inside
/// `AudioSecondaryPanel`.
struct AudioEditPanel: View {

    let segmentID: UUID
    let store: EditorStore

    @State private var isDraggingVolume = false
    @State private var localVolume: Double = 1.0
    @State private var isDraggingSpeed = false
    @State private var isDraggingFade = false
    @State private var localFadeIn: Double = 0
    @State private var localFadeOut: Double = 0

    static let height: CGFloat = 260

    // MARK: - Computed

    private var segment: EditorSegment? {
        store.timeline.segment(id: segmentID)
    }

    private var audioContent: SegmentContent.AudioContent? {
        guard let seg = segment, case .audio(let c) = seg.content else { return nil }
        return c
    }

    private var currentVolume: Double { audioContent?.volume ?? 1.0 }
    private var isMuted:       Bool   { audioContent?.isMuted ?? false }
    private var currentSpeed:  Double { segment?.speed ?? 1.0 }
    private var durationSecs:  Double { segment?.targetRange.duration ?? 0 }

    private var assetName: String {
        guard let mid = segment?.materialID,
              let asset = store.timeline.materials[mid],
              let url = asset.localURL ?? asset.remoteURL else { return "音频片段" }
        return url.lastPathComponent
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            volumeRow
            speedRow
            muteRow
            fadeRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .topLeading)
        .background(Color(white: 0.13))
        .overlay(alignment: .top) {
            Divider().background(Color.white.opacity(0.08))
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            localVolume = currentVolume
            localFadeIn  = audioContent?.fadeInDuration ?? 0
            localFadeOut = audioContent?.fadeOutDuration ?? 0
        }
        .onChange(of: currentVolume) { _, v in
            if !isDraggingVolume { localVolume = v }
        }
        .onChange(of: audioContent?.fadeInDuration) { _, v in
            localFadeIn = v ?? 0
        }
        .onChange(of: audioContent?.fadeOutDuration) { _, v in
            localFadeOut = v ?? 0
        }
    }

    // MARK: - Header (segment info)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.85))
            Text(assetName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(String(format: "%.1fs", durationSecs))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))
            // P3 fix: explicit dismiss button. Tapping deselects the audio segment
            // so the dispatch chain in ClipEditorView falls through to whatever
            // category the user selects next (or nothing, collapsing the panel).
            Button {
                store.selection.deselect()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Volume

    private var volumeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("音量")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Text("\(Int(localVolume * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(
                value: $localVolume,
                in: 0...2,
                step: 0.05,
                onEditingChanged: { editing in
                    isDraggingVolume = editing
                    if !editing {
                        store.setAudioVolume(segmentID: segmentID, volume: localVolume)
                    }
                }
            )
            .tint(.white)
            .onChange(of: localVolume) { _, v in
                if isDraggingVolume {
                    store.previewAudioVolume(segmentID: segmentID, volume: v)
                }
            }
        }
    }

    // MARK: - Speed

    private var speedRow: some View {
        let range = EditorStore.audioSpeedRange
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("速度")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.1fx", currentSpeed))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(
                value: Binding(
                    get: { currentSpeed },
                    set: { store.previewAudioSpeed(segmentID: segmentID, speed: $0) }
                ),
                in: range,
                step: 0.1,
                onEditingChanged: { editing in
                    isDraggingSpeed = editing
                    if !editing {
                        let final = store.timeline.segment(id: segmentID)?.speed ?? currentSpeed
                        store.setAudioSpeed(segmentID: segmentID, speed: final)
                    }
                }
            )
            .tint(.white)
        }
    }

    // MARK: - Mute

    private var muteRow: some View {
        Toggle(isOn: Binding(
            get: { isMuted },
            set: { store.muteAudioSegment(id: segmentID, isMuted: $0) }
        )) {
            HStack(spacing: 6) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                Text(isMuted ? "已静音" : "静音此片段")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
        .tint(.white.opacity(0.8))
    }

    // MARK: - Fade (v4 audio-track-controls-spec §2.5)

    /// Snap points for fade sliders. Dragging within ±0.02 of these values
    /// causes the slider to stick and triggers haptic feedback.
    private static let fadeSnapPoints: [Double] = [0, 0.5, 1.0, 2.0]
    private static let fadeSnapThreshold: Double = 0.02

    private var fadeRow: some View {
        let maxFade = min(2.0, durationSecs / 2)
        return VStack(alignment: .leading, spacing: 10) {
            Text("淡化")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))

            fadeSliderRow(label: "淡入", value: $localFadeIn, range: 0...maxFade,
                          onEditingChanged: onFadeDragChanged)
            fadeSliderRow(label: "淡出", value: $localFadeOut, range: 0...maxFade,
                          onEditingChanged: onFadeDragChanged)
        }
    }

    private func onFadeDragChanged(_ editing: Bool) {
        isDraggingFade = editing
        if !editing {
            store.mutateAudioFade(segmentID: segmentID, fadeIn: localFadeIn, fadeOut: localFadeOut)
        }
    }

    private func fadeSliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                               onEditingChanged: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Text(String(format: "%.1fs", value.wrappedValue))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(value.wrappedValue > 0 ? .white : Color.white.opacity(0.4))
            }
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newVal in
                        let snapped = Self.snapFade(newVal)
                        if snapped != value.wrappedValue {
                            let gen = UISelectionFeedbackGenerator()
                            gen.selectionChanged()
                        }
                        value.wrappedValue = snapped
                    }
                ),
                in: range,
                step: 0.01,
                onEditingChanged: onEditingChanged
            )
            .tint(.white)
        }
    }

    /// Snap `value` to nearest snap point within threshold, then clamp to range.
    private static func snapFade(_ value: Double) -> Double {
        for snap in fadeSnapPoints {
            if abs(value - snap) <= fadeSnapThreshold {
                return snap
            }
        }
        return value
    }
}
#endif
