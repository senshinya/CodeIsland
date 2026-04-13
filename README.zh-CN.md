<h1 align="center">
  <img src="logo.png" width="48" height="48" alt="CodeIsland Logo" valign="middle"> 
  CodeIsland
</h1>
<p align="center">
  <b>macOS 灵动岛（刘海）实时 AI 编码 Agent 状态面板</b><br>
  <a href="#安装">安装</a> •
  <a href="#功能特性">功能</a> •
  <a href="#支持的工具">支持的工具</a> •
  <a href="#从源码构建">构建</a><br>
  <a href="README.md">English</a> | 简体中文
</p>

---

<p align="center">
  <img src="docs/images/notch-panel.png" width="700" alt="CodeIsland Panel Preview">
</p>

## CodeIsland 是什么？

CodeIsland 住在你 MacBook 的刘海区域，实时展示 AI 编码 Agent 的工作状态。Claude 在等审批、Codex 还在跑、会话需要你回答问题，这些都能直接在刘海面板里看到，不用来回切终端窗口。

它专注支持 **Claude Code** 和 **Codex**，通过 Unix socket IPC 在刘海面板中展示会话状态、工具调用、权限请求、提问、最近消息和聊天记录，全部放进一个紧凑的像素风面板里。

## 功能特性

- **刘海原生 UI** — 从 MacBook 刘海处展开，空闲时自动收起
- **聚焦双工具支持** — 专门面向 Claude Code 和 Codex
- **实时状态追踪** — 实时查看活跃会话、工具调用、审批、提问和最近回复
- **面板内操作** — 可直接审批权限、回答问题，并在支持的终端里继续发送消息
- **会话聊天面板** — 查看最近聊天记录，支持 Markdown 渲染，并按会话保存未发送草稿
- **精确终端集成** — 支持 tmux、Kaku、Ghostty、iTerm2、Terminal.app、WezTerm 和 kitty 的跳转与可见性识别
- **订阅用量展示** — 在展开栏查看 Claude 或 Codex 用量
- **外观与交互可调** — 支持 notch 高度模式、面板尺寸、内容密度、悬停触觉反馈、角色和音效
- **自动安装 Hook** — 自动为检测到的 Claude Code 和 Codex 配置 hooks，支持修复和 bridge 更新
- **中英双语** — 支持中文和英文，自动跟随系统语言
- **多显示器** — 支持外接显示器，也支持按刘海屏幕选择显示位置

## 支持的工具

|                                                       | 工具                                                                                   | Hook 支持                               | 面板内操作                         | 跳转 / 可见性                    |
|:-----------------------------------------------------:| ------------------------------------------------------------------------------------ | ------------------------------------- | ----------------------------- | --------------------------- |
| <img src="docs/images/mascots/claude.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/claude.png" width="16"> Claude Code | 完整 Claude hook 流程，包含审批、提问、工具事件和会话生命周期 | 审批、回答问题、查看聊天记录，以及在支持终端里继续发送消息 | 在可支持的终端里精确匹配标签页或 pane       |
| <img src="docs/images/mascots/codex.gif" width="28">  | <img src="Sources/CodeIsland/Resources/cli-icons/codex.png" width="16"> Codex        | 会话生命周期、用户消息、工具事件和停止事件                 | 查看聊天记录、展开栏用量，以及在支持终端里继续发送消息   | 支持跳转到终端会话，必要时也可激活 Codex App |

当前支持 `tmux`、`Kaku`、`Ghostty`、`iTerm2`、`Terminal.app`、`WezTerm` 和 `kitty` 的跳转、可见性判断和 message bar 发送能力。

## 安装

### 手动下载

1. 前往 [Releases](https://github.com/wxtsky/CodeIsland/releases) 页面
2. 下载 `CodeIsland.dmg`
3. 打开 DMG，将 `CodeIsland.app` 拖入「应用程序」文件夹
4. 启动 CodeIsland — 会自动为检测到的 Claude Code 和 Codex 安装或修复 hooks

> **提示：** 首次启动时 macOS 可能弹出安全提示，前往 **系统设置 → 隐私与安全性** 点击 **仍要打开** 即可。

### 从源码构建

需要 **macOS 14+** 和 **Swift 5.9+**。

```bash
git clone https://github.com/wxtsky/CodeIsland.git
cd CodeIsland

# 开发模式（debug 构建 + 启动）
swift build && open .build/debug/CodeIsland.app

# 发布模式（通用二进制：Apple Silicon + Intel）
./build.sh
open .build/release/CodeIsland.app
```

## 工作原理

```text
Claude Code / Codex
  -> 触发 Hook 事件
    -> codeisland-bridge（原生 Swift 二进制）
      -> Unix socket -> /tmp/codeisland-<uid>.sock
        -> CodeIsland 接收事件
          -> 实时更新 UI
```

CodeIsland 会在每个受支持工具的配置中安装轻量级 hooks。当 Claude Code 或 Codex 触发事件（会话开始、工具调用、权限请求等）时，hook 会通过 Unix socket 发送 JSON 消息。CodeIsland 监听此 socket 并即时更新刘海面板。

## 设置

CodeIsland 提供 8 个标签页的设置面板：

- **通用** — 语言、登录时启动、显示器选择、水平拖动
- **行为** — 自动隐藏、智能抑制、离开收起、悬停触觉反馈、会话清理
- **外观** — 宽高设置、notch 高度模式、内容字体大小、AI 回复行数、展开栏用量显示
- **角色** — 预览 Claude 和 Codex 角色，并调整动画速度
- **声音** — 为会话事件和交互事件设置内置或自定义音效
- **快捷键** — 配置全局快捷键
- **Hooks** — 查看 Claude Code / Codex 状态，并重新安装或卸载 hooks
- **关于** — 版本信息和链接

## 系统要求

- macOS 14.0（Sonoma）或更高版本
- 在带刘海的 MacBook 上效果最佳，也支持外接显示器

## 许可证

MIT 许可证 — 详见 [LICENSE](LICENSE)。
