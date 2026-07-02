import Foundation
import TimelineKitCore
import TimelineKitRender

// MARK: - timelinekit-mcp
//
// V8 目标：
// - MCP (Model Context Protocol) server，供 Claude Code / Codex / 端侧 code-agent 调用
// - 暴露少量稳定高层工具（inspect / import_media / apply_edits / render / thumbnail / validate）
// - 不暴露底层任意命令
//
// 当前状态：骨架（M6 正式实现）

print("TimelineKit MCP Server v\(timelineKitCoreVersion)")
print("Status: skeleton — implementation pending (M6)")
