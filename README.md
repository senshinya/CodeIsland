<h1 align="center">
  <img src="logo.png" width="48" height="48" alt="CodeIsland Logo" valign="middle">&nbsp;
  CodeIsland
</h1>
<p align="center">
  <b>Real-time AI coding agent status panel for macOS Dynamic Island (Notch)</b><br>
  <a href="#installation">Install</a> •
  <a href="#features">Features</a> •
  <a href="#supported-tools">Supported Tools</a> •
  <a href="#build-from-source">Build</a><br>
  English | <a href="README.zh-CN.md">简体中文</a>
</p>

---

<p align="center">
  <img src="docs/images/notch-panel.png" width="700" alt="CodeIsland Panel Preview">
</p>

## What is CodeIsland?

CodeIsland lives in your MacBook's notch area and shows you what your AI coding agents are doing in real time. You can see when Claude is waiting for approval, when Codex is still working, and when a session needs an answer, without bouncing between terminal windows.

It focuses on **Claude Code** and **Codex**, using Unix socket IPC to display session status, tool calls, permission requests, questions, recent messages, and chat history in a compact pixel-art panel.

## Features

- **Notch-native UI** — Expands from the MacBook notch and collapses when idle
- **Focused support** — Built specifically for Claude Code and Codex
- **Live session tracking** — See active sessions, tool calls, approvals, questions, and recent replies in real time
- **Panel actions** — Approve or deny permissions, answer agent questions, and continue a session from the panel when the terminal supports direct input
- **Session chat panel** — View recent chat history with Markdown rendering and keep per-session input drafts when switching views
- **Precise terminal integration** — Jump to and detect visibility for tmux, Kaku, Ghostty, iTerm2, Terminal.app, WezTerm, and kitty sessions
- **Subscription usage** — Show Claude or Codex usage in the expanded bar
- **Customization** — Adjustable notch height modes, panel sizing, content density, hover haptics, mascots, and sound effects
- **Auto hook install** — Automatically configures Claude Code and Codex hooks, with repair support and bridge updates
- **Bilingual UI** — English and Chinese, with automatic language detection
- **Multi-display** — Works with external monitors and notch-aware display selection

## Supported Tools

| | Tool | Hook Support | Panel Actions | Jump / Visibility |
|:---:|------|--------------|---------------|-------------------|
| <img src="docs/images/mascots/claude.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/claude.png" width="16"> Claude Code | Full Claude hook flow, including approvals, questions, tool events, and session lifecycle | Approvals, question replies, chat history, and follow-up messages in supported terminals | Precise terminal tab or pane matching where available |
| <img src="docs/images/mascots/codex.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codex.png" width="16"> Codex | Session lifecycle, prompt, tool, and stop events | Chat history, usage display, and follow-up messages in supported terminals | Terminal session jump plus Codex app activation when applicable |

Supported terminal integrations for jump, visibility detection, and panel message sending currently include `tmux`, `Kaku`, `Ghostty`, `iTerm2`, `Terminal.app`, `WezTerm`, and `kitty`.

## Installation

### Manual Download

1. Go to [Releases](https://github.com/wxtsky/CodeIsland/releases)
2. Download `CodeIsland.dmg`
3. Open the DMG and drag `CodeIsland.app` to your Applications folder
4. Launch CodeIsland — it will automatically install or repair hooks for detected Claude Code and Codex setups

> **Note:** On first launch, macOS may show a security warning. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Build from Source

Requires **macOS 14+** and **Swift 5.9+**.

```bash
git clone https://github.com/wxtsky/CodeIsland.git
cd CodeIsland

# Development (debug build + launch)
swift build && open .build/debug/CodeIsland.app

# Release (universal binary: Apple Silicon + Intel)
./build.sh
open .build/release/CodeIsland.app
```

## How It Works

```text
Claude Code / Codex
  -> Hook event triggered
    -> codeisland-bridge (native Swift binary)
      -> Unix socket -> /tmp/codeisland-<uid>.sock
        -> CodeIsland app receives event
          -> Updates UI in real time
```

CodeIsland installs lightweight hooks into each supported tool's config. When Claude Code or Codex triggers an event, the hook sends a JSON message through a Unix socket. CodeIsland listens on that socket and updates the notch panel instantly.

## Settings

CodeIsland provides an 8-tab settings panel:

- **General** — Language, launch at login, display selection, horizontal drag
- **Behavior** — Auto-hide, smart suppress, collapse-on-mouse-leave, hover haptics, session cleanup
- **Appearance** — Width and height controls, notch height mode, content font size, AI reply lines, expanded usage display
- **Mascots** — Preview Claude and Codex mascots and adjust animation speed
- **Sound** — Built-in or custom sound effects for session and interaction events
- **Shortcuts** — Configure global keyboard shortcuts
- **Hooks** — Check Claude Code / Codex status and reinstall or uninstall hooks
- **About** — Version info and links

## Requirements

- macOS 14.0 (Sonoma) or later
- Works best on MacBooks with a notch, but also works on external displays

## License

MIT License — see [LICENSE](LICENSE) for details.
