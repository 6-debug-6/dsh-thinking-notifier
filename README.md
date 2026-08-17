# dsh-thinking-notifier

A [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) plugin that shows a small **always-on-top desktop popup** in the bottom-right corner of your screen. It mirrors the AI's thinking status in real time and alerts you when the AI requests permission or finishes thinking — even when you are working in other apps, browsers, or virtual desktops.

> 中文说明见 [README.zh.md](./README.zh.md)

## Features

| State | Popup | Sound |
| --- | --- | --- |
| AI is thinking | DeepSeek-blue pulsing dot + `AI 正在思考…` + elapsed time. Auto-collapses to a 25 px slim right-edge tab after 5 s; hover or click the tab to expand it again | none |
| AI requests permission | Amber pulsing dot + `AI 请求权限` + session/tool name | system Exclamation |
| AI finished thinking | Green dot + `AI 已完成思考`, auto-hides after 12 s | system Asterisk |
| Idle | Hidden | none |

- DeepSeek-style dark card (`#1E2235` / `#4D6BFE`).
- Always-on-top frameless window, bottom-right, visible over any application.
- Auto-collapses into a 25 px slim right-edge tab after 5 s while the AI is thinking, so it stays visible without blocking desktop controls.
- Hover or click the edge tab to expand it manually; new turns, permission requests, and completions expand it automatically.
- Click the **X** button to dismiss the current popup; the next new turn, permission request, or completion will show it again.
- Multiple sessions are summarized automatically.
- The popup process stays alive while DSH runs; it exits ~15 s after the status endpoint becomes unreachable.
- No browser extension required; the popup is a native desktop window.

## How it works

```
DSH process
  └─ lib/index.js (host plugin)
       ├─ listens to session/event: turn/start, turn/end, approval/asked, approval/decided, session/title
       ├─ rebuilds existing session state from ctx.sessions.list() at startup
       ├─ serves a local status JSON at http://127.0.0.1:7389/status
       └─ launches the desktop popup process
             ├─ Windows: desktop-popup.ps1 (PowerShell + WPF)
             └─ macOS/Linux: desktop-popup.py (Python 3 + tkinter)

Desktop popup
  ├─ polls /status every second
  ├─ renders the DeepSeek-style card (running/pending/done/idle)
  ├─ plays a system sound on pending/done transitions
  ├─ auto-collapses to the right edge while running; expands on new states
  └─ hides while idle, keeps running in the background
```

## Installation

### From a local checkout

```sh
cd dsh-thinking-notifier
dsh plugin --profile web add .

# Restart DSH web so the host plugin is loaded
dsh web
```

### From npm (once published)

```sh
dsh plugin --profile web add dsh-thinking-notifier
dsh web
```

### Uninstall

```sh
dsh plugin --profile web remove dsh-thinking-notifier
```

## Configuration

| Environment variable | Default | Description |
| --- | --- | --- |
| `DSH_THINKING_NOTIFIER_PORT` | `7389` | Local status server port. If busy, the next 10 ports are tried. |

## Requirements

- DeepSeek Harness Web UI (`dsh web`)
- Node.js `^22.19.0 || >=24.0.0`
- Windows: Windows 10/11 with PowerShell 5.1+ (built in)
- macOS/Linux: Python 3 with `tkinter`

## Project structure

```
dsh-thinking-notifier/
├── lib/
│   └── index.js          # host plugin: status service + popup launcher
├── desktop-popup.ps1     # Windows native popup (PowerShell + WPF)
├── desktop-popup.py      # macOS/Linux native popup (Python 3 + tkinter)
├── cordis.patch.yml      # DSH bundle patch for persistent mounting
├── package.json          # npm package + dsh.bundle declaration
├── README.md             # English readme
├── README.zh.md          # Chinese readme
├── CHANGELOG.md
├── CONTRIBUTING.md
└── LICENSE
```

## Troubleshooting

Debug logs are written to:

- `~/.dsh/tn-plugin.log` — host plugin lifecycle and launcher status.
- `~/.dsh/tn-launcher.log` — PID of the popup process created by the launcher.
- `~/.dsh/tn-popup-debug.log` — popup script lifecycle and polling errors.

If the popup does not appear after restarting `dsh web`, check those logs first.

## License

[MIT](./LICENSE)
