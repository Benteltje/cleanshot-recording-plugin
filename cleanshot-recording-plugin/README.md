# CleanShot Recording

A DynamicLake JSON plugin that shows a CleanShot X screen-recording indicator in
the notch and a recording card in the lake with a live timer and a red stop
button.

## Features

- Appears automatically while CleanShot X is recording the screen.
- Live activity shows only a red dot (and the activity name when expanded) —
  no timer, no sneak peek.
- Lake card shows a red dot + red elapsed timer, the "Screen Recording" label,
  and a red stop button.
- Pressing the stop button stops the active CleanShot X recording through
  Accessibility (toolbar stop button, with menu-extra fallback).
- Card dismisses and clears itself shortly after recording ends.

## Files

| File | Purpose |
| --- | --- |
| `plugin.json` | DynamicLake plugin manifest |
| `main.swift` | Swift source for the native monitor |
| `cleanshot-monitor` | Native macOS monitor (executable) |
| `icon.png` | Plugin icon |

## Requirements

- macOS with DynamicLake Pro
- CleanShot X
- Accessibility permission for the plugin process (needed to press stop)

## Install

Install the packaged `.dynamiclakeplugin` bundle with DynamicLake Pro, or place
this folder under:

```
~/Library/Application Support/DynamicLake/Plugins/JSON/
```

`cleanshot-monitor` must be executable (`chmod +x`). Python is not required.

## Rebuild

On Apple silicon Macs, rebuild the executable from source with:

```sh
swiftc -O -target arm64-apple-macosx13.0 -framework ApplicationServices main.swift -o cleanshot-monitor
```

## How it works

The monitor keeps a JSON socket connection to the host and polls `lsof` for a
video file that CleanShot X has open for writing. While such a file exists the
plugin publishes a notification-lake card. Pressing the stop button sends an
Accessibility action to CleanShot X's recording toolbar. When the file is closed
the card is cleared and the activity dismissed.

## License

Proprietary — All Rights Reserved. Copying, modification, redistribution, or
reuse of any part of this project is prohibited. See [LICENSE](LICENSE).
