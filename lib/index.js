/**
 * dsh-thinking-notifier 主机半边
 *
 * 在 DSH 进程内监听 session/event，维护每个会话的思考/权限状态，
 * 并通过 127.0.0.1 上的本地 HTTP 服务把状态暴露给桌面悬浮窗。
 * 同时负责拉起桌面悬浮窗进程（Windows 使用 PowerShell+WPF，其他平台使用 Python+tkinter）。
 *
 * 状态来源：
 *   - session/event 事件流：turn/start、turn/end、approval/asked、approval/decided、session/title 等
 *   - ctx.sessions.list()：启动时重建已有会话的状态
 */
import { createServer } from 'node:http'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

export const name = 'dsh-thinking-notifier'
export const inject = ['sessions', 'webServer']

const DEFAULT_PORT = Number(process.env.DSH_THINKING_NOTIFIER_PORT || 7389)
const DEFAULT_WEB_PORT = 3080
const DONE_SHOW_MS = 12000

const __dirname = dirname(fileURLToPath(import.meta.url))
const POPUP_PS1 = join(__dirname, '..', 'desktop-popup.ps1')
const POPUP_PY = join(__dirname, '..', 'desktop-popup.py')

let httpServer = null
let popupProcess
let updateTimer = null
let disposed = false

// ---- 简易文件日志（用于排查桌面弹窗拉起问题） ----
import { appendFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join as logJoin } from 'node:path'

function logLine(msg) {
  try {
    const dir = logJoin(homedir(), '.dsh')
    mkdirSync(dir, { recursive: true })
    appendFileSync(logJoin(dir, 'tn-plugin.log'), `[${new Date().toISOString()}] ${msg}
`)
  } catch (_err) { /* 日志失败不影响插件 */ }
}

/** @type {Map<string, any>} */
const sessionStates = new Map()
/** @type {Map<string, number>} */
const doneAt = new Map()
/** @type {Map<string, number>} */
const runningSince = new Map()

let status = {
  ok: true,
  mode: 'idle',
  statusText: 'AI 空闲',
  sessionText: '',
  timeText: '',
  pendingKind: undefined,
  pendingTool: undefined,
  runningSince: null,
  doneAt: null,
  appUrl: `http://127.0.0.1:${DEFAULT_WEB_PORT}`,
  now: Date.now(),
}

function ensureSession(id) {
  let s = sessionStates.get(id)
  if (s === undefined) {
    s = {
      id,
      title: String(id),
      running: false,
      runningSince: undefined,
      // pendingApprovals: approvalId -> { toolName, reason, time }
      pendingApprovals: new Map(),
    }
    sessionStates.set(id, s)
  }
  return s
}

function applyEvent(sessionId, event) {
  if (!event || typeof event.type !== 'string') return
  const s = ensureSession(sessionId)
  const time = typeof event.time === 'number' ? event.time : Date.now()
  const data = event.data || {}

  switch (event.type) {
    case 'turn/start':
      if (!s.running) {
        s.running = true
        s.runningSince = time
        runningSince.set(sessionId, time)
      }
      break
    case 'step/start':
      // 兜底：正常 turn/start 已设置 running，此处避免某些异常事件序列
      if (!s.running) {
        s.running = true
        s.runningSince = time
        runningSince.set(sessionId, time)
      }
      break
    case 'turn/end':
      if (s.running) {
        s.running = false
        s.runningSince = undefined
        runningSince.delete(sessionId)
        doneAt.set(sessionId, Date.now())
      }
      break
    case 'approval/asked': {
      const id = data.id
      if (id === undefined) break
      s.pendingApprovals.set(String(id), {
        toolName: data.toolName,
        reason: data.reason,
        time,
      })
      break
    }
    case 'approval/decided': {
      const id = data.id
      if (id === undefined) break
      s.pendingApprovals.delete(String(id))
      break
    }
    case 'session/title':
      if (typeof data.title === 'string' && data.title !== '') {
        s.title = data.title
      }
      break
    default:
      break
  }
}

/** 启动时从已有会话重建状态（正向扫描，事件是 append-only 的） */
function rebuildFromSessions(sessions) {
  if (!sessions || typeof sessions.list !== 'function') return
  for (const session of sessions.list()) {
    const events = session.events
    if (!Array.isArray(events)) continue
    for (const event of events) {
      applyEvent(session.id, event)
    }
  }
}

