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

# Embed the application icon (AppIcon.ico compiled to lightburn_tray.o by windres).
# The build step runs: windres lightburn_tray.rc lightburn_tray.o
{.link: "lightburn_tray.o".}

# Windows Credential Manager (advapi32) — wraps CredWriteW/CredReadW for SMTP password.
{.compile: "lightburn_win_cred.c".}
{.passL: "-ladvapi32".}
proc winSaveCredential(password: cstring) {.importc: "win_save_credential".}
proc winLoadCredential(): cstring         {.importc: "win_load_credential".}

import ./lightburn_shared
import std/[os, strutils]
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
  ID_SETTINGS     = 1005
  ID_EXIT         = 1002

# ─── Windows-only extra state ─────────────────────────────────────────────────
var
  gFrame: wFrame
  gNid:   NOTIFYICONDATAW
  gIcons: array[BurnStatus, HICON]
  gSettingsDlg: wFrame = nil   # reference kept so GC doesn't collect it

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

# ─── Settings dialog ─────────────────────────────────────────────────────────
proc showSettingsDialog() =
  ## Open the native settings window (or bring existing one to front).
  if not gSettingsDlg.isNil and IsWindow(gSettingsDlg.mHwnd) != 0:
    SetForegroundWindow(gSettingsDlg.mHwnd)
    return

  # Layout constants — mirror the Mac panel geometry
  const
    LBL_X   = 10    # label leading edge
    LBL_W   = 162   # label column width (right-aligned)
    FLD_X   = 176   # field leading edge
    FLD_W   = 338   # field width to right margin
    SML_W   = 80    # narrow field (ports / numbers)
    ROW_H   = 23    # text control height
    ROW_GAP = 7     # gap between consecutive rows
    SEC_GAP = 14    # extra vertical space before a section header
    TOP_PAD = 14    # top padding inside a page panel
    PNL_W   = 530   # page panel inner width
    NB_H    = 430   # notebook height
    BTN_Y   = NB_H + 10  # Y of the button strip

  let dlg = Frame(title = "Settings - " & AppName,
                  size  = (580, 0),
                  style = wDefaultFrameStyle and not wResizeBorder and not wMaximizeBox)

  let mainPanel = Panel(dlg)
  let nb = Notebook(mainPanel, pos = (8, 8), size = (560, NB_H))

  # ── Tab 1: Connection ──────────────────────────────────────────────────────
  let pg1 = Panel(nb)
  nb.addPage(pg1, "Connection")

  var y = TOP_PAD

  proc lbl1(text: string; atY: int) =
    discard StaticText(pg1, label = text,
                       pos = (LBL_X, atY + 4), size = (LBL_W, 18),
                       style = wAlignRight)

  proc txt1(val: string; atY: int; w = FLD_W): wTextCtrl =
    result = TextCtrl(pg1, value = val, pos = (FLD_X, atY), size = (w, ROW_H))

  proc secHdr1(text: string; atY: int) =
    let tf = StaticText(pg1, label = text, pos = (LBL_X, atY), size = (PNL_W, 16))
    tf.font = Font(8, weight = wFontWeightBold)

  secHdr1("LIGHTBURN CONNECTION", y);  y += 20
  lbl1("LightBurn Host:", y);  let hostCtrl    = txt1(gCfg.lbHost,       y);  y += ROW_H + ROW_GAP
  lbl1("Out Port:", y);        let outPortCtrl = txt1($gCfg.lbOutPort,   y, SML_W); y += ROW_H + ROW_GAP
  lbl1("In Port:", y);         let inPortCtrl  = txt1($gCfg.lbInPort,    y, SML_W); y += ROW_H + SEC_GAP
  secHdr1("TIMING", y);        y += 20
  lbl1("Poll Interval (s):",    y); let pollCtrl = txt1($gCfg.pollSecs,      y, SML_W); y += ROW_H + ROW_GAP
  lbl1("Complete Display (s):", y); let compCtrl = txt1($gCfg.completeSecs,  y, SML_W); y += ROW_H + ROW_GAP
  lbl1("Recv Timeout (ms):",    y); let recvCtrl = txt1($gCfg.recvTimeoutMs, y, SML_W); y += ROW_H

  # ── Tab 2: Email & Alerts ──────────────────────────────────────────────────
  let pg2 = Panel(nb)
  nb.addPage(pg2, "Email && Alerts")
  nb.select(0)  # ensure tab 1 is shown first

  y = TOP_PAD

  proc lbl2(text: string; atY: int) =
    discard StaticText(pg2, label = text,
                       pos = (LBL_X, atY + 4), size = (LBL_W, 18),
                       style = wAlignRight)

  proc txt2(val: string; atY: int; w = FLD_W): wTextCtrl =
    result = TextCtrl(pg2, value = val, pos = (FLD_X, atY), size = (w, ROW_H))

  proc secHdr2(text: string; atY: int) =
    let tf = StaticText(pg2, label = text, pos = (LBL_X, atY), size = (PNL_W, 16))
    tf.font = Font(8, weight = wFontWeightBold)

  secHdr2("ALERTS", y);  y += 20
  let soundChk  = CheckBox(pg2, label = "Sound Alert",           pos = (FLD_X, y))
  soundChk.value  = gSoundOn;   y += ROW_H + ROW_GAP
  let notifyChk = CheckBox(pg2, label = "Desktop Notifications", pos = (FLD_X, y))
  notifyChk.value = gNotifyOn;  y += ROW_H + ROW_GAP
  let emailChk  = CheckBox(pg2, label = "Email Alerts",          pos = (FLD_X, y))
  emailChk.value  = gEmailOn;   y += ROW_H + SEC_GAP

  secHdr2("SMTP EMAIL", y);  y += 20
  lbl2("SMTP Host:", y);      let smtpHostCtrl = txt2(gCfg.smtp.host,              y); y += ROW_H + ROW_GAP
  lbl2("SMTP Port:", y);      let smtpPortCtrl = txt2($gCfg.smtp.port,             y, SML_W); y += ROW_H + ROW_GAP
  let smtpSslChk = CheckBox(pg2,
                             label = "Use STARTTLS (port 587) or implicit SSL (port 465)",
                             pos = (FLD_X, y), size = (FLD_W, 20))
  smtpSslChk.value = gCfg.smtp.useSsl;  y += 22 + ROW_GAP
  lbl2("Username:", y);       let smtpUserCtrl = txt2(gCfg.smtp.username,          y); y += ROW_H + ROW_GAP
  lbl2("Password:", y)
  let smtpPassCtrl = TextCtrl(pg2, value = gCfg.smtp.password,
                               pos = (FLD_X, y), size = (FLD_W, ROW_H),
                               style = wTePassword);                                    y += ROW_H + ROW_GAP
  lbl2("From:", y);           let smtpFromCtrl = txt2(gCfg.smtp.fromAddr,          y); y += ROW_H + ROW_GAP
  lbl2("To (comma-sep.):", y);let smtpToCtrl   = txt2(gCfg.smtp.toAddrs.join(", "), y)

  # ── Button strip ───────────────────────────────────────────────────────────
  let testEmailBtn = Button(mainPanel, label = "Test Email...", pos = (10,  BTN_Y), size = (110, 28))
  let cancelBtn    = Button(mainPanel, label = "Cancel",        pos = (348, BTN_Y), size = (90,  28))
  let saveBtn      = Button(mainPanel, label = "Save",          pos = (448, BTN_Y), size = (90,  28))
  saveBtn.setDefault()

  mainPanel.size = (576, BTN_Y + 42)
  dlg.clientSize = (576, BTN_Y + 42)
  dlg.center()

  # ── Event handlers ─────────────────────────────────────────────────────────
  testEmailBtn.connect(wEvent_Button) do (ev: wEvent):
    let (ok, err) = sendTestEmail()
    if ok:
      discard MessageBoxW(0, newWideCString("Test email delivered successfully."),
                          newWideCString(AppName), MB_ICONINFORMATION or MB_OK)
    else:
      discard MessageBoxW(0, newWideCString("Could not send test email:\n" & err),
                          newWideCString(AppName), MB_ICONERROR or MB_OK)

  cancelBtn.connect(wEvent_Button) do (ev: wEvent): dlg.close()

  saveBtn.connect(wEvent_Button) do (ev: wEvent):
    # ── Validation ────────────────────────────────────────────────────────────
    var errs: seq[string]
    let host = hostCtrl.value.strip()
    if host.len == 0: errs.add("LightBurn Host cannot be empty.")

    let outPort = try: outPortCtrl.value.strip().parseInt except: -1
    if outPort < 1 or outPort > 65535: errs.add("Out Port must be 1-65535.")
    let inPort  = try: inPortCtrl.value.strip().parseInt  except: -1
    if inPort   < 1 or inPort  > 65535: errs.add("In Port must be 1-65535.")

    let pollSecs = try: pollCtrl.value.strip().parseFloat except: -1.0
    if pollSecs < 0.1 or pollSecs > 60.0:
      errs.add("Poll Interval must be 0.1-60 seconds.")
    let completeSecs = try: compCtrl.value.strip().parseFloat except: -1.0
    if completeSecs < 1.0 or completeSecs > 3600.0:
      errs.add("Complete Timer must be 1-3600 seconds.")
    let recvMs = try: recvCtrl.value.strip().parseInt except: -1
    if recvMs < 50 or recvMs > 10000:
      errs.add("Recv Timeout must be 50-10000 ms.")

    let smtpPort = try: smtpPortCtrl.value.strip().parseInt except: -1
    if smtpPort < 1 or smtpPort > 65535: errs.add("SMTP Port must be 1-65535.")

    let fromAddr = smtpFromCtrl.value.strip()
    if fromAddr.len > 0 and '@' notin fromAddr:
      errs.add("From address does not look like a valid email.")

    if errs.len > 0:
      discard MessageBoxW(0, newWideCString(errs.join("\n")),
                          newWideCString(AppName & " - Validation Error"),
                          MB_ICONERROR or MB_OK)
      return

    # ── Apply ─────────────────────────────────────────────────────────────────
    let prevInPort   = gCfg.lbInPort
    let prevPollSecs = gCfg.pollSecs

    gCfg.lbHost        = host
    gCfg.lbOutPort     = outPort
    gCfg.lbInPort      = inPort
    gCfg.pollSecs      = pollSecs
    gCfg.completeSecs  = completeSecs
    gCfg.recvTimeoutMs = recvMs
    gSoundOn  = soundChk.isChecked();  gCfg.soundOn  = gSoundOn
    gNotifyOn = notifyChk.isChecked(); gCfg.notifyOn = gNotifyOn
    gEmailOn  = emailChk.isChecked();  gCfg.emailOn  = gEmailOn
    gCfg.smtp.host     = smtpHostCtrl.value.strip()
    gCfg.smtp.port     = smtpPort
    gCfg.smtp.useSsl   = smtpSslChk.isChecked()
    gCfg.smtp.username = smtpUserCtrl.value.strip()
    gCfg.smtp.password = smtpPassCtrl.value
    gCfg.smtp.fromAddr = fromAddr
    gCfg.smtp.toAddrs  = @[]
    for part in smtpToCtrl.value.split(','):
      let t = part.strip()
      if t.len > 0: gCfg.smtp.toAddrs.add(t)

    # Rebind socket if listen port changed
    if prevInPort != gCfg.lbInPort:
      closeSockets()
      try: initSockets()
      except:
        discard MessageBoxW(0, newWideCString("Could not bind UDP port " & $gCfg.lbInPort &
                                              ".\nReverted to previous port."),
                            newWideCString(AppName), MB_ICONERROR or MB_OK)
        gCfg.lbInPort = prevInPort
        closeSockets()
        try: initSockets() except: discard
        return

    # Update poll timer if interval changed
    if prevPollSecs != gCfg.pollSecs:
      gFrame.stopTimer(TIMER_POLL)
      gFrame.startTimer(gCfg.pollSecs, TIMER_POLL)

    winSaveCredential(gCfg.smtp.password.cstring)
    saveSettings(gCfg)
    dlg.close()

  dlg.connect(wEvent_Close) do (ev: wEvent):
    gSettingsDlg = nil
    ev.skip()

  gSettingsDlg = dlg
  dlg.show()

