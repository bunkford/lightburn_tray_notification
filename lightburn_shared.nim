# lightburn_shared.nim
# ─────────────────────────────────────────────────────────────────────────────
# Platform-independent logic: settings, UDP polling, SMTP email, state.
# Imported by both lightburn_tray.nim (Windows) and lightburn_tray_mac.nim.
# ─────────────────────────────────────────────────────────────────────────────

import std/[net, strutils, os, json, sequtils]
import std/nativesockets as ns
import smtp
when not defined(windows):
  import posix

const AppName* = "LightBurn Monitor"

# ─── Settings ─────────────────────────────────────────────────────────────────
type
  SmtpSettings* = object
    host*:     string
    port*:     int
    useSsl*:   bool
    username*: string
    password*: string
    fromAddr*: string
    toAddrs*:  seq[string]

  Settings* = object
    lbHost*:        string
    lbOutPort*:     int
    lbInPort*:      int
    pollSecs*:      float
    completeSecs*:  float
    recvTimeoutMs*: int
    soundOn*:       bool
    notifyOn*:      bool
    emailOn*:       bool
    smtp*:          SmtpSettings

proc defaultSettings*(): Settings =
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

proc loadSettings*(): Settings =
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

# ─── Status enum ──────────────────────────────────────────────────────────────
type
  BurnStatus* = enum
    bsDisconnected   ## LightBurn unreachable or not running
    bsIdle           ## Connected, no active job
    bsBurning        ## Job in progress
    bsComplete       ## Job just finished (transient, reverts after completeSecs)

# ─── Global state ─────────────────────────────────────────────────────────────
var
  gCfg*:      Settings   = defaultSettings()
  gStatus*:   BurnStatus = bsDisconnected
  gSoundOn*:  bool       = true
  gNotifyOn*: bool       = true
  gEmailOn*:  bool       = false
  gOutSock*:  Socket
  gInSock*:   Socket

# ─── Status label ─────────────────────────────────────────────────────────────
proc statusLabel*(s: BurnStatus): string =
  case s
  of bsDisconnected: AppName & " — not connected"
  of bsIdle:         AppName & " — idle"
  of bsBurning:      AppName & " — burning..."
  of bsComplete:     AppName & " — job complete!"

# ─── SMTP email ───────────────────────────────────────────────────────────────
proc sendAlertEmail*() =
  if not gEmailOn: return
  let s = gCfg.smtp
  if s.toAddrs.len == 0 or s.fromAddr == "": return
  try:
    let sender     = createEmail(s.fromAddr)
    let recipients = s.toAddrs.mapIt(createEmail(it))
    let msg = createMessage(
      "LightBurn Job Complete",
      "LightBurn has finished the job.",
      sender, recipients)
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

# ─── UDP sockets ──────────────────────────────────────────────────────────────
proc initSockets*() =
  gOutSock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, buffered = false)
  gInSock  = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, buffered = false)
  gInSock.setSockOpt(OptReuseAddr, true)
  gInSock.bindAddr(Port(gCfg.lbInPort), "0.0.0.0")
  # Set receive timeout — format differs between Windows (DWORD ms) and POSIX (timeval).
  when defined(windows):
    ns.setSockOptInt(gInSock.getFd(), 0xFFFF, 0x1006, gCfg.recvTimeoutMs)
  else:
    var tv = Timeval(
      tv_sec:  Time(gCfg.recvTimeoutMs div 1000),
      tv_usec: Suseconds((gCfg.recvTimeoutMs mod 1000) * 1000))
    discard setsockopt(gInSock.getFd(),
                       cint(SOL_SOCKET), cint(SO_RCVTIMEO),
                       addr tv, Socklen(sizeof(tv)))

proc closeSockets*() =
  try: gOutSock.close() except: discard
  try: gInSock.close()  except: discard

# ─── UDP poll ─────────────────────────────────────────────────────────────────
proc pollLightBurn*() =
  ## Send STATUS to LightBurn, parse response, update gStatus.
  let oldStatus = gStatus

  try:
    gOutSock.sendTo(gCfg.lbHost, Port(gCfg.lbOutPort), "STATUS")
  except:
    gStatus = bsDisconnected
    return

  var data   = newString(256)
  var sender = ""
  var port   = Port(0)
  let n = try: gInSock.recvFrom(data, 256, sender, port)
          except: (gStatus = bsDisconnected; return)
  if n <= 0:
    gStatus = bsDisconnected
    return
  data.setLen(n)

  if "OK" in data:
    if oldStatus == bsBurning:
      gStatus = bsComplete
    elif oldStatus != bsComplete:
      gStatus = bsIdle
  elif "!" in data:
    gStatus = bsBurning
  else:
    gStatus = bsDisconnected
