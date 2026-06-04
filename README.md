# LightBurn Tray Monitor

> [!WARNING]
> **LightBurn only reports whether it is *ready to burn* or not — it does not expose a dedicated "currently burning" state.**
> This means any situation that causes LightBurn to report "not ready" (an open dialog, a prompt, a pause, framing mode, etc.) will look identical to an active burn job and may trigger a **false positive** completion notification when that condition clears.
> If you are designing, framing, or otherwise using LightBurn without intending to run a job, use **Notifications: Off** from the tray menu to suppress balloon alerts while keeping the status-colour indicator active.

A cross-platform menu-bar / system-tray application that monitors [LightBurn](https://lightburnsoftware.com/) laser software via UDP and alerts you when a burn job completes. Supports **Windows** (system tray) and **macOS** (menu bar).

## Features

- **Status icon** — colour-coded dot updates in real time:
  | Colour | Meaning |
  |--------|---------|
  | Grey   | LightBurn unreachable / not running |
  | Green  | Connected, idle |
  | Orange | Burn job in progress |
  | Blue   | Job just completed |
- **Completion alert** — system notification when a job finishes (balloon on Windows, Notification Centre on macOS)
- **Alert sound** — plays on job completion; drop a `complete.wav` next to the binary for a custom sound, otherwise falls back to the system default (*Exclamation* on Windows, *Glass* on macOS)
- **Email alert** — optional SMTP email sent on job completion (configurable in `lightburn_tray.json`)
- **Menu** — right-click (Windows) or click the dot (macOS) for a context menu:
  - Toggle notifications on/off
  - Toggle sound on/off
  - Toggle email alert on/off
  - Exit
- **JSON configuration** — all settings read from `lightburn_tray.json` at startup; defaults apply if the file is absent
- **Single instance guard** — fails fast if another copy is already bound to the same UDP port

## How it works

1. Every **2 seconds** the app sends a `STATUS` UDP packet to LightBurn on port `19840` and reads the response on port `19841`.
2. LightBurn responds with `!` while a job is running and `OK` when idle/ready.
3. When the response transitions from `!` → `OK` the app triggers the notification, plays the alert sound, sends an email (if configured), and holds the blue "complete" icon for **8 seconds** before reverting to green.

## Configuration

Settings are read from `lightburn_tray.json` placed next to the binary (or inside `Contents/Resources/` on macOS). All keys are optional — omitted values use the defaults shown below.

```json
{
  "lbHost":        "127.0.0.1",
  "lbOutPort":     19840,
  "lbInPort":      19841,
  "pollSecs":      2.0,
  "completeSecs":  8.0,
  "recvTimeoutMs": 700,
  "soundOn":       true,
  "notifyOn":      true,
  "emailOn":       false,
  "smtp": {
    "host":     "smtp.example.com",
    "port":     587,
    "useSsl":   false,
    "username": "",
    "password": "",
    "fromAddr": "lightburn@example.com",
    "toAddrs":  ["you@example.com"]
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `lbHost` | `127.0.0.1` | LightBurn host |
| `lbOutPort` | `19840` | UDP command port |
| `lbInPort` | `19841` | UDP response port |
| `pollSecs` | `2.0` | Status poll interval (seconds) |
| `completeSecs` | `8.0` | How long to hold the "complete" icon before reverting to idle |
| `recvTimeoutMs` | `700` | UDP receive timeout (milliseconds) |
| `soundOn` | `true` | Play alert sound on completion |
| `notifyOn` | `true` | Show system notification on completion |
| `emailOn` | `false` | Send email alert on completion |
| `smtp.host` | — | SMTP server hostname |
| `smtp.port` | `587` | SMTP port |
| `smtp.useSsl` | `false` | Use SSL (true) or STARTTLS (false) |
| `smtp.username` | — | SMTP login username |
| `smtp.password` | — | SMTP login password |
| `smtp.fromAddr` | — | Sender email address |
| `smtp.toAddrs` | — | Array of recipient email addresses |

### Custom alert sound

Place a file named `complete.wav` next to the binary (or in `Contents/Resources/` on macOS). Any standard PCM WAV file works. If absent, the system default sound is used.

---

## Building

### macOS

**Requirements**

- macOS 10.13+
- [Nim](https://nim-lang.org/) (install via [choosenim](https://github.com/dom96/choosenim))
- Xcode Command Line Tools (`xcode-select --install`)

**Build**

```sh
bash build.sh
```

This compiles a release binary and packages it into `LightBurnMonitor.app`. The script also copies `lightburn_tray.json` and `complete.wav` (if present) into the bundle's `Contents/Resources/`.

**Run**

```sh
open LightBurnMonitor.app
```

> [!IMPORTANT]
> Always launch via `open` or double-click in Finder — **not** by running the binary directly from the terminal. macOS requires a proper `.app` bundle to grant menu-bar (window server) access. `LSUIElement = YES` in `Info.plist` keeps it out of the Dock and app switcher.

The settings file and sound file are looked up from:
- `Contents/Resources/lightburn_tray.json`
- `Contents/Resources/complete.wav`

---

### Windows

**Requirements**

- Windows 10/11
- [Nim](https://nim-lang.org/)
- [wnim](https://github.com/khchen/wnim) (`nimble install wnim`)

**Build**

```powershell
nim c -d:ssl lightburn_tray.nim
```

This produces `lightburn_tray.exe`. Place `lightburn_tray.json` and `complete.wav` in the same directory as the `.exe`.

**Run**

Double-click `lightburn_tray.exe` — it starts silently with no window and appears in the system tray.

---

## Usage

| Action | Result |
|--------|--------|
| Click / right-click tray icon | Open context menu |
| **Notifications: On/Off** | Toggle system notifications (icon colours still update) |
| **Sound: On/Off** | Toggle completion alert sound |
| **Email Alert: On/Off** | Toggle email notification |
| **Exit** | Remove icon and quit |
