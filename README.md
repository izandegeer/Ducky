# Ducky 🐤

Your MacBook notch mascot. A lightweight macOS menu bar app that monitors your Claude Code sessions and keeps you informed through the notch.

## Features

### Claude Code Monitor
Ducky detects all active Claude Code sessions running in iTerm (or any terminal) and shows their status in real time.

**States detected:**
| Emoji | State | Description |
|---|---|---|
| ⏳ | Working | Claude is processing your request |
| ✅ | Completed | Task finished |
| 🔐 | Permission | Claude needs permission to run a command |
| ⚠️ | Needs attention | Claude has a question or needs input |
| 💤 | Idle | Session is idle |

### Notch Integration
The MacBook notch becomes a live status indicator:
- **Spinner** while Claude is working, with a count of active sessions
- **Checkmark** when a task completes
- **Warning** when Claude needs attention
- Expands with a bounce animation when there's activity

### Toast Notifications
When a session changes state, a brief notification slides down from the notch:
- `✅ club — listo` (task completed)
- `🔐 api — Bash: npm run build` (permission needed, shows the command)
- `⚠️ frontend — Cannot find module 'react'` (needs attention, shows the message)

Click the toast to jump directly to that session in iTerm.

### Hover Preview
Hover over the notch to see all sessions at a glance:
```
⏳ club         trabajando
✅ fctoolshub    listo
💤 api           idle
⚠️ frontend     necesita atención
```

Click any session to switch to its tab in iTerm.

### Menu Bar
Click the duck icon for:
- List of all sessions with emoji status
- **Toggle notch** — hide the notch indicator (useful in class or presentations)
- **Toggle sound** — enable/disable notification sounds
- Quit

## How It Works

### Session Detection
Ducky reads `~/.claude/sessions/*.json` files that Claude Code maintains for each active session. It also checks CPU usage via `ps` to determine if a session is actively working.

### Hooks (Event-Driven)
For precise state detection, Ducky installs Claude Code hooks that write to `~/.ducky/sessions/`. These hooks fire on:
- `UserPromptSubmit` → working
- `Stop` → completed
- `PermissionRequest` → permission needed (includes the command)
- `Notification` → needs attention (includes the message)
- `SessionEnd` → cleanup

### iTerm Integration
When you click a session (in the toast or hover preview), Ducky uses AppleScript to activate iTerm and switch to the correct tab based on the session's TTY.

## Requirements

- macOS 15.0+
- MacBook with notch (menu bar works on any Mac)
- Claude Code CLI installed
- iTerm2 (for click-to-focus feature)

## Build

```bash
xcodebuild -project Ducky.xcodeproj -scheme Ducky -configuration Debug build
```

Or open `Ducky.xcodeproj` in Xcode and press Cmd+B.

## Setup

The hooks are automatically added to `~/.claude/settings.json` on first run. The hook script lives at `~/.ducky/hook.sh`.

## Architecture

```
Ducky/
├── DuckyApp.swift              # Entry point
├── AppDelegate.swift           # Menu bar + notch setup
├── DuckySettings.swift         # User preferences (notch, sound)
├── NotchWindow.swift           # Notch indicator, toast, hover preview
└── Modules/
    └── ClaudeMonitor/
        └── ClaudeMonitor.swift # Session detection + hook integration
```

Modular architecture — ready for future modules beyond Claude monitoring.

## License

MIT
