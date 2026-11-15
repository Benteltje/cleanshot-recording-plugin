# CleanShot Recording

A DynamicLake JSON plugin that shows a CleanShot X screen-recording indicator in
the notch and a recording card in the lake with a live timer and a red stop
button. When the recording finishes, the card turns into a preview with a video
thumbnail, duration, filename, and quick actions.

## Features

- Appears automatically while CleanShot X is recording the screen.
- Live activity shows only a red dot (and the activity name when expanded) —
  no timer, no sneak peek.
- Lake card shows a red dot + red elapsed timer, the "Screen Recording" label,
  and a red stop button.
- Pressing the stop button stops the active CleanShot X recording through
  Accessibility (toolbar stop button, with menu-extra fallback).
- While the recording is being saved the stop button becomes a spinner: a
  white arc that keeps turning around the red square, with the card relabelled
  "Saving Recording…", until the preview replaces it.
- After stopping, the live card is replaced by a preview with the recording's
  thumbnail, duration, filename, and folder.
- Preview actions: Watch, Show in Finder, Copy, and Delete. The preview hides
  after about ten seconds, or shortly after the lake is closed.

## Files

| File | Purpose |
| --- | --- |
| `plugin.json` | DynamicLake plugin manifest |
| `cleanshot-monitor` | Swift monitor (executable) |
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

`cleanshot-monitor` must be executable (`chmod +x`).

## How it works

The monitor keeps a JSON socket connection to the host and polls `lsof` for a
video file that CleanShot X has open for writing. While such a file exists the
plugin publishes a notification-lake card. Pressing the stop button sends an
Accessibility action to CleanShot X's recording toolbar. When the file is closed
the plugin waits for CleanShot to finish writing (it renames its temporary `.mov`
to the final `.mp4`), grabs a frame with AVFoundation for the thumbnail, and
swaps the card for the preview. A copy already exported to Desktop, Downloads,
Movies, or Documents is preferred when its duration matches.

## License

Proprietary — All Rights Reserved. Copying, modification, redistribution, or
reuse of any part of this project is prohibited. See [LICENSE](LICENSE).
