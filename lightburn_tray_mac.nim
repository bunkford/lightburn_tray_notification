# lightburn_tray_mac.nim
# ─────────────────────────────────────────────────────────────────────────────
# macOS entry point for LightBurn Monitor.
# Compile on a Mac with:
#   nim c -d:ssl lightburn_tray_mac.nim
# (requires Xcode command-line tools for the Objective-C compiler)
#
# Runtime files expected next to the binary:
#   lightburn_tray.json   — settings (optional, defaults apply if absent)
#   complete.wav          — custom alert sound (optional, falls back to Glass)
# ─────────────────────────────────────────────────────────────────────────────

when not defined(macosx):
  {.error: "lightburn_tray_mac is macOS-only. Compile on a Mac with: nim c -d:ssl lightburn_tray_mac.nim"}

import ./lightburn_shared
import std/[os, osproc, strutils]

# ─── Link the ObjC helper and Cocoa framework ─────────────────────────────────
{.compile: "lightburn_mac_helper.m".}
{.passL: "-framework Cocoa -framework Foundation -framework UserNotifications -framework Security".}

# ─── C API declared by lightburn_mac_helper.m ────────────────────────────────
proc mac_setup(pollSecs, completeSecs: cdouble) {.importc.}
proc mac_run()                                  {.importc.}
proc mac_show_notification(title, body: cstring){.importc.}
proc mac_start_complete_timer()                 {.importc.}
proc mac_stop_all_timers()                      {.importc.}
proc mac_quit()                                 {.importc.}
proc mac_resource_dir(): cstring               {.importc.}

# ─── Sound (macOS: afplay command) ────────────────────────────────────────────
proc playAlert() =
  if not gSoundOn: return
  let wav = resourceDir() / "complete.wav"
  let cmd =
    if fileExists(wav): "afplay \"" & wav & "\""
    else:               "afplay /System/Library/Sounds/Glass.aiff"
  # Run asynchronously so we don't stall the run loop
  discard startProcess(command = "sh", args = ["-c", cmd & " &"],
                       options = {poUsePath})

# ─── Nim callbacks — exported as C symbols, called from lightburn_mac_helper.m ─

# Called by NSTimer every pollSecs. Does the UDP request and reacts to changes.
proc nim_poll_tick() {.exportc.} =
  let prev = gStatus
  pollLightBurn()
  if gStatus != prev and gStatus == bsComplete:
    if gNotifyOn:
      mac_show_notification("Burn Complete!", "LightBurn has finished the job.")
    playAlert()
    let (emailOk, emailErr) = sendAlertEmail()
    if gEmailOn:
      if emailOk:
        mac_show_notification("Email Sent", "Alert email delivered successfully.")
      else:
        var msg = "Could not send alert: " & emailErr
        mac_show_notification("Email Failed", msg.cstring)
    mac_start_complete_timer()

# Called when the complete timer fires (after completeSecs). Reverts to idle.
proc nim_complete_revert() {.exportc.} =
  if gStatus == bsComplete:
    gStatus = bsIdle

# Test-email result buffer — kept alive so the cstring pointer stays valid.
var gEmailErrBuf: string

proc nim_send_test_email(): cint {.exportc.} =
  let (ok, err) = sendTestEmail()
  gEmailErrBuf = err
  result = cint(ok)

proc nim_send_test_email_fields(host: cstring; port: cint; useSsl: cint;
                                username: cstring; password: cstring;
                                fromAddr: cstring; toStr: cstring): cint {.exportc.} =
  var toAddrs: seq[string]
  for part in ($toStr).split(','):
    let t = part.strip()
    if t.len > 0: toAddrs.add(t)
  let smtp = SmtpSettings(host: $host, port: port.int, useSsl: useSsl != 0,
                          username: $username, password: $password,
                          fromAddr: $fromAddr, toAddrs: toAddrs)
  let (ok, err) = sendTestEmailWith(smtp)
  gEmailErrBuf = err
  result = cint(ok)

proc nim_email_last_error(): cstring {.exportc.} =
  gEmailErrBuf.cstring

proc nim_toggle_sound()  {.exportc.} = gSoundOn  = not gSoundOn
proc nim_toggle_notify() {.exportc.} = gNotifyOn = not gNotifyOn
proc nim_toggle_email()  {.exportc.} = gEmailOn  = not gEmailOn