function pendingSummary(s) {
  if (s.pendingApprovals.size === 0) return undefined
  const first = s.pendingApprovals.values().next().value
  return {
    kind: 'approval',
    toolName: first && first.toolName,
    reason: first && first.reason,
    count: s.pendingApprovals.size,
  }
}

function updateStatus() {
  const now = Date.now()
  const runningIds = []
  const pendingIds = []
  const sessions = []

  for (const s of sessionStates.values()) {
    const pending = pendingSummary(s)
    sessions.push({
      id: s.id,
      title: s.title,
      running: s.running,
      pendingKind: pending ? 'approval' : undefined,
      pendingTool: pending ? pending.toolName : undefined,
      pendingCount: pending ? pending.count : 0,
    })
    if (s.running) runningIds.push(s.id)
    if (pending) pendingIds.push(s.id)
  }

  // 清理过期 done 标记
  let latestDoneAt = null
  for (const [id, t] of doneAt) {
    if (now - t < DONE_SHOW_MS) {
      if (latestDoneAt === null || t > latestDoneAt) latestDoneAt = t
    } else {
      doneAt.delete(id)
    }
  }

  let mode = 'idle'
  let statusText = 'AI 空闲'
  let sessionText = ''
  let timeText = ''
  let pendingKind
  let pendingTool

  if (pendingIds.length > 0) {
    mode = 'pending'
    pendingKind = 'approval'
    const names = pendingIds.map(id => {
      const s = sessionStates.get(id)
      const p = pendingSummary(s)
      return (p && p.toolName) ? p.toolName : (s ? s.title : id)
    })
    statusText = pendingIds.length > 1 ? `AI 请求权限 · ${pendingIds.length} 个会话` : 'AI 请求权限'
    sessionText = names.join('、')
    const first = sessionStates.get(pendingIds[0])
    const p = first ? pendingSummary(first) : undefined
    pendingTool = p ? p.toolName : undefined
  } else if (runningIds.length > 0) {
    mode = 'running'
    statusText = runningIds.length > 1 ? `AI 正在思考 · ${runningIds.length} 个会话` : 'AI 正在思考…'
    const names = runningIds.map(id => {
      const s = sessionStates.get(id)
      return s ? (s.title || s.id) : id
    })
    sessionText = names.join('、')
    let earliest = Infinity
    for (const id of runningIds) {
      const t = runningSince.get(id)
      if (t !== undefined && t < earliest) earliest = t
    }
    if (earliest !== Infinity) {
      const sec = Math.max(0, Math.floor((now - earliest) / 1000))
      const m = Math.floor(sec / 60)
      const s = sec % 60
      timeText = `${m < 10 ? '0' + m : String(m)}:${s < 10 ? '0' + s : String(s)}`
    }
  } else if (latestDoneAt !== null) {
    mode = 'done'
    statusText = 'AI 已完成思考'
    sessionText = ''
    timeText = ''
  }

  status = {
    ok: true,
    mode,
    statusText,
    sessionText,
    timeText,
    pendingKind,
    pendingTool,
    runningSince: runningIds.length > 0 ? Math.min(...runningIds.map(id => runningSince.get(id) ?? now)) : null,
    doneAt: latestDoneAt,
    appUrl: status.appUrl,
    now,
  }
}

function startServer(port) {
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8')
    res.setHeader('Access-Control-Allow-Origin', '*')
    res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS')
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
    if (req.method === 'OPTIONS') {
      res.statusCode = 204
      res.end()
      return
    }
    if (req.method === 'GET' && (req.url === '/status' || req.url === '/')) {
      res.statusCode = 200
      res.end(JSON.stringify(status))
      return
    }
    if (req.method === 'GET' && req.url === '/health') {
      res.statusCode = 200
      res.end(JSON.stringify({ ok: true }))
      return
    }
    res.statusCode = 404
    res.end(JSON.stringify({ ok: false, error: 'not found' }))
  })

  return new Promise((resolve) => {
    const onError = (err) => {
      if (err && err.code === 'EADDRINUSE') {
        if (port < DEFAULT_PORT + 10) {
          port += 1
          server.listen(port, '127.0.0.1')
          return
        }
        console.warn('[dsh-thinking-notifier] 本地状态端口均被占用，桌面悬浮窗不可用')
        resolve(null)
        return
      }
      console.warn('[dsh-thinking-notifier] 状态服务启动失败:', err)
      resolve(null)
    }
    server.on('error', onError)
    server.once('listening', () => {
      server.removeListener('error', onError)
      resolve(server)
    })
    server.listen(port, '127.0.0.1')
  })
}

