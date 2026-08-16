# dsh-thinking-notifier

一个 [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) 插件：在屏幕**右下角**显示一个**置顶桌面悬浮窗**，实时显示 AI 思考状态；当 AI 请求权限或完成思考时，弹出提醒并播放系统提示音。即使你切到其它网页、桌面或桌面应用，也能看到统一风格的弹窗。

> English version: [README.md](./README.md)

## 功能

| 状态 | 悬浮窗 | 声音 |
| --- | --- | --- |
| AI 正在思考 | DeepSeek 蓝呼吸点 + `AI 正在思考…` + 计时 | 无 |
| AI 请求权限 | 琥珀色呼吸点 + `AI 请求权限` + 会话/工具名 | 系统 Exclamation |
| AI 完成思考 | 绿色点 + `AI 已完成思考`，12 秒后自动隐藏 | 系统 Asterisk |
| 空闲 | 自动隐藏 | 无 |

- DeepSeek 风格深色卡片（`#1E2235` / `#4D6BFE`）。
- 无边框置顶窗口，右下角显示，覆盖所有应用。
- 点击右上角 **X** 可提前关闭当前弹窗；后续新的思考、权限请求或完成状态会重新显示。
- 多个会话自动汇总显示。
- 弹窗进程在 DSH 运行期间常驻；状态服务不可达约 15 秒后自动退出。
- 不需要浏览器扩展，弹窗是原生桌面窗口。

## 工作原理

```
DSH 进程
  └─ lib/index.js（主机插件）
       ├─ 监听 session/event：turn/start、turn/end、approval/asked、approval/decided、session/title
       ├─ 启动时从 ctx.sessions.list() 重建已有会话状态
       ├─ 在 http://127.0.0.1:7389/status 提供本地状态 JSON
       └─ 拉起桌面弹窗进程
             ├─ Windows: desktop-popup.ps1（PowerShell + WPF）
             └─ macOS/Linux: desktop-popup.py（Python 3 + tkinter）

桌面弹窗
  ├─ 每 1 秒轮询 /status
  ├─ 渲染 DeepSeek 风格卡片（running/pending/done/idle）
  ├─ pending/done 状态切换时播放系统提示音
  └─ 空闲时隐藏，进程保持运行
```

## 安装

### 本地安装

```sh
cd dsh-thinking-notifier
dsh plugin --profile web add .

# 重启 DSH Web 以加载主机插件
dsh web
```

### 发布到 npm 后安装

```sh
dsh plugin --profile web add dsh-thinking-notifier
dsh web
```

### 卸载

```sh
dsh plugin --profile web remove dsh-thinking-notifier
```

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DSH_THINKING_NOTIFIER_PORT` | `7389` | 本地状态服务端口，被占用时自动顺延 10 个端口 |

## 环境要求

- DeepSeek Harness Web UI（`dsh web`）
- Node.js `^22.19.0 || >=24.0.0`
- Windows：Win10/11 自带 PowerShell 5.1+
- macOS/Linux：Python 3 + `tkinter`

## 项目结构

```
dsh-thinking-notifier/
├── lib/
│   └── index.js          # 主机插件：状态服务 + 弹窗拉起
├── desktop-popup.ps1     # Windows 原生弹窗（PowerShell + WPF）
├── desktop-popup.py      # macOS/Linux 原生弹窗（Python 3 + tkinter）
├── cordis.patch.yml      # DSH bundle patch，用于持久挂载
├── package.json          # npm 包 + dsh.bundle 声明
├── README.md             # 英文说明
├── README.zh.md          # 中文说明
├── CHANGELOG.md
├── CONTRIBUTING.md
└── LICENSE
```

## 排错

调试日志位置：

- `~/.dsh/tn-plugin.log` — 主机插件生命周期与启动器状态。
- `~/.dsh/tn-launcher.log` — 启动器创建的弹窗进程 PID。
- `~/.dsh/tn-popup-debug.log` — 弹窗脚本生命周期与轮询错误。

重启 `dsh web` 后如果看不到弹窗，请先查看以上日志。

## License

[MIT](./LICENSE)
