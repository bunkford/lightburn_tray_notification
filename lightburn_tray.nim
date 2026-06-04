# lightburn_tray.nim
# ─────────────────────────────────────────────────────────────────────────────
# Windows system tray monitor for LightBurn laser software.
#
# - Polls LightBurn via UDP (configurable ports) every N seconds
# - Shows job status as a coloured dot in the system tray
#   · Grey   = LightBurn unreachable
#   · Green  = Idle (no active job)
#   · Orange = Burning (job in progress)
#   · Blue   = Job just completed
# - Optionally plays a loud alert sound when a job finishes
#   (place a "complete.wav" next to the .exe to use a custom sound)
# - Optionally sends an email notification when a job finishes
# - Settings loaded from lightburn_tray.json in the application directory
# - Right-click tray icon for menu (toggle sound / notifications / email / exit)
#
# Compile:  nim c -d:ssl lightburn_tray.nim
# macOS:    see lightburn_tray_mac.nim
# ─────────────────────────────────────────────────────────────────────────────

when not defined(windows):
  {.error: "lightburn_tray is Windows-only. For macOS use: nim c -d:ssl lightburn_tray_mac.nim"}

# GUI subsystem — suppresses the console window on Windows.
{.passL: "-mwindows".}

import ./lightburn_shared
import std/os
import wnim
import winim/[winstr, utils]
import winim/inc/[shellapi, winuser, windef, wingdi, mmsystem]

# ─── Win32 / tray identifiers ─────────────────────────────────────────────────
const
  WM_TRAYICON    = WM_APP + 1
  TRAY_UID       = 1
  TIMER_POLL     = 1
  TIMER_COMPLETE = 2
  ID_SOUND        = 1001
  ID_NOTIFY       = 1003
  ID_EMAIL        = 1004
  ID_TEST_EMAIL   = 1005
  ID_EXIT         = 1002

# ─── Windows-only extra state ─────────────────────────────────────────────────
var
  gFrame: wFrame
  gNid:   NOTIFYICONDATAW
  gIcons: array[BurnStatus, HICON]

# ─── Helpers ──────────────────────────────────────────────────────────────────
proc setWcharArray[N: static int](arr: var array[N, WCHAR], s: string) =
  ## Copy a Nim string into a fixed-length WCHAR array (null-terminated).
  zeroMem(addr arr[0], N * 2)
  if s.len == 0: return
  let ws = newWideCString(s)
  let n  = min(s.len, N - 1)
  for i in 0 ..< n:
    arr[i] = cast[WCHAR](ws[i])

# ─── Coloured dot icons ───────────────────────────────────────────────────────
proc createDotIcon(r, g, b: int): HICON =
  ## Draw a 16×16 filled coloured circle and return it as an HICON.
  let color    = RGB(r, g, b)
  let screenDC = GetDC(0)
  let memDC    = CreateCompatibleDC(screenDC)
  let hbmColor = CreateCompatibleBitmap(screenDC, 16, 16)
  # Monochrome mask: all zeros = fully opaque
  let hbmMask  = CreateBitmap(16, 16, 1, 1, nil)

  let oldBm = SelectObject(memDC, hbmColor)

  # Black background
  let bgBrush = CreateSolidBrush(RGB(0, 0, 0))
  var rc: RECT
  rc.right = 16; rc.bottom = 16
  FillRect(memDC, addr rc, bgBrush)
  DeleteObject(bgBrush)

  # Filled ellipse — use same-colour pen so the outline is invisible
  let fgPen    = CreatePen(0, 1, color)  # 0 = PS_SOLID
  let fgBrush  = CreateSolidBrush(color)
  let oldPen   = SelectObject(memDC, fgPen)
  let oldBrush = SelectObject(memDC, fgBrush)
  Ellipse(memDC, 1, 1, 15, 15)
  SelectObject(memDC, oldBrush)
  SelectObject(memDC, oldPen)
  DeleteObject(fgBrush)
  DeleteObject(fgPen)

  SelectObject(memDC, oldBm)

  # Fill monochrome mask solid black (fully opaque icon)
  let maskDC    = CreateCompatibleDC(screenDC)
  let oldMask   = SelectObject(maskDC, hbmMask)
  let maskBrush = CreateSolidBrush(0)   # explicit black — avoids stock-object ambiguity
  FillRect(maskDC, addr rc, maskBrush)
  DeleteObject(maskBrush)
  SelectObject(maskDC, oldMask)
  DeleteDC(maskDC)

  var ii = ICONINFO(
    fIcon:    TRUE,
    xHotspot: 8,
    yHotspot: 8,
    hbmMask:  hbmMask,
    hbmColor: hbmColor,
  )
  result = CreateIconIndirect(addr ii)

  DeleteObject(hbmColor)
  DeleteObject(hbmMask)
  DeleteDC(memDC)
  ReleaseDC(0, screenDC)

