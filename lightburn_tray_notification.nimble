# Package
version       = "1.3.0"
author        = "bunkford"
description   = "Menu-bar / system-tray monitor for LightBurn laser software"
license       = "MIT"
srcDir        = "."
bin           = @["lightburn_tray", "lightburn_tray_mac"]

# Dependencies
requires "nim >= 2.2.10"
requires "https://github.com/bunkford/wNim"
requires "smtp"