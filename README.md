# LightBurn Tray Monitor

> [!WARNING]
> **LightBurn only reports whether it is *ready to burn* or not — it does not expose a dedicated "currently burning" state.**
> This means any situation that causes LightBurn to report "not ready" (an open dialog, a prompt, a pause, framing mode, etc.) will look identical to an active burn job and may trigger a **false positive** completion notification when that condition clears.
> If you are designing, framing, or otherwise using LightBurn without intending to run a job, use **Notifications: Off** from the tray menu to suppress balloon alerts while keeping the status-colour indicator active.

A Windows system tray application that monitors [LightBurn](https://lightburnsoftware.com/) laser software via UDP and alerts you when a burn job completes.

## Features

- **Tray icon status** — colour-coded dot updates in real time:
  | Colour | Meaning |
  |--------|---------|
  | Grey   | LightBurn unreachable / not running |
  | Green  | Connected, idle |
  | Orange | Burn job in progress |
  | Blue   | Job just completed |
- **Completion alert** — Windows balloon notification + optional sound when a job finishes
- **Custom sound** — drop a `complete.wav` next to the `.exe` for a custom alert; falls back to the Windows *Exclamation* system sound
- **Right-click menu** — toggle sound on/off or exit
- **Single instance** — fails fast if another copy is already running on the same UDP port
- Windows-only (uses `Shell_NotifyIcon`, GDI, `winmm`)

## Requirements

- Windows 10/11
- [LightBurn](https://lightburnsoftware.com/) installed and running with its UDP bridge enabled (default ports `19840`/`19841`)
- [Nim](https://nim-lang.org/) + [wnim](https://github.com/khchen/wnim) (for building from source)

## Building

```powershell
# From the lightburn_tray/ directory
nim c --app:gui -o:lightburn_tray.exe lightburn_tray.nim
```


## Usage

Run `lightburn_tray.exe` — it starts silently in the system tray with no window.

| Action | Result |
|--------|--------|
| Right-click tray icon | Open context menu |
| **Notifications: On/Off** | Toggle balloon alerts (icon colours still update) |
| **Sound: On/Off** | Toggle completion alert sound |
| **Exit** | Remove tray icon and quit |

### Custom alert sound

Place a file named `complete.wav` in the same directory as `lightburn_tray.exe`. Any standard PCM WAV file works. If the file is absent the Windows *Exclamation* system sound is used instead.

## How it works

1. Every **2 seconds** the app sends a `STATUS` UDP packet to LightBurn on port `19840` and reads the response on port `19841`.
2. LightBurn responds with `!` while a job is running and `OK` when idle.
3. When the response transitions from `!` to `OK` the app shows a balloon notification, plays the alert sound, and holds the blue "complete" icon for **8 seconds** before reverting to green (idle).

## Configuration

All tuneable values are `const` at the top of `lightburn_tray.nim`:

| Constant | Default | Description |
|----------|---------|-------------|
| `LBHost` | `127.0.0.1` | LightBurn host |
| `LBOutPort` | `19840` | UDP command port |
| `LBInPort` | `19841` | UDP response port |
| `PollSecs` | `2.0` | Status poll interval (seconds) |
| `CompleteSecs` | `8.0` | How long to show the "complete" icon |
| `RecvTimeoutMs` | `700` | UDP receive timeout (milliseconds) |
