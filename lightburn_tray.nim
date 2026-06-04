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
# ─────────────────────────────────────────────────────────────────────────────

when not defined(windows):
  {.error: "lightburn_tray is a Windows-only application."}

import wnim
import winim/[winstr, utils]
import winim/inc/[shellapi, winuser, windef, wingdi, mmsystem]
import std/[net, strutils, os, json, sequtils]
import std/nativesockets as ns
import smtp

# ─── Application constant ─────────────────────────────────────────────────────
const AppName = "LightBurn Monitor"

# ─── Settings ─────────────────────────────────────────────────────────────────
type
  SmtpSettings = object
    host:      string
    port:      int
    useSsl:    bool
    username:  string
    password:  string
    fromAddr:  string
    toAddrs:   seq[string]

  Settings = object
    lbHost:        string
    lbOutPort:     int
    lbInPort:      int
    pollSecs:      float
    completeSecs:  float
    recvTimeoutMs: int
    soundOn:       bool
    notifyOn:      bool
    emailOn:       bool
    smtp:          SmtpSettings

proc defaultSettings(): Settings =
  Settings(
    lbHost:        "127.0.0.1",
    lbOutPort:     19840,
    lbInPort:      19841,
    pollSecs:      2.0,
    completeSecs:  8.0,
    recvTimeoutMs: 700,
    soundOn:       true,
    notifyOn:      true,
    emailOn:       false,
    smtp: SmtpSettings(
      host:     "smtp.example.com",
      port:     587,
      useSsl:   false,
      username: "",
      password: "",
      fromAddr: "lightburn@example.com",
      toAddrs:  @[],
    ),
  )

proc loadSettings(): Settings =
  result = defaultSettings()
  let path = getAppDir() / "lightburn_tray.json"
  if not fileExists(path): return
  try:
    let j = parseFile(path)
    result.lbHost        = j{"lbHost"}.getStr(result.lbHost)
    result.lbOutPort     = j{"lbOutPort"}.getInt(result.lbOutPort)
    result.lbInPort      = j{"lbInPort"}.getInt(result.lbInPort)
    result.pollSecs      = j{"pollSecs"}.getFloat(result.pollSecs)
    result.completeSecs  = j{"completeSecs"}.getFloat(result.completeSecs)
    result.recvTimeoutMs = j{"recvTimeoutMs"}.getInt(result.recvTimeoutMs)
    result.soundOn       = j{"soundOn"}.getBool(result.soundOn)
    result.notifyOn      = j{"notifyOn"}.getBool(result.notifyOn)
    result.emailOn       = j{"emailOn"}.getBool(result.emailOn)
    let s = j{"smtp"}
    if s != nil:
      result.smtp.host     = s{"host"}.getStr(result.smtp.host)
      result.smtp.port     = s{"port"}.getInt(result.smtp.port)
      result.smtp.useSsl   = s{"useSsl"}.getBool(result.smtp.useSsl)
      result.smtp.username = s{"username"}.getStr(result.smtp.username)
      result.smtp.password = s{"password"}.getStr(result.smtp.password)
      result.smtp.fromAddr = s{"fromAddr"}.getStr(result.smtp.fromAddr)
      let ta = s{"toAddrs"}
      if ta != nil and ta.kind == JArray:
        result.smtp.toAddrs = @[]
        for item in ta:
          result.smtp.toAddrs.add(item.getStr())
  except:
    discard  # keep defaults on any parse error

# ─── Win32 / tray identifiers ─────────────────────────────────────────────────
const
  WM_TRAYICON    = WM_APP + 1   # tray callback message
  TRAY_UID       = 1
  TIMER_POLL     = 1            # wnim timer ID for UDP polling
  TIMER_COMPLETE = 2            # wnim timer ID for "complete" revert
  ID_SOUND       = 1001         # context-menu command IDs
  ID_NOTIFY      = 1003
  ID_EMAIL       = 1004
  ID_EXIT        = 1002

