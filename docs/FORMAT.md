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
  share/            the quick-share stream (optional; its timeline skips paused ranges)
  captions.vtt      optional
  transcript.json   optional, word-timed transcript behind captions.vtt (source timeline)
  analysis.json     optional cache: measured loudness of the voice (AudioAnalysis)
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

## Audio

`edit.json → audio` holds `autoLevel` (default `true`), `microphoneGainDB` (the Boost, added on top of auto level), `systemGainDB`, `microphoneMuted` and `systemMuted`. Export applies each track's gain, a look-ahead limiter per track, sums them, and limits the sum, with a −1.5 dBFS ceiling on samples and estimated inter-sample peaks (AAC overshoots heavily limited peaks a little; decoded exports stay under −1 dBFS). The editor's preview runs the same per-track stage, so it sounds the same.

`analysis.json` caches the voice measurement so it is made once per recording (one decode at 16 kHz mono, about 0.3 s for 8 s of audio in a debug build):

```json
{
  "version": 1,
  "microphone": {
    "file": "microphone/microphone.m4a",
    "fileSize": 1234567,
    "integratedLUFS": -31.4,
    "peakDBFS": -9.8,
    "duration": 312.5
  }
}
```

`integratedLUFS` is ITU-R BS.1770 integrated loudness (K-weighted, 400 ms blocks, −70 LUFS absolute and −10 LU relative gates) as heard on two speakers: the mono voice plays on both channels, so it is the mono measurement + 3 dB. It is `null` when the track is silent. Auto level gain = −16 − `integratedLUFS`, capped to −6…+18 dB (0 when silent). The file is ignored, and the voice measured again, when `version` differs or `file` / `fileSize` no longer match the voice file. Deleting it is always safe.

## Status

`project.json → status` is `recording` while a take is being written, `complete` after a clean stop and `recovered` after a crash recovery. If the project was shared, `share` holds its key, link and last update.

## Recovery

If the app stops while recording, `project.json` still says `"status": "recording"`. On next launch (or with `reelbird recover PROJECT`) the segments on disk are concatenated, a truncated last segment is dropped, the duration is recomputed, and the status becomes `recovered`.
