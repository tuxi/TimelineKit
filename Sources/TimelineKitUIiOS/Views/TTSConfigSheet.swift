#if canImport(UIKit)
import SwiftUI
import AVFoundation
import TimelineKitCore
import TimelineKitUIShared

/// V3 tts-spec §5.3: configuration sheet for the TTS flow.
/// Voice selector (女声/男声) + rate slider (0.5x-2.0x) + 试听 + 应用.
/// Picks up `store.lastTTSVoice` / `store.lastTTSRate` as initial values.
struct TTSConfigSheet: View {

    let store: EditorStore
    let targetSegmentIDs: [UUID]
    var onDismiss: () -> Void

    @State private var voice: TTSService.VoiceKind = .female
    @State private var rate: Double = 1.0
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var previewSynth: AVSpeechSynthesizer?

    var body: some View {
        NavigationStack {
            Form {
                Section("声线") {
                    Picker("声线", selection: $voice) {
                        ForEach(TTSService.VoiceKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("语速 \(String(format: "%.1fx", rate))") {
                    HStack {
                        Text("0.5x").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $rate, in: 0.5...2.0, step: 0.1)
                        Text("2.0x").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        previewVoice()
                    } label: {
                        Label("试听当前设置", systemImage: "play.circle")
                    }
                    .disabled(isGenerating)

                    Button {
                        Task { await applyAndGenerate() }
                    } label: {
                        HStack {
                            if isGenerating {
                                ProgressView().controlSize(.small)
                            }
                            Text(isGenerating ? "生成中…" : "应用")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isGenerating || targetSegmentIDs.isEmpty)
                }

                Section("说明") {
                    Text("将为选中的 \(targetSegmentIDs.count) 条文案生成配音音频，自动插入音频轨道。修改文案后可再次进入本面板重新生成。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("文字朗读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        stopPreview()
                        onDismiss()
                    }
                    .disabled(isGenerating)
                }
            }
            .alert(
                "生成失败",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                presenting: errorMessage
            ) { _ in
                Button("确定") { errorMessage = nil }
            } message: { msg in
                Text(msg)
            }
            .onAppear {
                voice = store.lastTTSVoice
                rate  = store.lastTTSRate
            }
            .onDisappear { stopPreview() }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func previewVoice() {
        stopPreview()
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: previewText)
        utterance.voice = voice.resolveSystemVoice()
        let mapped = Float(rate) * AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                             min(AVSpeechUtteranceMaximumSpeechRate, mapped))
        synth.speak(utterance)
        previewSynth = synth
    }

    private func stopPreview() {
        previewSynth?.stopSpeaking(at: .immediate)
        previewSynth = nil
    }

    private var previewText: String {
        // Use the first target's actual text if available; fall back to a stock sample.
        if let first = targetSegmentIDs.first,
           let seg = store.timeline.segment(id: first) {
            switch seg.content {
            case .text(let c):     if !c.text.isEmpty { return c.text }
            case .subtitle(let c): if !c.text.isEmpty { return c.text }
            default: break
            }
        }
        return "试听一下这个声音的效果"
    }

    private func applyAndGenerate() async {
        stopPreview()
        isGenerating = true
        defer { isGenerating = false }
        do {
            try await store.regenerateTTS(
                forSourceSegments: targetSegmentIDs,
                voice: voice,
                rate:  rate
            )
            onDismiss()
        } catch let err as TTSService.Failure {
            errorMessage = err.errorDescription ?? "未知错误"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