proc createIcons() =
  gIcons[bsDisconnected] = createDotIcon(100, 100, 100)  # grey
  gIcons[bsIdle]         = createDotIcon(0, 200, 80)     # green
  gIcons[bsBurning]      = createDotIcon(255, 140, 0)    # orange
  gIcons[bsComplete]     = createDotIcon(0, 160, 255)    # blue

proc destroyIcons() =
  for st in BurnStatus:
    if gIcons[st] != 0:
      DestroyIcon(gIcons[st])

# ─── Tray icon management ─────────────────────────────────────────────────────
proc updateTrayIcon() =
  gNid.uFlags = NIF_ICON or NIF_TIP
  gNid.hIcon  = gIcons[gStatus]
  setWcharArray(gNid.szTip, statusLabel(gStatus))
  discard Shell_NotifyIcon(NIM_MODIFY, addr gNid)

proc showBalloon(title, msg: string) =
  ## Show a Windows balloon notification from the tray icon.
  gNid.uFlags = NIF_INFO
  setWcharArray(gNid.szInfoTitle, title)
  setWcharArray(gNid.szInfo, msg)
  gNid.dwInfoFlags       = NIIF_INFO
  gNid.union1.uTimeout   = 6000
  discard Shell_NotifyIcon(NIM_MODIFY, addr gNid)

proc initTray(hwnd: HWND) =
  zeroMem(addr gNid, sizeof(gNid))
  gNid.cbSize           = DWORD sizeof(NOTIFYICONDATAW)
  gNid.hWnd             = hwnd
  gNid.uID              = TRAY_UID
  gNid.uFlags           = NIF_ICON or NIF_MESSAGE or NIF_TIP
  gNid.uCallbackMessage = WM_TRAYICON
  gNid.hIcon            = gIcons[bsDisconnected]
  setWcharArray(gNid.szTip, AppName)
  discard Shell_NotifyIcon(NIM_ADD, addr gNid)

proc removeTray() =
  discard Shell_NotifyIcon(NIM_DELETE, addr gNid)

# ─── Sound ────────────────────────────────────────────────────────────────────
proc playAlert() =
  if not gSoundOn: return
  # Prefer complete.wav in the same directory as the executable
  let wav = getAppDir() / "complete.wav"
  if fileExists(wav):
    discard PlaySoundW(newWideCString(wav), 0, SND_FILENAME or SND_ASYNC)
  else:
    # Fall back to the Windows "Exclamation" system sound
    discard PlaySoundW(newWideCString("SystemExclamation"), 0, SND_ALIAS or SND_ASYNC)

# ─── Right-click context menu ─────────────────────────────────────────────────
proc showContextMenu(hwnd: HWND) =
  var pt: POINT
  GetCursorPos(addr pt)
  # Required so the menu dismisses properly when clicking elsewhere
  SetForegroundWindow(hwnd)

  let hMenu = CreatePopupMenu()

  # Status header — greyed, not clickable
  AppendMenuW(hMenu, MF_STRING or MF_GRAYED, 0,
              newWideCString(statusLabel(gStatus)))
  AppendMenuW(hMenu, MF_SEPARATOR, 0, nil)

  # Notifications toggle with check mark
  let notifyLabel = if gNotifyOn: "Notifications: On" else: "Notifications: Off"
  let notifyFlags = MF_STRING or (if gNotifyOn: MF_CHECKED else: 0)
  AppendMenuW(hMenu, notifyFlags.UINT, ID_NOTIFY.UINT_PTR,
              newWideCString(notifyLabel))

  # Sound toggle with check mark
  let soundLabel = if gSoundOn: "Sound: On" else: "Sound: Off"
  let soundFlags = MF_STRING or (if gSoundOn: MF_CHECKED else: 0)
  AppendMenuW(hMenu, soundFlags.UINT, ID_SOUND.UINT_PTR,
              newWideCString(soundLabel))

  # Email toggle with check mark
  let emailLabel = if gEmailOn: "Email Alert: On" else: "Email Alert: Off"
  let emailFlags = MF_STRING or (if gEmailOn: MF_CHECKED else: 0)
  AppendMenuW(hMenu, emailFlags.UINT, ID_EMAIL.UINT_PTR,
              newWideCString(emailLabel))

  AppendMenuW(hMenu, MF_STRING, ID_TEST_EMAIL.UINT_PTR,
              newWideCString("Send Test Email..."))

  AppendMenuW(hMenu, MF_SEPARATOR, 0, nil)
  AppendMenuW(hMenu, MF_STRING, ID_EXIT.UINT_PTR, newWideCString("Exit"))

  let cmd = TrackPopupMenu(hMenu,
    TPM_LEFTALIGN or TPM_RIGHTBUTTON or TPM_RETURNCMD,
    pt.x, pt.y, 0, hwnd, nil).int
  DestroyMenu(hMenu)

  case cmd
  of ID_NOTIFY: gNotifyOn = not gNotifyOn
  of ID_SOUND:  gSoundOn  = not gSoundOn
  of ID_EMAIL:  gEmailOn  = not gEmailOn
  of ID_TEST_EMAIL:
    let (ok, err) = sendTestEmail()
    if ok:
      discard MessageBoxW(0, newWideCString("Test email delivered successfully."),
                          newWideCString(AppName), MB_ICONINFORMATION or MB_OK)
    else:
      discard MessageBoxW(0, newWideCString("Could not send test email:\n" & err),
                          newWideCString(AppName), MB_ICONERROR or MB_OK)
  of ID_EXIT:   gFrame.close()
  else: discard

