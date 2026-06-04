# Package
version       = "1.0.0"
author        = "bunkford"
description   = "Menu-bar / system-tray monitor for LightBurn laser software"
license       = "MIT"
srcDir        = "."
bin           = @["lightburn_tray", "lightburn_tray_mac"]

# Dependencies
requires "nim >= 1.6.0"
requires "wnim >= 0.13.0"