function spawnPopup(port) {
  if (popupProcess !== undefined) return
  logLine(`spawnPopup: platform=${process.platform} port=${port} ps1=${POPUP_PS1}`)
  try {
    if (process.platform === 'win32') {
      // Clean up any existing popup instances first so multiple DSH restarts
      // never stack overlapping popup windows.
      spawnSync('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command',
        "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*desktop-popup.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }",
      ], { stdio: 'ignore', windowsHide: true })

      // DSH 主进程直接 spawn 的 PowerShell 子进程会立即退出（原因与 DSH 的
      // 进程/窗口站环境有关）。这里改为 spawn 一个一次性启动器，由启动器通过
      // Start-Process 拉起真正独立运行的弹窗进程，绕过该限制。
      const launchArgs = `'-NoProfile','-ExecutionPolicy','Bypass','-File','${POPUP_PS1}','-Port','${String(port)}'`
      const launcherLog = logJoin(homedir(), '.dsh', 'tn-launcher.log')
      popupProcess = spawn('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command',
        `try { Start-Process powershell -ArgumentList ${launchArgs} -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id | Out-File -FilePath '${launcherLog}' -Encoding utf8 } catch { $_ | Out-File -FilePath '${launcherLog}' -Encoding utf8 }`,
      ], { stdio: 'ignore', windowsHide: true })
    } else {
      const python = process.env.PYTHON || 'python3'
      popupProcess = spawn(python, [POPUP_PY, '--port', String(port)], { stdio: 'ignore' })
    }
    popupProcess.on('error', (err) => {
      logLine(`popup error: ${err && err.message ? err.message : err}`)
      console.warn('[dsh-thinking-notifier] 桌面悬浮窗进程启动失败:', err && err.message ? err.message : err)
      popupProcess = undefined
    })
    popupProcess.on('exit', (code, signal) => {
      logLine(`popup exit: code=${code} signal=${signal}`)
      popupProcess = undefined
    })
  } catch (err) {
    logLine(`popup spawn throw: ${err && err.message ? err.message : err}`)
    console.warn('[dsh-thinking-notifier] 无法拉起桌面悬浮窗:', err && err.message ? err.message : err)
    popupProcess = undefined
  }
}

function dispose() {
  if (disposed) return
  disposed = true
  if (updateTimer !== null) { clearInterval(updateTimer); updateTimer = null }
  if (popupProcess !== undefined) {
    try { popupProcess.kill() } catch (_err) { /* 忽略 */ }
    popupProcess = undefined
  }
  if (httpServer !== null) {
    try { httpServer.close() } catch (_err) { /* 忽略 */ }
    httpServer = null
  }
  sessionStates.clear()
  doneAt.clear()
  runningSince.clear()
}

export function apply(ctx) {
  logLine(`apply: pid=${process.pid} cwd=${process.cwd()}`)
  const sessions = ctx.sessions
  const webServer = ctx.webServer
  let webPort = DEFAULT_WEB_PORT
  try {
    if (webServer && typeof webServer.port === 'number') webPort = webServer.port
  } catch (_err) { /* 使用默认端口 */ }
  status.appUrl = `http://127.0.0.1:${webPort}`

  // 1. 从已有会话重建状态
  rebuildFromSessions(sessions)

  // 2. 监听后续事件
  ctx.on('session/event', (session, event) => {
    if (disposed) return
    try {
      applyEvent(session.id, event)
      updateStatus()
    } catch (err) {
      console.warn('[dsh-thinking-notifier] 处理 session/event 失败:', err)
    }
  })

  // 3. 启动本地状态服务并拉起桌面悬浮窗
  const tryStart = async () => {
    const server = await startServer(DEFAULT_PORT)
    if (server === null) return
    httpServer = server
    const addr = server.address()
    const port = addr && typeof addr === 'object' ? addr.port : DEFAULT_PORT
    updateStatus()
    updateTimer = setInterval(() => {
      if (disposed) return
      updateStatus()
    }, 1000)
    spawnPopup(port)
  }
  void tryStart()

  // 4. 注册清理
  ctx.effect(() => () => dispose(), 'dsh-thinking-notifier: 桌面悬浮窗')
}
