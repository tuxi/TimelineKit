//
//  ToastView.swift
//  TimelineKit
//
//  Created by xiaoyuan on 2026/3/14.
//

import SwiftUI

/// Toast 的配置模型
struct ToastConfig: Equatable {
    let message: String
    let icon: String?
    let style: ToastStyle
    let duration: TimeInterval
    let position: ToastPosition // 位置属性
    let offset: CGFloat         // 微调偏移量
    
    public enum ToastStyle {
        case info, success, error, warning
        
        var color: Color {
            switch self {
            case .error: return .red
            case .success: return .green
            case .warning: return .orange
            case .info:
                // 如果是 info，在浅色模式用蓝色或灰色，深色模式用白色，会更清晰
                return .accentColor
            }
        }
    }
    
    // 定义位置枚举
    public enum ToastPosition {
        case top, center, bottom
        
        var alignment: Alignment {
            switch self {
            case .top: return .top
            case .center: return .center
            case .bottom: return .bottom
            }
        }
    }
}

/// 全局单例管理器
@MainActor
@Observable
class ToastContext {
    public static let shared = ToastContext()
    
    var currentToast: ToastConfig?
    private var workItem: DispatchWorkItem?
    
    // 窗口引用
#if os(iOS)
    private var toastWindow: UIWindow?
#elseif os(macOS)
    private var toastWindow: NSWindow?
#endif
    
    /// 初始化全局窗口（只需在 App 启动时调用一次）
    private func bootstrap() {
#if os(iOS)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              toastWindow == nil else { return }
        
        let window = UIWindow(windowScene: windowScene)
        // 关键：设置窗口级别为最高，确保在 Alert 和 Sheet 之上
        window.windowLevel = .alert + 1
        let controller = UIHostingController(rootView: GlobalToastContainer())
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        window.isHidden = false
        window.isUserInteractionEnabled = false // 允许点击穿透到下方业务层
        self.toastWindow = window
        
#elseif os(macOS)
        guard toastWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), // 给个初始大小，后面会自适应
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating // 设置在普通窗口之上
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true // 点击穿透
        // ✨ 关键代码：允许窗口出现在所有 Space，并且作为全屏窗口的附属
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let hostingView = NSHostingView(rootView: GlobalToastContainer())
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        // 让窗口居中或置顶（根据需求）
        window.center()
        self.toastWindow = window
#endif
    }
    
    /// 核心 API：一句话显示 Toast
    public func show(
        _ message: String,
        icon: String? = nil,
        style: ToastConfig.ToastStyle = .info,
        duration: TimeInterval = 2.5,
        position: ToastConfig.ToastPosition = .top, // 默认顶部
        offset: CGFloat = 0
    ) {
        
        // 保证在主线程更新 UI
        Task { @MainActor in
            
            // 如果窗口还没初始化，自动初始化
            if toastWindow == nil { bootstrap() }
            
            // 先重置当前 Toast，确保动画能重新触发（如果需要连续弹窗）
            if currentToast != nil {
                currentToast = nil
                try? await Task.sleep(nanoseconds: 100_000_000) // 停 0.1s 保证切换感
            }
            
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.currentToast = ToastConfig(
                    message: message,
                    icon: icon,
                    style: style,
                    duration: duration,
                    position: position,
                    offset: offset
                )
            }
            
            workItem?.cancel()
            let task = DispatchWorkItem {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    self.currentToast = nil
                }
            }
            workItem = task
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
        }
    }
}

struct GlobalToastContainer: View {
    @Bindable var context = ToastContext.shared
    
    var body: some View {
        ZStack {
            if let toast = context.currentToast {
                VStack {
                    if toast.position == .bottom { Spacer() }
                    
                    ToastView(config: toast)
                    // ✨ 增加 id 确保 transition 每次都触发
                        .id(toast.message + "\(toast.position)")
                        .transition(getTransition(for: toast.position))
                        .padding(toast.position == .top ? .top : .bottom, 60)
                        .offset(y: toast.offset)
                        .allowsHitTesting(true)
                    
                    if toast.position == .top { Spacer() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // ✨ 在容器级别增加动画关联
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: context.currentToast)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
    
    private func getTransition(for pos: ToastConfig.ToastPosition) -> AnyTransition {
        switch pos {
        case .top: return .move(edge: .top).combined(with: .opacity)
        case .bottom: return .move(edge: .bottom).combined(with: .opacity)
        case .center: return .opacity.combined(with: .scale(scale: 0.9))
        }
    }
}

struct ToastContainerModifier: ViewModifier {
    @Bindable var context = ToastContext.shared
    
    func body(content: Content) -> some View {
        content
            .overlay(alignment: context.currentToast?.position.alignment ?? .top) {
                if let toast = context.currentToast {
                    ToastView(config: toast)
                        .padding(getPadding(for: toast.position)) // 根据位置设置边距
                        .offset(y: toast.offset) // 支持手动偏移
                        .transition(getTransition(for: toast.position))
                        .zIndex(999)
                        .gesture(
                            DragGesture().onEnded { value in
                                // 这里可以优化：根据位置判断滑动方向
                                if abs(value.translation.height) > 10 {
                                    context.currentToast = nil
                                }
                            }
                        )
                }
            }
            .animation(.spring(), value: context.currentToast)
    }
    
    // 根据位置决定 padding 逻辑
    private func getPadding(for pos: ToastConfig.ToastPosition) -> EdgeInsets {
        switch pos {
        case .top: return .init(top: 20, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return .init(top: 0, leading: 0, bottom: 40, trailing: 0)
        case .center: return .init()
        }
    }
    
    // 根据位置决定进场动画
    private func getTransition(for pos: ToastConfig.ToastPosition) -> AnyTransition {
        switch pos {
        case .top:
            return .move(edge: .top).combined(with: .opacity)
        case .bottom:
            return .move(edge: .bottom).combined(with: .opacity)
        case .center:
            return .opacity.combined(with: .scale)
        }
    }
}

struct ToastView: View {
    @Environment(\.colorScheme) private var colorScheme
    let config: ToastConfig
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = config.icon {
                Image(systemName: icon)
                    .foregroundColor(config.style.color)
            }
            Text(config.message)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
        .background {
            ZStack {
                // 1. 强化底色：在浅色模式下，我们不再使用半透明白，而是稍微带一点点灰（2%的黑）
                // 这样即便在大白背景下也能看出轮廓
                Capsule()
                    .fill(colorScheme == .light ? Color.white : Color(white: 0.1))
                
                // 2. 依然保留材质感
                Capsule()
                    .fill(.ultraThinMaterial)
                
                // 3. 浅色模式下额外垫一层极淡的灰色，增加“厚度感”
                if colorScheme == .light {
                    Capsule()
                        .fill(Color.black.opacity(0.02))
                }
            }
        }
        .clipShape(Capsule())
        // 4. 关键：大幅增强浅色模式下的阴影。
        // 使用更宽的半径 (20) 和更明显的透明度 (0.18)，营造悬浮感
        .shadow(
            color: Color.black.opacity(colorScheme == .light ? 0.18 : 0.5),
            radius: 20,
            x: 0,
            y: 10
        )
        // 5. 增强边框：在浅色模式下，给一个非常淡的灰色描边，强制勾勒出边缘
        .overlay(
            Capsule()
                .stroke(
                    colorScheme == .light ? Color.black.opacity(0.08) : config.style.color.opacity(0.4),
                    lineWidth: 0.5
                )
        )
    }
}
//extension View {
//    /// 在 App 根视图调用一次即可
//    public func installToast() -> some View {
//        self.modifier(ToastContainerModifier())
//    }
//}