proc nim_do_exit() {.exportc.} =
  mac_stop_all_timers()
  closeSockets()
  mac_quit()

# Queried by ObjC to populate menu labels and the status-bar tooltip.
# Returns a pointer into a module-level string — valid for the duration of the call.
var gLabelBuf: string   # kept alive so the cstring pointer stays valid

proc nim_status_label(): cstring {.exportc.} =
  gLabelBuf = statusLabel(gStatus)
  result = gLabelBuf.cstring

proc nim_get_sound_on():  cint {.exportc.} = cint(gSoundOn)
proc nim_get_notify_on(): cint {.exportc.} = cint(gNotifyOn)
proc nim_get_email_on():  cint {.exportc.} = cint(gEmailOn)
proc nim_get_status():    cint {.exportc.} = cint(ord(gStatus))

# ─── Settings read API (called from main thread only) ─────────────────────────
var gCfgStrBuf: string  # separate from gLabelBuf — main-thread only

proc nim_cfg_lb_host(): cstring {.exportc.} =
  gCfgStrBuf = gCfg.lbHost; gCfgStrBuf.cstring
proc nim_cfg_lb_out_port(): cint {.exportc.} = cint(gCfg.lbOutPort)
proc nim_cfg_lb_in_port():  cint {.exportc.} = cint(gCfg.lbInPort)
proc nim_cfg_poll_secs():   cdouble {.exportc.} = cdouble(gCfg.pollSecs)
proc nim_cfg_complete_secs(): cdouble {.exportc.} = cdouble(gCfg.completeSecs)
proc nim_cfg_recv_timeout_ms(): cint {.exportc.} = cint(gCfg.recvTimeoutMs)
proc nim_cfg_smtp_host(): cstring {.exportc.} =
  gCfgStrBuf = gCfg.smtp.host; gCfgStrBuf.cstring
proc nim_cfg_smtp_port():    cint {.exportc.} = cint(gCfg.smtp.port)
proc nim_cfg_smtp_use_ssl(): cint {.exportc.} = cint(gCfg.smtp.useSsl)
proc nim_cfg_smtp_username(): cstring {.exportc.} =
  gCfgStrBuf = gCfg.smtp.username; gCfgStrBuf.cstring
proc nim_cfg_smtp_password(): cstring {.exportc.} =
  gCfgStrBuf = gCfg.smtp.password; gCfgStrBuf.cstring
proc nim_set_smtp_password(pw: cstring) {.exportc.} =
  gCfg.smtp.password = $pw
proc nim_cfg_smtp_from(): cstring {.exportc.} =
  gCfgStrBuf = gCfg.smtp.fromAddr; gCfgStrBuf.cstring
proc nim_cfg_smtp_to(): cstring {.exportc.} =
  gCfgStrBuf = gCfg.smtp.toAddrs.join(", "); gCfgStrBuf.cstring

proc nim_reload_settings(): cint {.exportc.} =
  ## Reload settings from disk and reinit sockets if listen port changed.
  ## Called from main thread after the ObjC settings window writes the JSON file.
  let prevPort = gCfg.lbInPort
  gCfg      = loadSettings()
  gSoundOn  = gCfg.soundOn
  gNotifyOn = gCfg.notifyOn
  gEmailOn  = gCfg.emailOn
  if prevPort != gCfg.lbInPort:
    closeSockets()
    try: initSockets(); result = 1
    except: result = 0
  else:
    result = 1

# ─── Entry point ──────────────────────────────────────────────────────────────
when isMainModule:
  # Must be set before loadSettings() so resourceDir() points at Contents/Resources/
  gResourceDir  = $mac_resource_dir()
  gCfg      = loadSettings()
  gSoundOn  = gCfg.soundOn
  gNotifyOn = gCfg.notifyOn
  gEmailOn  = gCfg.emailOn

  try:
    initSockets()
  except OSError:
    let msg = "Could not bind UDP port " & $gCfg.lbInPort &
              ". Is another instance already running?"
    discard execCmd("osascript -e 'display alert \"LightBurn Monitor\" " &
                    "message \"" & msg & "\"'")
    quit(1)

  mac_setup(gCfg.pollSecs, gCfg.completeSecs)
  mac_run()   # enters [NSApp run] — blocks until mac_quit() is called
