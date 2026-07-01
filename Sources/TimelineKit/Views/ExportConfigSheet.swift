#if canImport(UIKit)
import SwiftUI

/// V5 export-config-panel-spec §5.2：导出参数配置面板。
///
/// UI 沿用 `TTSConfigSheet` 风格（NavigationStack + Form + Section + segmented Picker）。
/// 4 个参数：分辨率 / 帧率 / 码率（三档）/ 智能 HDR。
///
/// 任一字段变更即时调 `store.mutateExportConfig` → 实时持久化（DraftStore.save 同步落盘）；
/// "完成"按钮仅 dismiss，不二次落盘。
struct ExportConfigSheet: View {

    let store: EditorStore
    var onDismiss: () -> Void

    /// 临时编辑态。`onAppear` 时由 `store.timeline.effectiveExportConfig` 初始化
    /// （新工程/旧草稿走 `default(for: canvas)` 派生；已设置过的工程走持久化值）。
    @State private var cfg: ExportConfig = .factoryDefault

    var body: some View {
        NavigationStack {
            Form {
                Section("分辨率") {
                    Picker("分辨率", selection: $cfg.resolution) {
                        ForEach(ExportConfig.Resolution.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.resolution) { _, new in
                        store.mutateExportConfig { $0.resolution = new }
                    }
                }

                Section("帧率") {
                    Picker("帧率", selection: $cfg.fps) {
                        ForEach(ExportConfig.FrameRate.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.fps) { _, new in
                        store.mutateExportConfig { $0.fps = new }
                    }
                }

                Section("码率") {
                    Picker("码率", selection: $cfg.bitrateTier) {
                        ForEach(ExportConfig.BitrateTier.allCases, id: \.self) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cfg.bitrateTier) { _, new in
                        store.mutateExportConfig { $0.bitrateTier = new }
                    }
                }

                Section("高级") {
                    Toggle("智能 HDR", isOn: $cfg.hdrEnabled)
                        .disabled(!isHDRAvailable)
                        .onChange(of: cfg.hdrEnabled) { _, new in
                            store.mutateExportConfig { $0.hdrEnabled = new }
                        }

                    Text(hdrFootnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("恢复默认", role: .destructive) {
                        store.resetExportConfigToDefault()
                        cfg = store.timeline.effectiveExportConfig    // 重新按 canvas 派生
                    }
                }

                Section("说明") {
                    Text("默认跟随当前画布尺寸与帧率自动匹配最接近档位；可手动选择更高/更低分辨率。导出配置随工程保存，下次打开继续沿用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导出规格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                cfg = store.timeline.effectiveExportConfig
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - HDR 能力检测（详见 render-pipeline-unification-spec.md §7 / §5）

    /// M3 阶段始终 false（HDR Toggle 禁用，文案显示"即将上线"）。
    /// M4 阶段切换为真实设备能力检测（参考 VideoExporter.canEncodeHDR）。
    private var isHDRAvailable: Bool {
        ExportEncodingProfile.canEncodeHDR()
    }

    private var hdrFootnote: String {
        if isHDRAvailable {
            return "开启后自动依据原素材色彩动态转译生成 HDR 画质视频"
        }
        return "智能 HDR 即将上线"
    }
}

#endif
