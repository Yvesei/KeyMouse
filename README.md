# KeyMouse

A small native macOS menu bar app that shows battery levels for compatible wireless keyboards and mice. Each available reading appears beside a keyboard or mouse icon. No third-party dependencies or background helper processes are required.

## Build and run

Requires macOS 12 or later and Apple's Command Line Tools.

```sh
bash scripts/build.sh
open "build/KeyMouse.app"
```

Allow Bluetooth access when prompted. Pair and connect your keyboard or mouse in Bluetooth settings and wake it if needed. Open the menu bar item to see device names, refresh readings, or quit. You can move the app to Applications and add it under System Settings → General → Login Items.

The build uses an ad hoc local signature and is not notarized. Rebuild on the target Mac to match its architecture. If you previously used Razer Battery or Peripheral Battery, quit and remove the older app; macOS may ask for Bluetooth permission again for KeyMouse.

## Compatibility

The app reads battery values already exposed by macOS for keyboard and mouse HID devices. It also connects to matching Bluetooth Low Energy devices and reads the standard Battery Service (`180F`) and Battery Level characteristic (`2A19`). It identifies connected keyboards and mice using their HID usage and can discover devices whose Bluetooth names include “keyboard” or “mouse”.

**Not every keyboard or mouse exposes a usable battery level through these interfaces.** Bluetooth Classic, USB receivers, and vendor-specific protocols may require other support, even if macOS or a manufacturer's app shows a battery level. A device may use a Bluetooth name that cannot be matched to its HID name. The app never guesses a percentage. If a device is recognized but does not expose the standard service, its menu entry explains that the reading is unavailable.

## Resource use and privacy

The app refreshes every five minutes, scans for up to five seconds per refresh, and subscribes to battery notifications when available. Readings older than 15 minutes are hidden. Refreshing from the menu and waking the Mac trigger an immediate refresh. No network access, analytics, Input Monitoring, Accessibility permission, administrator access, or third-party services are used.
