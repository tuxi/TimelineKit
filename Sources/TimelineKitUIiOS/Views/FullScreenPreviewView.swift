#if canImport(UIKit)
import SwiftUI
import AVFoundation
import TimelineKitCore
import TimelineKitUIShared

/// V5 fullscreen-preview-spec §3：同源全屏真实预览的 SwiftUI 容器。
///
/// 沉浸式只读语义：仅播放 / 暂停 / 拖拽进度 / 退出 4 项操作；不允许在全屏内
/// 编辑（不可拖字幕、不可调样式）。与剪映 / CapCut / FCP / LumaFusion 行为一致。
///
/// 字幕、描边、阴影、背景、层级 5 类样式均走与导出同一条 CIImage/CALayer 烘焙路径，
/// 解决"预览 ≠ 成片"痛点。
struct FullScreenPreviewView: View {

    let timeline: EditorTimeline

    /// 退出时回传 player 最后停留位置；上层（ClipEditorView）回写到
    /// `store.selection.playheadTime`，编辑画布播放头跳到该时刻。
    let onDismiss: (CMTime) -> Void

    @State private var controller = FullScreenPreviewController()
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            playerLayer

            // 顶部退出按钮（始终可见）
            VStack {
                HStack {
                    Spacer()
                    closeButton
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                }
                Spacer()
            }

            // 底部控制栏
            VStack {
                Spacer()
                if controller.isReady {
                    controlBar
                        .padding(.bottom, 24)
                }
            }

            // Loading / Error 覆盖
            if !controller.isReady {
                loadingOverlay
            }
        }
        .task {
            await controller.build(timeline: timeline)
            // 构建完成后自动播放——与剪映/CapCut 行为一致
            if controller.errorMessage == nil {
                controller.play()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var playerLayer: some View {
        if controller.isReady {
            if controller.usesTimelineRuntime {
                TimelinePreviewRepresentable(previewView: controller.timelinePreviewView)
                    .ignoresSafeArea()
            } else {
                AVPlayerRepresentable(player: controller.player)
                    .ignoresSafeArea()
            }
        } else if let img = controller.firstFrameImage {
            // 首帧占位（用导出同源帧），避免黑屏
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .accessibilityLabel("退出全屏")
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            // 播放/暂停
            Button(action: togglePlay) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }

            // 进度条
            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { newValue in
                        controller.seek(to: newValue)
                    }
                ),
                in: 0...max(controller.duration, 0.1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        controller.pause()
                    }
                }
            )
            .tint(.white)

            // 时间显示
            Text("\(formatTime(controller.currentTime)) / \(formatTime(controller.duration))")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            Color.black.opacity(0.55)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .padding(.horizontal, 16)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(controller.firstFrameImage == nil ? 1.0 : 0.4)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                if let err = controller.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.yellow)
                    Text("预览构建失败")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                    Text("正在生成同源预览…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Actions

    private func togglePlay() {
        if controller.isPlaying {
            controller.pause()
        } else {
            controller.play()
        }
    }

    private func dismiss() {
        controller.recordExitPlayhead()
        let exitTime = controller.exitPlayheadTime
        controller.teardown()
        onDismiss(exitTime)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
