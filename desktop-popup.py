#!/usr/bin/env python3
"""dsh-thinking-notifier desktop popup (Python 3 + tkinter fallback).

Polls the host-side status endpoint and renders the same bottom-right card
on macOS / Linux / Windows when PowerShell+WPF is not used.
"""
import atexit
import json
import os
import sys
import time
import urllib.request

try:
    import tkinter as tk
except Exception as exc:  # pragma: no cover
    print(f'dsh-thinking-notifier: tkinter unavailable: {exc}', file=sys.stderr)
    raise SystemExit(1)

PORT = 7389
if '--port' in sys.argv:
    try:
        PORT = int(sys.argv[sys.argv.index('--port') + 1])
    except Exception:
        pass

URL = f'http://127.0.0.1:{PORT}/status'

# ---- Single-instance guard (file lock + PID check) ----
LOCK_DIR = os.path.join(os.path.expanduser('~'), '.dsh')
LOCK_PATH = os.path.join(LOCK_DIR, f'tn-popup-{PORT}.lock')


def _is_pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


if os.path.exists(LOCK_PATH):
    try:
        with open(LOCK_PATH, 'r', encoding='utf-8') as f:
            old_pid = int(f.read().strip())
        if _is_pid_alive(old_pid):
            print(f'dsh-thinking-notifier: another popup instance is running (pid={old_pid}), exiting', file=sys.stderr)
            sys.exit(0)
    except Exception:
        pass

os.makedirs(LOCK_DIR, exist_ok=True)
with open(LOCK_PATH, 'w', encoding='utf-8') as f:
    f.write(str(os.getpid()))


def _remove_lock():
    try:
        if os.path.exists(LOCK_PATH):
            with open(LOCK_PATH, 'r', encoding='utf-8') as f:
                if f.read().strip() == str(os.getpid()):
                    os.remove(LOCK_PATH)
    except Exception:
        pass


atexit.register(_remove_lock)

# DeepSeek-style palette
BG = '#1E2235'
FG = '#ECEEF2'
FG_MUTED = '#9AA3B5'
FG_TIME = '#6B7488'
BORDER = '#3A4056'
COLORS = {
    'idle': '#64748B',
    'running': '#4D6BFE',
    'pending': '#F59E0B',
    'done': '#22C55E',
}

root = tk.Tk()
root.overrideredirect(True)
root.attributes('-topmost', True)
root.configure(bg=BG)

card = tk.Frame(root, bg=BG, highlightbackground=BORDER, highlightthickness=1)
card.pack(fill='both', expand=True, padx=1, pady=1)

dot = tk.Canvas(card, width=12, height=12, bg=BG, highlightthickness=0)
dot.create_oval(2, 2, 10, 10, fill=COLORS['idle'], outline='')
dot.grid(row=0, column=0, rowspan=3, padx=(12, 8), pady=10)

status_label = tk.Label(card, text='AI idle', bg=BG, fg=FG, font=('Segoe UI', 10, 'bold'), anchor='w')
status_label.grid(row=0, column=1, sticky='w')
session_label = tk.Label(card, text='', bg=BG, fg=FG_MUTED, font=('Segoe UI', 8), anchor='w', wraplength=280)
session_label.grid(row=1, column=1, sticky='w')
time_label = tk.Label(card, text='', bg=BG, fg=FG_TIME, font=('Segoe UI', 8), anchor='w')
time_label.grid(row=2, column=1, sticky='w')

close_button = tk.Label(card, text='X', bg=BG, fg=FG_MUTED, font=('Segoe UI', 9, 'bold'), cursor='hand2', padx=8, pady=2)
close_button.grid(row=0, column=2, sticky='ne')

state = {
    'last_mode': '',
    'last_session': '',
    'fail_count': 0,
    'tick': 0,
    'last_status': None,
    'dismissed': False,
    'dismissed_mode': '',
    'dismissed_session': '',
    'expanded': False,
    'expanded_at': 0.0,
    'auto_collapse_ms': 5000,
}


def set_dot_color(hex_color):
    dot.itemconfig(1, fill=hex_color)


def show_card():
    root.deiconify()
    root.lift()
    root.attributes('-topmost', True)
    w = 372
    h = 84
    x = root.winfo_screenwidth() - w - 16
    y = max(16, root.winfo_screenheight() - h - 48)
    root.geometry(f'{w}x{h}+{x}+{y}')
    state['expanded'] = True
    state['expanded_at'] = time.time()


def collapse_card():
    root.deiconify()
    root.lift()
    root.attributes('-topmost', True)
    w = 372
    h = 84
    x = root.winfo_screenwidth() - 25
    y = max(16, root.winfo_screenheight() - h - 48)
    root.geometry(f'{w}x{h}+{x}+{y}')
    state['expanded'] = False


def hide_card():
    root.withdraw()
    state['expanded'] = False


def dismiss_card():
    status = state['last_status']
    if status:
        state['dismissed_mode'] = status.get('mode') or ''
        state['dismissed_session'] = status.get('sessionText') or ''
    state['dismissed'] = True
    hide_card()


def render(status):
    state['last_status'] = status
    status_label.config(text=status.get('statusText') or 'AI idle')
    session_label.config(text=status.get('sessionText') or '')
    time_label.config(text=status.get('timeText') or '')
    mode = status.get('mode') or 'idle'
    session = status.get('sessionText') or ''

    should_expand = False
    if mode != state['last_mode'] or session != state['last_session']:
        if mode != 'idle':
            state['dismissed'] = False
            should_expand = True
        if mode == 'pending':
            try:
                root.bell()
            except Exception:
                pass
        elif mode == 'done':
            try:
                root.bell()
            except Exception:
                pass
        state['last_mode'] = mode
        state['last_session'] = session

    if mode == 'idle':
        state['dismissed'] = False

    set_dot_color(COLORS.get(mode, COLORS['idle']))
    if mode == 'pending':
        card.config(highlightbackground=COLORS['pending'])
    else:
        card.config(highlightbackground=BORDER)

    if mode in ('running', 'pending'):
        state['tick'] += 1
        dot.itemconfig(1, fill=COLORS[mode] if state['tick'] % 2 else BG)
    elif mode == 'done':
        dot.itemconfig(1, fill=COLORS['done'])
    else:
        dot.itemconfig(1, fill=COLORS['idle'])

    if mode == 'idle' or state['dismissed']:
        hide_card()
    elif mode in ('pending', 'done'):
        show_card()
    elif mode == 'running':
        if should_expand or root.state() != 'normal':
            show_card()


def poll():
    try:
        with urllib.request.urlopen(URL, timeout=2) as resp:
            status = json.loads(resp.read().decode('utf-8'))
        state['fail_count'] = 0
        render(status)
    except Exception:
        state['fail_count'] += 1
        if state['fail_count'] >= 15:
            root.destroy()
            return

    # Auto-collapse only while the AI is thinking.
    if (
        state['expanded']
        and state['last_status']
        and state['last_status'].get('mode') == 'running'
        and not state['dismissed']
        and (time.time() - state['expanded_at']) * 1000 >= state['auto_collapse_ms']
    ):
        collapse_card()

    root.after(1000, poll)


def on_enter(_event):
    if (
        not state['expanded']
        and not state['dismissed']
        and state['last_status']
        and state['last_status'].get('mode') != 'idle'
    ):
        show_card()


close_button.bind('<Button-1>', lambda _e: dismiss_card())
card.bind('<Enter>', on_enter)
root.bind('<Enter>', on_enter)

root.withdraw()
root.after(0, poll)
root.mainloop()