# ─── Right-click context menu ─────────────────────────────────────────────────
proc showContextMenu(hwnd: HWND) =
  var pt: POINT
  GetCursorPos(addr pt)
  SetForegroundWindow(hwnd)

  let hMenu = CreatePopupMenu()

  AppendMenuW(hMenu, MF_STRING or MF_GRAYED, 0,
              newWideCString(statusLabel(gStatus)))
  AppendMenuW(hMenu, MF_SEPARATOR, 0, nil)

  let notifyLabel = if gNotifyOn: "Notifications: On" else: "Notifications: Off"
  let notifyFlags = MF_STRING or (if gNotifyOn: MF_CHECKED else: 0)
  AppendMenuW(hMenu, notifyFlags.UINT, ID_NOTIFY.UINT_PTR, newWideCString(notifyLabel))

  let soundLabel = if gSoundOn: "Sound: On" else: "Sound: Off"
  let soundFlags = MF_STRING or (if gSoundOn: MF_CHECKED else: 0)
  AppendMenuW(hMenu, soundFlags.UINT, ID_SOUND.UINT_PTR, newWideCString(soundLabel))

  let emailLabel = if gEmailOn: "Email Alert: On" else: "Email Alert: Off"
  let emailFlags = MF_STRING or (if gEmailOn: MF_CHECKED else: 0)
  AppendMenuW(hMenu, emailFlags.UINT, ID_EMAIL.UINT_PTR, newWideCString(emailLabel))

  AppendMenuW(hMenu, MF_SEPARATOR, 0, nil)
  AppendMenuW(hMenu, MF_STRING, ID_SETTINGS.UINT_PTR, newWideCString("Settings..."))
  AppendMenuW(hMenu, MF_SEPARATOR, 0, nil)
  AppendMenuW(hMenu, MF_STRING, ID_EXIT.UINT_PTR, newWideCString("Exit"))

  let cmd = TrackPopupMenu(hMenu,
    TPM_LEFTALIGN or TPM_RIGHTBUTTON or TPM_RETURNCMD,
    pt.x, pt.y, 0, hwnd, nil).int
  DestroyMenu(hMenu)

  case cmd
  of ID_NOTIFY:   gNotifyOn = not gNotifyOn
  of ID_SOUND:    gSoundOn  = not gSoundOn
  of ID_EMAIL:    gEmailOn  = not gEmailOn
  of ID_SETTINGS: showSettingsDialog()
  of ID_EXIT:     gFrame.close()
  else: discard

# ─── Entry point ──────────────────────────────────────────────────────────────
when isMainModule:
  # Load settings from JSON file in app directory
  gCfg     = loadSettings()
  # Load SMTP password from Windows Credential Manager (not stored in JSON)
  let credPw = $winLoadCredential()
  if credPw.len > 0:
    gCfg.smtp.password = credPw      # cred store wins over JSON
  elif gCfg.smtp.password.len > 0:
    # Migration: JSON had a plaintext password — move it to cred store
    winSaveCredential(gCfg.smtp.password.cstring)
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