# ─── Status enum ──────────────────────────────────────────────────────────────
type
  BurnStatus = enum
    bsDisconnected   ## LightBurn unreachable or not running
    bsIdle           ## Connected, no active job
    bsBurning        ## Job in progress
    bsComplete       ## Job just finished (transient, reverts after CompleteSecs)

# ─── Global state ─────────────────────────────────────────────────────────────
var
  gCfg:       Settings   = defaultSettings()
  gStatus:    BurnStatus = bsDisconnected
  gSoundOn:   bool       = true
  gNotifyOn:  bool       = true
  gEmailOn:   bool       = false
  gFrame:    wFrame
  gNid:      NOTIFYICONDATAW
  gIcons:    array[BurnStatus, HICON]
  gOutSock:  Socket
  gInSock:   Socket

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
proc statusLabel(s: BurnStatus): string =
  case s
  of bsDisconnected: AppName & " — not connected"
  of bsIdle:         AppName & " — idle"
  of bsBurning:      AppName & " — burning..."
  of bsComplete:     AppName & " — job complete!"

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

# ─── Email ────────────────────────────────────────────────────────────────────
proc sendAlertEmail() =
  if not gEmailOn: return
  let s = gCfg.smtp
  if s.toAddrs.len == 0 or s.fromAddr == "": return
  try:
    let sender = createEmail(s.fromAddr)
    let recipients = s.toAddrs.mapIt(createEmail(it))
    let msg = createMessage(
      "LightBurn Job Complete",
      "LightBurn has finished the job.",
      sender,
      recipients)
    let conn = newSmtp(useSsl = s.useSsl)
    conn.connect(s.host, Port(s.port))
    if not s.useSsl:
      discard conn.ehlo()
      if s.username != "":
        conn.startTls()
        discard conn.ehlo()
    if s.username != "":
      conn.auth(s.username, s.password)
    conn.sendMail(s.fromAddr, s.toAddrs, $msg)
    conn.close()
  except:
    discard  # silently ignore email errors

# ─── UDP polling ──────────────────────────────────────────────────────────────
proc initSockets() =
  gOutSock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, buffered = false)
  gInSock  = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, buffered = false)
  gInSock.setSockOpt(OptReuseAddr, true)
  gInSock.bindAddr(Port(gCfg.lbInPort), "0.0.0.0")
  # SO_RCVTIMEO (0x1006) on SOL_SOCKET (0xFFFF): millisecond DWORD on Windows.
  # Causes recvFrom to raise OSError after the timeout instead of blocking.
  ns.setSockOptInt(gInSock.getFd(), 0xFFFF, 0x1006, gCfg.recvTimeoutMs)

proc closeSockets() =
  try: gOutSock.close() except: discard
  try: gInSock.close()  except: discard

proc pollLightBurn() =
  ## Send STATUS to LightBurn and parse the response.
  ## Updates gStatus in-place.
  let oldStatus = gStatus

  # Send STATUS request
  try:
    gOutSock.sendTo(gCfg.lbHost, Port(gCfg.lbOutPort), "STATUS")
  except:
    gStatus = bsDisconnected
    return

  # Receive response — recvFrom will time out via SO_RCVTIMEO set in initSockets.
  var data   = newString(256)
  var sender = ""
  var port   = Port(0)
  let n = try: gInSock.recvFrom(data, 256, sender, port)
          except: (gStatus = bsDisconnected; return)
  if n <= 0:
    gStatus = bsDisconnected
    return
  data.setLen(n)

  # Parse: "OK" = idle, "!" without "OK" = burning, else disconnected
  if "OK" in data:
    if oldStatus == bsBurning:
      gStatus = bsComplete   # job finished — caller will react
    elif oldStatus != bsComplete:
      gStatus = bsIdle       # already idle or reconnected
    # if oldStatus == bsComplete we leave it alone; TIMER_COMPLETE will revert it
  elif "!" in data:
    gStatus = bsBurning
  else:
    gStatus = bsDisconnected

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
          sendAlertEmail()
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
