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

CodeIsland lives in your MacBook's notch area and shows you what your AI coding agents are doing — in real time. No more switching windows to check if Claude is waiting for approval or if Codex finished its task.

It focuses on **Claude Code** and **Codex**, using Unix socket IPC to display session status, tool calls, permission requests, and recent messages in a compact pixel-art panel.

## Features

- **Notch-native UI** — Expands from the MacBook notch, collapses when idle
- **Focused support** — Built specifically for Claude Code and Codex
- **Live status tracking** — See active sessions, tool calls, and AI responses in real time
- **Permission management** — Approve/deny tool permissions directly from the panel
- **Question answering** — Respond to agent questions without leaving your current app
- **Pixel-art mascots** — Includes dedicated Claude and Codex characters
- **One-click jump** — Click a session to jump to its terminal tab or IDE window
- **Smart suppress** — Tab-level terminal detection: only suppresses notifications when you're looking at the specific session tab, not just the terminal app
- **Sound effects** — Optional 8-bit sound notifications for session events
- **Auto hook install** — Automatically configures Claude Code and Codex hooks, with auto-repair and version tracking
- **Bilingual UI** — English and Chinese, auto-detects system language
- **Multi-display** — Works with external monitors, auto-detects notch displays

## Supported Tools

| | Tool | Events | Jump | Status |
|:---:|------|--------|------|--------|
| <img src="docs/images/mascots/claude.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/claude.png" width="16"> Claude Code | 13 | Terminal tab | Full |
| <img src="docs/images/mascots/codex.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codex.png" width="16"> Codex | 3 | Terminal | Basic |

## Installation

### Homebrew (Recommended)

```bash
brew tap wxtsky/tap
brew install --cask codeisland
```

### Manual Download

1. Go to [Releases](https://github.com/wxtsky/CodeIsland/releases)
2. Download `CodeIsland.dmg`
3. Open the DMG and drag `CodeIsland.app` to your Applications folder
4. Launch CodeIsland — it will automatically install hooks for detected Claude Code and Codex setups

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

CodeIsland provides a 7-tab settings panel:

- **General** — Language, launch at login, display selection
- **Behavior** — Auto-hide, smart suppress, session cleanup
- **Appearance** — Panel height, font size, AI reply lines
- **Mascots** — Preview the Claude and Codex characters and their animations
- **Sound** — 8-bit sound effects for session events
- **Hooks** — View Claude Code / Codex installation status, reinstall or uninstall hooks
- **About** — Version info and links

## Requirements

- macOS 14.0 (Sonoma) or later
- Works best on MacBooks with a notch, but also works on external displays

## Acknowledgments

This project was inspired by [claude-island](https://github.com/farouqaldori/claude-island) by [@farouqaldori](https://github.com/farouqaldori). Thanks for the original idea of bringing AI agent status into the macOS notch.

## Star History

<a href="https://www.star-history.com/?repos=wxtsky%2FCodeIsland&type=date&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=wxtsky/CodeIsland&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=wxtsky/CodeIsland&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=wxtsky/CodeIsland&type=date&legend=top-left" />
 </picture>
</a>

## License

MIT License — see [LICENSE](LICENSE) for details.
