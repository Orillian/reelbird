# The `.reelbird` project format

A project is a directory (a macOS package) with only relative paths inside, so it can be moved, zipped or committed.

```
Demo.reelbird/
  project.json      what was recorded (ProjectManifest)
  edit.json         every edit (EditDocument)
  events.jsonl      one input event per line
  cursors/          cursor images (<id>.png at 2x) + cursors.json
  screen/           init.mp4, seg_00001.m4s, …, index.m3u8, and screen.mp4 once finished
  camera/           same layout (optional)
  microphone/       same layout, audio only (optional)
  systemAudio/      same layout, audio only (optional)
  share/            the quick-share stream (optional)
  captions.vtt      optional
  transcript.json   optional, word-timed transcript behind captions.vtt (source timeline)
  exports/          rendered files
```

The Swift types in `Sources/ReelbirdCore` are the schema: `ProjectManifest` for `project.json`, `EditDocument` for `edit.json`, `InputEvent` for each line of `events.jsonl`. Readers ignore unknown keys and fill missing keys with defaults, so files written by older or newer versions still open.

## Time

Every time value is seconds on one timeline. Zero is the host-clock time of the first screen frame (`project.json → clock.originHostTime`). Each track's `startTime` says where its first sample sits on that timeline.

## Coordinates

Positions in events and edits are normalized to the captured area: `(0, 0)` top-left, `(1, 1)` bottom-right.

## Events

```json
{"t":1.204,"type":"move","x":0.412,"y":0.233}
{"t":1.311,"type":"down","x":0.413,"y":0.234,"button":0}
{"t":1.398,"type":"up","x":0.413,"y":0.234,"button":0}
{"t":1.650,"type":"scroll","x":0.413,"y":0.234,"dx":0,"dy":-3.5}
{"t":2.010,"type":"key","chars":"s","mods":["⌘"]}
{"t":2.500,"type":"cursor","image":"a1b2c3"}
{"t":3.000,"type":"pause"}
{"t":5.000,"type":"resume"}
```

`button` is 0 for left, 1 for right, 2 for other. `key` events appear only when keystroke recording was on. `cursor` names a file stem in `cursors/`. A `focus` event with a `rect` (normalized) is reserved for focused-element frames; current builds don't write it.

## Status

`project.json → status` is `recording` while a take is being written, `complete` after a clean stop and `recovered` after a crash recovery. If the project was shared, `share` holds its key, link and last update.

## Recovery

If the app stops while recording, `project.json` still says `"status": "recording"`. On next launch (or with `reelbird recover PROJECT`) the segments on disk are concatenated, a truncated last segment is dropped, the duration is recomputed, and the status becomes `recovered`.
