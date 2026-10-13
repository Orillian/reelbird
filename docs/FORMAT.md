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
  analysis.json     optional cache: loudness, noise floor and speech ranges of the audio (AudioAnalysis)
  voice/            optional cache: the enhanced voice stem (voice-<hash>.caf + stem.json)
  crop-suggestion.json  optional cache: the detected browser toolbar (CropSuggestion)
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

## Crop

`edit.json → crop` is the part of the screen video that stays visible, normalized to the screen video with a top-left origin: `{"x": 0, "y": 0.08, "width": 1, "height": 0.92}`. Absent or `null` = the whole screen. The media is never changed.

- Readers are lenient: a missing `x`/`y` is 0 and a missing `width`/`height` reaches the right/bottom edge (`{"y": 0.08}` hides the top 8%); values are clamped inside the screen with a 5% minimum side; anything unusable, or a crop of the whole screen, reads as no crop.
- Event positions, annotation `rect`s and zoom `focus` points stay in full-screen coordinates, so changing the crop never moves them off the content they point at. The renderer maps them into the crop.
- The output canvas follows the crop (aspect `source` = the crop's pixel size); zooms and the camera work inside it; automatic zooms ignore clicks, typing and focus outside it; the cursor and click effects fade out within 6 points past a cropped edge. Captions, keystrokes and the camera bubble sit on the canvas as before. Posters, preview and export all apply it.

`crop-suggestion.json` caches the browser toolbar found in the screen video (`reelbird edit --crop-toolbar` and the editor's Hide Browser Toolbar use it). Detection needs no permission: 16 frames spread over the recording are decoded at full height (at most 480 columns, luma); per row it measures the change between neighbouring samples and the share of the width with a horizontal edge above it. The toolbar is the deepest full-width edge inside the still band at the top, 40–220 points tall and at least 3% of the height, with the content below it changing. Without such an edge the end of the still band is used with confidence ≤ 0.45. The editor offers the crop at confidence ≥ 0.6. Ignored when `version`, `file` or `fileSize` don't match the screen video; deleting it is always safe.

```json
{"version": 1, "file": "screen/screen.mp4", "fileSize": 48213377, "height": 2234, "topPixels": 214, "confidence": 0.93, "seconds": 0.41}
```

## Audio

`edit.json → audio` holds `autoLevel` (default `true`), `microphoneGainDB` (the Boost, added on top of auto level), `systemGainDB`, `microphoneMuted`, `systemMuted`, and the voice cleanup: `enhance` (default `true`), `enhanceStrength` (`light`, `medium` (default), `strong` or `max`: noise reduction capped at 6, 12, 24 dB or uncapped), `enhanceMix` (0 = original … 1 = fully enhanced, default 1) and `duckSystemAudio` (default `true`: system audio dips about 12 dB while the voice speaks, starting 20 ms before each phrase and recovering over 600 ms). Export applies each track's gain, a look-ahead limiter per track, sums them, and limits the sum, with a −1.5 dBFS ceiling on samples and estimated inter-sample peaks (AAC overshoots heavily limited peaks a little; decoded exports stay under −1 dBFS). The editor's preview runs the same per-track stage, so it sounds the same.

`analysis.json` caches the measurements so they are made once per voice file (one decode at 16 kHz mono per track, about 0.3 s for 8 s of audio in a debug build). `microphone` is the voice as it plays: the voice stem when enhance is on and a stem exists, else the raw track; `rawMicrophone` is the raw track, measured too when the stem plays (for the loudness-matched "Hear original"); `systemAudio` lets ducking skip a silent system track:

```json
{
  "version": 2,
  "microphone": {
    "file": "voice/voice-3f2a9c01d4.caf",
    "fileSize": 1234567,
    "integratedLUFS": -19.4,
    "peakDBFS": -6.8,
    "noiseFloorDB": -71.2,
    "duration": 312.5,
    "speech": [{"start": 0.84, "end": 4.31}, {"start": 5.02, "end": 9.77}]
  },
  "rawMicrophone": {"file": "microphone/microphone.m4a", "fileSize": 2345678, "integratedLUFS": -31.4, "noiseFloorDB": -52.0, "…": "…"},
  "systemAudio": {"file": "systemAudio/systemAudio.m4a", "…": "…"}
}
```

`integratedLUFS` is ITU-R BS.1770 integrated loudness (K-weighted, 400 ms blocks, −70 LUFS absolute and −10 LU relative gates) as heard on two speakers: the mono voice plays on both channels, so it is the mono measurement + 3 dB. It is `null` when the track is silent. Auto level gain = −16 − `integratedLUFS`, capped to −6…+18 dB (0 when silent). The file is ignored, and the voice measured again, when `version` differs or `file` / `fileSize` no longer match the voice file. Deleting it is always safe.

`noiseFloorDB` is the 10th percentile of 10 ms frame levels (mono dBFS, after a 100 Hz high-pass). `speech` (voice only) holds where someone is speaking, in seconds from the file's first sample: an energy detector (9 dB over the noise floor, within 40 dB of the loud speech level, 30 ms onset, 150 ms hangover, gaps under 200 ms bridged). Ducking keys on it.

### Voice stem (`voice/`)

When `enhance` is on, the microphone track is rendered once into an enhanced copy that preview, export and auto level use instead; the raw track is never changed (captions keep transcribing it). Rendering runs after the recording opens in the editor, whenever the enhance settings change, before an export that needs it, or with `reelbird enhance`. The chain, mono at the microphone's own sample rate: 18 dB/oct high-pass at 80 Hz (100 Hz for inputs at 24 kHz or less, i.e. Bluetooth headsets) → noise removal (Apple's AUSoundIsolation, HighQualityVoice model), blended with its input so removed noise drops by at most the strength's cap → downward expander (2:1, at most 10 dB, threshold just above the remaining noise) → compressor (3:1 above the speech level, 8 ms / 120 ms) → de-esser (5–9 kHz detection, at most 6 dB) → presence EQ (+2 dB at 4 kHz, +1.5 dB shelf at 10 kHz) → blend with the raw track by `enhanceMix`. The denoiser's delay is removed exactly, so the stem lines up sample for sample with the raw track and has the same length.

- `voice-<hash>.caf`: mono Apple Lossless (24-bit) at the microphone's sample rate. A new render gets a new name and older ones are deleted.
- `stem.json` (`VoiceStemInfo`): `version` (the chain version), `engine` (`AUSoundIsolation.hq`, or `none` when no denoiser is available), `settingsHash` (strength, mix rounded to 0.01, source file and size, chain version), `strength`, `mix`, `sourceFile`, `sourceSize`, `file`, `sampleRate`, `frames`, `latencyFrames` (the delay that was removed), `highPassHz`, `renderSeconds`, `createdAt`.

A stem plays while it was made from the current microphone file and chain version, even with older settings, until the new one is ready. Deleting `voice/` is always safe.

## Status

`project.json → status` is `recording` while a take is being written, `complete` after a clean stop and `recovered` after a crash recovery. If the project was shared, `share` holds its key, link and last update.

## Recovery

If the app stops while recording, `project.json` still says `"status": "recording"`. On next launch (or with `reelbird recover PROJECT`) the segments on disk are concatenated, a truncated last segment is dropped, the duration is recomputed, and the status becomes `recovered`.