# ─── Entry point ──────────────────────────────────────────────────────────────
when isMainModule:
  # Load settings from JSON file in app directory
  gCfg     = loadSettings()
  gSoundOn  = gCfg.soundOn
  gNotifyOn = gCfg.notifyOn
  gEmailOn  = gCfg.emailOn

  # Bind UDP receive socket — fail fast if port is taken (another instance)
  try:
    initSockets()
  except OSError:
    discard MessageBoxW(0,
      newWideCString("Could not bind UDP port " & $gCfg.lbInPort &
                     ".\nIs another instance already running?"),
      newWideCString(AppName), MB_ICONERROR or MB_OK)
    quit(1)

  let app = App()

  # Minimal hidden frame — only needed as a message sink
  gFrame = Frame(title = AppName)
  gFrame.hide()

  # Remove app from taskbar: set WS_EX_TOOLWINDOW, clear WS_EX_APPWINDOW
  let hwnd = gFrame.mHwnd
  var exStyle = GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
  exStyle = (exStyle or WS_EX_TOOLWINDOW) and not WS_EX_APPWINDOW
  SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle)
  SetWindowPos(hwnd, 0, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_FRAMECHANGED)

  createIcons()
  initTray(hwnd)
  updateTrayIcon()

  # ── Tray icon mouse events ─────────────────────────────────────────────────
  gFrame.connect(WM_TRAYICON.UINT) do (event: wEvent):
    let notif = int event.lParam
    if notif == WM_RBUTTONUP:
      showContextMenu(hwnd)

  # ── Periodic poll + completion detection ──────────────────────────────────
  gFrame.connect(wEvent_Timer) do (event: wEvent):
    let tid = event.timerId

    if tid == TIMER_POLL:
      let prev = gStatus
      pollLightBurn()

      if gStatus != prev:
        updateTrayIcon()
        if gStatus == bsComplete:
          if gNotifyOn:
            showBalloon("Burn Complete!", "LightBurn has finished the job.")
          playAlert()
          let (emailOk, emailErr) = sendAlertEmail()
          if gEmailOn and not emailOk:
            showBalloon("Email Alert Failed", emailErr)
          # Schedule revert to idle after CompleteSecs seconds
          gFrame.startTimer(gCfg.completeSecs, TIMER_COMPLETE)

    elif tid == TIMER_COMPLETE:
      gFrame.stopTimer(TIMER_COMPLETE)
      if gStatus == bsComplete:
        gStatus = bsIdle
        updateTrayIcon()

  # ── Cleanup on close ──────────────────────────────────────────────────────
  gFrame.connect(wEvent_Close) do (event: wEvent):
    gFrame.stopTimer(TIMER_POLL)
    gFrame.stopTimer(TIMER_COMPLETE)
    removeTray()
    destroyIcons()
    closeSockets()
    event.skip()  # let default handler destroy the window and exit the loop

  # Start polling timer
  gFrame.startTimer(gCfg.pollSecs, TIMER_POLL)

  app.mainLoop()
