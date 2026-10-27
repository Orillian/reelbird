# The `.reelbird` project format

A project is a directory (a macOS package) with only relative paths inside, so it can be moved, zipped or committed.

```
Demo.reelbird/
  project.json      what was recorded (ProjectManifest)
  edit.json         every edit (EditDocument)
  events.jsonl      one input event per line
  cursors/          cursor images (<id>.png at 2x) + cursors.json
  screen/           screen.mp4 (while recording: init.mp4, seg_00001.m4s, …, index.m3u8)
  camera/           same layout (optional)
  microphone/       same layout, audio only (optional)
  systemAudio/      same layout, audio only (optional)
  share/            the quick-share stream (optional; its timeline skips paused ranges)
  .lock             empty lock file (see Recovery)
  .edit.lock        empty lock file, held while edit.json is checked and written
  captions.vtt      optional
  transcript.json   optional, word-timed transcript behind captions.vtt (source timeline)
  analysis.json     optional cache: loudness, noise floor and speech ranges of the audio (AudioAnalysis)
  voice/            optional cache: the enhanced voice stem (voice-<hash>.caf + stem.json)
  crop-suggestion.json  optional cache: the detected browser toolbar (CropSuggestion)
  steps.json        optional cache: the guide's steps read from the screen (StepDocument)
  exports/          rendered files
```

`edit.json` also carries `revision`, a counter every writer (the editor, `reelbird edit`, MCP `set_edit`) raises by one, so an editor with the project open notices outside changes. Every writer takes an advisory `flock` on `.edit.lock` (waiting up to 10 s) while it reads the revision, checks it and writes, so two writers starting from the same revision can't both succeed; `reelbird` and MCP changes read `edit.json`, apply their change and write under that lock, so they never overwrite a change saved in between. It picks them up straight away when it has no unsaved changes of its own, and merges them setting by setting when it does. Where both changed the same setting, the editor's choice stays and the other version is saved next to it as `edit.outside-<date>-<time>.json`. Closing the editor writes `edit.json` only if something changed there.

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
{"t":6.120,"type":"camera","x":0.0521,"y":0.0926,"rect":{"x":0,"y":0,"width":0.1042,"height":0.1852},"shape":"circle"}
{"t":9.800,"type":"camera","x":0.0521,"y":0.0926,"rect":{"x":0,"y":0,"width":0.1042,"height":0.1852},"shape":"circle","layout":"fullCamera"}
{"t":8.400,"type":"marker"}
{"label":"Checkout","t":12.750,"type":"marker"}
```

`button` is 0 for left, 1 for right, 2 for other. `key` events appear only when keystroke recording was on; for a window recording, only keys typed while that window's app was in front. `cursor` names a file stem in `cursors/`. `camera` is the live camera bubble (recordings with a camera): logged when recording starts (`t` 0, where the bubble was when the countdown ended), then whenever a drag or a resize ends, on the same clock as the pointer; a move made while paused is logged at the resume. `rect` is the bubble's frame and `x`, `y` its centre, normalized to the captured area and moved to the nearest place fully inside it (a bubble beside a recorded window or area, or on another display, lands at its edge); `shape` is its shape. `layout` is the live camera layout switched with the layout shortcut (`overlay`, `fullCamera` or `screenOnly`); it is logged as a `camera` event at the switch (one made while paused at the resume) and written on every `camera` event after the first switch, so logs from takes that never switched (and older ones) have none, which means `overlay`. `marker` is a marker dropped while recording (the marker shortcut, the control bar's flag or MCP `add_marker`), on the same clock; `label` is its name when one was given, otherwise it reads as "Marker N" (N counts markers in time order). A marker dropped while paused keeps its time inside the pause. Versions without markers skip these lines. A `focus` event with a `rect` (normalized) is reserved for focused-element frames; current builds don't write it.

## Camera

`edit.json → camera` places the camera bubble, an overlay on the output canvas (it never zooms with the screen):

```json
{"visible": true, "shape": "circle", "size": 0.22, "corner": "bottomRight", "inset": 0.025,
 "x": 0.5, "y": 1, "moves": [{"t": 12.4, "x": 0, "y": 0}], "mirror": true, "blurBackground": false,
 "shrinkWhenZoomed": true, "sizeWhileZoomed": 0.7, "smartFraming": true}
```

- `shape`: `circle` (default), `roundedSquare` (a square with continuous "squircle" corners: superellipse arcs of exponent 4 with a radius of 31% of the side, like a macOS app icon) or `portrait` (a 3:4 tile with the same corners). Older files' `roundedRect` reads as `roundedSquare`. The camera frame is cropped around its centre to the shape's aspect, never stretched.
- `size`: the circle's diameter (and the square's side) as a fraction of the canvas's shorter side. The portrait tile is 1.15 × that tall and 3:4, about the same area.
- `x`, `y`: where the bubble sits, 0…1 across the room it can move in: 0 = against the left (top) edge at `inset`, 1 = against the right (bottom) edge, 0.5 = centred. The corners are (0, 0), (1, 0), (0, 1), (1, 1). Measured in that room, the bubble keeps its spot relative to the frame through any aspect, padding, crop or zoom, and never leaves the canvas. Either may be absent: it then comes from `corner` (`topLeft`, `topRight`, `bottomLeft`, `bottomRight`), so files written before free placement place it exactly as before.
- `moves`: changes of place on the recording timeline, sorted by `t`: from `t` the bubble glides to (`x`, `y`) over 300 ms (cubic ease in and out); a move that starts mid-glide sets off from wherever the bubble is. Empty = it stays in one place.
- `inset`: the gap to the edge it is against, as a fraction of the shorter side (default 0.025).
- `shrinkWhenZoomed` (default `true`) and `sizeWhileZoomed` (0.4…1, default 0.7; values outside are clamped): while the screen is zoomed in, the bubble's size is `size × lerp(1, sizeWhileZoomed, p)`, where `p` = ln(zoom scale) / ln(the zoom region's depth), clamped to 0…1. So it shrinks and grows back on the zoom's own curve, staying against the same edges (its place doesn't change).
- `smartFraming` (default `true`): for each zoom, the renderer samples the zoom's focus (its fixed `focus`, or the smoothed cursor for a following zoom) every 1/15 s while it holds, on the output canvas. When a point falls under the bubble (at its zoomed size, plus 2% of the shorter side), the bubble goes to the nearest corner that covers fewer of them, gliding over the zoom's own transition in (and back over its transition out, on the same curve); back-to-back zooms that pick the same corner keep it there. Nothing is stored: it follows the zooms and the cursor.

Older files have none of these keys and read with the defaults.

## Layouts

`edit.json → layouts` changes how the screen and the camera share the frame for parts of the recording (recording timeline, sorted, no overlaps). Outside every segment the camera is the overlay bubble above. Absent or empty = the bubble throughout. Layouts need a camera track and `camera.visible`.

```json
"layouts": [{"id": "k3r9xq", "range": {"start": 4.0, "end": 9.5}, "kind": "split"},
            {"id": "p2m7aa", "range": {"start": 21.2, "end": 25.0}, "kind": "fullCamera"}]
```

- `kind`: `fullCamera` (the camera fills the canvas, an aspect-fill crop around its centre), `split` (screen card and camera panel on the background: side by side with the camera taking 34% of the padded width on the right when the canvas is at least as wide as it is tall, stacked with the camera taking 34% of the padded height below otherwise; they share the padding, a gap of max(2% of the shorter side, half the padding) and the card's corner radius, the panel matches the card's height (width) and the pair is centred; the zoomed screen stays inside its card), `screenOnly` (the camera steps away: it shrinks to 60% as it fades) or `overlay` (the bubble; the same as no segment).
- Changes take 0.5 s on a critically damped spring (`Spring.ease`, ωT = 6), centred on the segment's edge; edges closer than that share the time between them. A segment that starts at 0 is there from the first frame, one that ends at the end of the recording stays to the last. Between back-to-back segments the change is direct. During a change the camera tile (position, size, corner radius, opacity) and the screen card blend, and the screen gets the usual motion blur as it slides.
- Readers drop segments they can't read (an unknown `kind` from a newer version) and tidy the rest: times clamped to ≥ 0, segments under 0.2 s dropped, an overlap ending where the next segment starts.

The first time a recording opens, the layouts switched while recording become segments: from each switch (the `layout` of the `camera` events) to the next, or to the end, for every stretch that wasn't the bubble.

The first time a recording opens (no `edit.json` yet), the place comes from its `camera` events: the first is the start place, each later one a move. The recorded frame maps to `x`, `y` by how far the bubble was across the room it could move in on the visible screen, measured with the same proportional inset; within 2% of an edge (1% of the centre) it lands exactly there. So the live bubble's default spot, bottom right at 2.5% of the screen's shorter side, becomes the editor's default corner. The shape follows the live bubble's, and `size` is the live size it had longest, measured against the captured screen and scaled to the padded screen card, so the bubble keeps its size relative to the screen.

## Parts and cuts

`edit.json → splits` holds the split points (recording timeline, sorted; absent in older files). They change nothing in the output on their own: the editor divides the recording into parts at the split points, the edges of `cuts` and the trim (`Parts`). A click selects a part. Delete adds its range to `cuts`, which removes it from every track at once, so screen, voice, camera, zooms and overlays stay in sync. Dragging a part's edge inward cuts what it passes over. Dragging it outward brings back cut footage next to it, and at the recording's ends it moves `trim`. The editor's timeline closes cuts up (`CutSpace`): a cut takes no room and shows as a scissors chip at its join that restores it.

## Speed

`edit.json → speed` plays parts of the recording faster or slower. Files without it play at normal speed throughout.

```json
{"segments": [{"id": "k3v9qa", "range": {"start": 12.4, "end": 19.8}, "rate": 4, "source": "typing"},
              {"id": "p0x2mf", "range": {"start": 31, "end": 33.5}, "rate": 0.5, "source": "user"}],
 "keepFastAudio": false}
```

- `range` is on the recording timeline, like cuts. `rate` is 0.25…8 (2 = twice as fast); values outside are clamped. `source` is `user` (added by hand), `typing` or `idle` (an applied "speed up typing" suggestion; it is an ordinary segment from then on). An unknown `source` reads as `user`.
- Segments are kept sorted and never overlap: readers trim an overlapped segment (the later one in the list wins), drop rate-1 segments and ones shorter than 0.1 s, and skip a segment they can't read rather than the whole list.
- The output timeline is the kept part of the recording (trim and cuts) played back to back, each stretch at its rate. One mapping (`EditTimeline` in `Sources/ReelbirdCore`) turns recording time into output time and back for everything: preview, export, the editor's timeline and duration, ducking, captions and `transcript.json` remapping, chapters and share renders. Zoom regions, cursor and keystroke events, camera moves, annotations and captions stay on the recording timeline; they play faster or slower with the part they're in.
- Sound: up to 2× it is time-stretched with its pitch kept (AVFoundation's spectral algorithm, chosen by measurement). Faster than 2×, the microphone and system audio are silent there, with 12 ms fades, unless `keepFastAudio` is `true`. Microphone and system audio are stretched by the same edits as the video, so they stay in sync.

Speed-up suggestions (the editor's Speed Up Typing, `reelbird speedup`, MCP `suggest_speedups`) come from the event log and the voice: continuous typing (key presses at most 1.2 s apart, at least 3 s from first to last) at 4×, or 2× when someone talks over more than a quarter of it; idle stretches (at least 4 s with no click, scroll, key press or pointer movement, and silent by the same detector as Cut Long Silences) at 8×, keeping 0.4 s at normal speed at each end. Parts that are trimmed, cut or already have a speed are left out.

## Markers

`edit.json → markers` holds the markers once they are renamed, deleted or added in the editor: `[{"id": "m1", "t": 8.4, "title": "Marker 1"}]`, `t` on the recording timeline. Absent (older files, or nothing changed yet) = the `marker` events in `events.jsonl`, with IDs `m1`, `m2`, … in time order; `[]` = every marker deleted. A value that can't be read counts as absent.

Use Markers as Chapters (editor, `reelbird markers --as-chapters`, MCP `list_markers` with `as_chapters`) replaces `chapters` with one per marker. A marker in a cut or a pause moves to where the video carries on, one past the end is dropped, markers less than a second apart in the edited video merge (the first title wins), and when the first marker comes more than a second in, a "Start" chapter opens the list.

## Guide

Every take has a step guide: each click, run of typing and shortcut in `events.jsonl` becomes a step, with what was clicked (read from the screen video on the Mac), what was said around it and an instruction. The editor's Guide panel, `reelbird steps`, `reelbird guide` and MCP `get_steps` / `describe_take` / `export_guide` show it; share links carry it as Guide and Click-through views.

`edit.json → guide` holds what the link gets and the steps changed by hand:

```json
"guide": {"share": true, "copyText": true, "showTypedText": false,
          "edits": [{"id": "c4210", "text": "Open the Inbox"}, {"id": "c9876", "hidden": true}]}
```

- `share` (default `true`): publish the guide with the link. `copyText` (default `true`): publish the text layer, so viewers can select text in the paused video.
- `showTypedText` (default `false`): typing steps quote what was typed. Otherwise they name the field ("Type in \"Email\""). Text that looks like an email, key, card or phone number is masked, and nothing typed while a blur is on screen is ever quoted.
- `edits`: per step ID, a replacement `text` and/or `hidden: true`. Unknown IDs are kept, since the step can come back on a later scan. A missing `guide` reads as the defaults.

How steps are made (`StepExtractor`, pure):

- A left mouse down is a click; two within 0.4 s and 1.5% of the screen are a double-click; button 1 is a right-click; a press that moves more than 3% before release is a drag. Clicks on the same spot within a second merge (`count`).
- Keys with ⌘, ⌃ or ⌥ are shortcuts (the same one in a row merges). Plain keys in runs with gaps of at most 1.5 s are typing, folded into the click just before (within 10 s) as typing into that field; ⏎ or ⇥ right after ends it ("then press Return"). A lone ⏎, ⇥ or ⎋ is a key step. Arrows and page keys are not steps. Typing and shortcuts need keystroke recording.
- IDs are stable: `c` (pointer), `t` (typing with no click before it) or `k` (keys) plus the time of the first event in milliseconds.
- What was clicked: the frame just before the click is read with Vision (accurate, language correction on) in a 640 × 240 pixel window around the pointer; the label is the smallest text box under the pointer (8 px of slack), else the nearest text within 90 px, counting text on the same row as half as far. A line cut off by the window is read again across the whole frame width.
- For the edit (`GuideSteps.resolve`): steps in trimmed, cut or paused time, or outside the crop, are left out; hidden steps go; a label under a blur is dropped (with the model's sentence); narration is what was said, a sentence at a time, from 1.5 s after the previous step to 1.5 s after this one; the last marker since the previous step names a section.
- Wording: a hand edit, else the on-device model's sentence (macOS 26+, only for steps with narration, and only when it still names the label in quotes), else the template: `Click "Inbox"`, `Click next to "…"` (a checkbox beside its text), `Double-click`, `Right-click`, `Drag`, `Click here` (no label), `Type "…" in "Email"`, `Press ⌘S`, `(3 times)`.

`steps.json` caches the scan (labels and model wording) for the recording: `version`, `inputs` (the sizes of `events.jsonl`, the screen video and `transcript.json`, and the screen video's path), `writer` (`template` or `model`) and `steps` (`GuideStep`: `id`, `kind`, `t`, `imageTime`, `point`, `label`, `labelRect`, `typed`, `keys`, `count`, `modelText`). It is ignored when `version` or `inputs` differ, and deleting it is always safe.

Step images are rendered on demand, never stored in the bundle: the frame just before each action through the same renderer as the video, with the crop, blurs and drawn overlays but no zoom, camera, background, captions, keystrokes or cursor, at most 1600 pixels wide.

## Zooms

`edit.json → zoom` holds the zoom mode (`auto`, `manual` or `off`), the auto-zoom `intensity` (0 = subtle … 1 = punchy) and the zoom `regions`:

```json
{"id": "auto-3", "range": {"start": 12.4, "end": 15.1}, "scale": 1.8, "focus": {"x": 0.62, "y": 0.31},
 "source": "auto", "enabled": true, "instant": false}
```

- `scale`: magnification (1 = none); the editor offers 1.1…3.5. `focus`: a fixed point in full-screen coordinates, or absent to follow the cursor.
- `source`: `auto` (planned from clicks and typing; replaced whenever automatic zooms are planned again) or `user` (added or changed by hand; always kept, and automatic zooms never overlap it). Changing an automatic zoom in any way, in the editor or with `reelbird edit` / MCP `set_edit`, makes it `user`.
- `enabled`: `false` turns the zoom off without deleting it. It stays in the edit (dimmed on the timeline), isn't rendered, and still keeps automatic zooms away from its moment. Absent = `true`.
- `instant`: `true` cuts straight in at `start` and out at `end`, with no zoom animation and no motion blur across the cut. Absent = `false` (the animated zoom). A cut lands on the renderer's 120 Hz camera grid, so it is exact to within about 8 ms.

Both flags were added after the first release: files without them open as before (every zoom on and animated), and older versions ignore them. A region missing `id`, `scale` or `source` reads with a new id, 1.8× and `user`.

## Annotations

`edit.json → annotations` holds the overlays drawn on the screen video: privacy blurs, arrows, boxes, text labels and highlights. Each has an `id`, a `kind`, a `range` on the recording timeline, and a `rect` in full-screen normalized coordinates (top-left origin), so it stays on the content it marks through zoom, crop, padding, aspect and camera layouts.

```json
{"id": "k3P9xq", "kind": "blur", "range": {"start": 5, "end": 12}, "rect": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.05},
 "color": {"r": 1, "g": 0.353, "b": 0.212, "a": 1}, "style": "pixelate", "strength": 0.5}
{"id": "s1f2e3d4", "kind": "blur", "range": {"start": 19.5, "end": 36}, "rect": {"x": 0.07, "y": 0, "width": 0.5, "height": 0.56},
 "color": {"r": 1, "g": 0.353, "b": 0.212, "a": 1}, "detected": "apiKey",
 "keys": [{"t": 19.5, "rect": {"x": 0.07, "y": 0.52, "width": 0.5, "height": 0.04}}, {"t": 20, "rect": {"x": 0.07, "y": 0.5, "width": 0.5, "height": 0.04}}]}
{"id": "a8Tm2c", "kind": "arrow", "range": {"start": 3, "end": 6}, "rect": {"x": 0.55, "y": 0.45, "width": 0.25, "height": 0.35},
 "color": {"r": 1, "g": 0.353, "b": 0.212, "a": 1}, "tail": {"x": 0.8, "y": 0.8}, "head": {"x": 0.55, "y": 0.45}}
{"id": "t0Lq7w", "kind": "text", "range": {"start": 3, "end": 6}, "rect": {"x": 0.6, "y": 0.7, "width": 0.19, "height": 0.057},
 "color": {"r": 1, "g": 0.353, "b": 0.212, "a": 1}, "text": "New billing page", "fontSize": 0.03}
```

- `kind`: `blur`, `arrow`, `box`, `text` or `highlight` (dims everything around `rect`). `color` applies to arrows, boxes and text labels; it defaults to coral when absent.
- `style` (blur): `blur` (default), `pixelate` or `solid` (a flat bar in `color`, near-black by default). `strength` (blur): 0…1, default 0.5.
- `shape` (blur): `rectangle`, `rounded` (default) or `oval`. `softness` (blur): 0…1, default 0. The edge fades out *past* the area over up to 3% of the frame's shorter side; the area itself is always fully covered. Cells are anchored to the screen video and measured in its pixels: a side of at least 9 to 18 points (by strength) and a quarter to half of the area's shorter side. Each cell is reduced to one averaged colour (pixelate shows the cells; blur draws a smooth B-spline through them), so the content under a blur can't be recovered at any strength or zoom. A blur doesn't fade in or out: it covers its whole range.
- `tail`, `head` (arrow): where it starts and where its head points. Absent = from `rect`'s top-left to its bottom-right (files written before arrows had ends). `rect` is their bounding box.
- `text`, `fontSize` (text): the label and its letter size as a fraction of the screen video's height. Absent `fontSize` = 0.7 × `rect.height` (older files). The label is drawn in `color` with white text (ink on light colours), its left edge at `rect.x` and centred on `rect`'s middle; the editor sizes `rect` to the label.
- `keys`: where the area is over time, sorted by `t` (written by Find Sensitive Info for text that moves). Before the first key the first area is used, after the last the last; between two keys the blur covers both areas, so text moving between two samples stays covered. `rect` is then the area covering every key, which older versions blur for the whole range.
- `detected`: what Find Sensitive Info found (`email`, `apiKey`, `card`, `phone`, `custom`); absent for overlays added by hand. Its blurs use the finding's `id`, so scanning again doesn't suggest it twice.

Everything except `id`, `kind`, `range` and `rect` was added after the first release and is left out when unset; files without these keys open as before, and older versions ignore them. Out-of-range values are clamped instead of failing the document.

### Find Sensitive Info

Find Sensitive Info (the editor's Overlays panel, `reelbird redact --auto`, MCP `find_sensitive_info`) reads the screen video on the Mac and writes nothing until findings are kept. It decodes the screen track once, in up to four parts in parallel, and samples a frame every 0.5 s. Text recognition (Vision, accurate, no language correction) runs only when the picture changed since the last recognised frame (any 1/160 × 1/100 block of the luma moved by more than 8 levels); otherwise the last results carry over. While a finding is on screen and the picture changes, the band around it is re-read every 0.25 s so the blur follows scrolling. Matches:

- **Emails.**
- **API keys and tokens:** known prefixes (`sk-`, `sk_live_`/`pk_test_`, `ghp_`/`github_pat_`, `AKIA`…, `xox?-`, `AIza`, `glpat-`, `SG.`, `hf_`, `npm_`, `shpat_`, `dop_v1_`, JWTs, private key headers), values after `api_key`, `secret`, `token`, `password`, `bearer`, and high-entropy runs of 20 or more characters (mixed letters and digits that switch case often; hex from 32 characters, except 40-character git commit hashes).
- **Card numbers:** 13–19 digits starting 2–6 that pass the Luhn check.
- **Phone numbers:** 10–15 digits written with separators, or 8–15 after a `+`; not dates, IP addresses or card numbers.
- **Custom words**, without regard to case.

Sightings in neighbouring samples are the same finding when they are the same kind with the same text (one misread character in ten allowed) or in the same place. A finding is hidden from the sample before it was first seen to the sample after it was last seen; its boxes are padded by about a third of a line. Text shown for less than half a second, or partly scrolled off the edge, can be missed: check the result before sharing. On a 60 s 1920 × 1200 test recording with ten fake secrets (static, scrolling and typed), the scan finds all ten, with no false positives, in about 6–8 s on Apple silicon. The first scan by a newly built or installed copy of Reelbird takes about half a minute longer while macOS prepares its text recognizer.

The scan reads the screen video only, not narration, captions or overlays. The keystroke overlay (`cursor.showKeystrokes`) shows shortcuts (⌘, ⌃ or ⌥ held) and special keys (Return, Esc, Tab, arrows); plain typing only with `cursor.showTypedText` (off by default; files from before it existed read it as `showKeystrokes`, which is what they showed). Typed text is never shown while a blur is on screen, nor for keys typed during one.

## Crop

`edit.json → crop` is the part of the screen video that stays visible, normalized to the screen video with a top-left origin: `{"x": 0, "y": 0.08, "width": 1, "height": 0.92}`. Absent or `null` = the whole screen. The media is never changed.

- Readers are lenient: a missing `x`/`y` is 0 and a missing `width`/`height` reaches the right/bottom edge (`{"y": 0.08}` hides the top 8%); values are clamped inside the screen with a 5% minimum side; anything unusable, or a crop of the whole screen, reads as no crop.
- Event positions, annotation `rect`s (and `keys`, arrow ends) and zoom `focus` points stay in full-screen coordinates, so changing the crop never moves them off the content they point at. The renderer maps them into the crop.
- The output canvas follows the crop (aspect `source` = the crop's pixel size); zooms and the camera work inside it; automatic zooms ignore clicks, typing and focus outside it; the cursor and click effects fade out within 6 points past a cropped edge. Captions, keystrokes and the camera bubble sit on the canvas as before. Posters, preview and export all apply it.

`crop-suggestion.json` caches the browser toolbar found in the screen video (`reelbird edit --crop-toolbar` and the editor's Hide Browser Toolbar use it). Detection needs no permission: 16 frames spread over the recording are decoded at full height (at most 480 columns, luma); per row it measures the change between neighbouring samples and the share of the width with a horizontal edge above it. The toolbar is the deepest full-width edge inside the still band at the top, 40–220 points tall and at least 3% of the height, with the content below it changing. Without such an edge the end of the still band is used with confidence ≤ 0.45. The editor offers the crop at confidence ≥ 0.6. Ignored when `version`, `file` or `fileSize` don't match the screen video; deleting it is always safe.

```json
{"version": 1, "file": "screen/screen.mp4", "fileSize": 48213377, "height": 2234, "topPixels": 214, "confidence": 0.93, "seconds": 0.41}
```

## Captions

`transcript.json` (a `Transcript`: `locale` and `segments`, each with `range`, `text`, timed `words` and an optional `hidden`) is the source of truth; `captions.vtt` is made from it, leaving out hidden segments. Correcting a line in the editor keeps each word's time slot when the word count is unchanged; otherwise the new words share the line's span by length.

`edit.captions`:
- `file`: the WebVTT file, bundle-relative (`captions.vtt`), or absent when there are no captions.
- `locale`: the BCP 47 language the transcript was made in.
- `style`: `none`, `classic`, `highlight`, `marker`, `pop`, `oneWord` or `slam`. `none` draws nothing; any other style is drawn into the preview and exports. Classic draws the WebVTT cues; the others draw word groups from `transcript.json` (one breath of speech, at most 6 words or 2.5 s; one or two words for One Word and Slam).
- `palette`: `night`, `reelbird`, `mint`, `paper` or `bare` (no backing, a soft shadow).
- `size`: `small`, `medium` or `large`. `position`: `auto`, `bottom`, `belowVideo` or `top`. Auto uses the padding under the video when there is room, and otherwise the bottom of the frame, moving a caption to the top while the cursor is in the bottom third.
- `uppercase`: capitals for One Word and Slam.
- `burnIn`: written for older versions (true for any style but `none`). Files without `style` read `burnIn: true` as Classic.

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

## Tracks while recording and after

While recording, each track folder fills with fragmented MP4: `init.mp4`, 2-second `seg_NNNNN.m4s` files written as they are produced, and an HLS playlist `index.m3u8`. Stopping concatenates them into `<track>.mp4` (no re-encoding), flushes it to disk, reads it back to check it and opens it with AVFoundation. Once `project.json` with status `complete` is safely on disk, the segment files are deleted, so a finished project holds one file per track. `share/` keeps its segments until its live upload has finished (an interrupted upload resumes from them), then they go too. A track whose segments couldn't all be used (a damaged one) keeps them.

## Writes

`project.json` and `edit.json` are written to a temporary file, flushed and renamed over the old one, so a crash or power cut leaves the old or the new file, never a torn one. While recording (every 2 s) the flush is a write barrier (`F_BARRIERFSYNC`, about 0.5 ms); the final `project.json` of a take and every `edit.json` are fully flushed (`F_FULLFSYNC`, then the folder; about 8 ms).

## Recovery

If the app stops while recording, `project.json` still says `"status": "recording"`. On next launch (or with `reelbird recover PROJECT`) the segments on disk are concatenated, a truncated last segment is dropped, the duration is recomputed, and the status becomes `recovered`. Segments that all went into the rebuilt file are then deleted, as after a normal stop.

If `project.json` itself is unreadable, recovery rebuilds it from what is on disk: tracks from their folders (segments or finished files) and pauses from `events.jsonl`. The capture source, display scale (2) and frame rate (60) aren't stored anywhere else, so those are guesses.

`.lock` is an advisory `flock` shared by the app, the CLI and the MCP server. The recorder holds it for the whole take (including while it consolidates) and recovery holds it while it rebuilds, so two processes never rebuild the same project at once; a second recovery waits and then finds the work done. The file holds what the holder is doing (`recording`, `recovering` or `cleanup`). The system releases it when a process exits, so a crash never leaves a project locked. Don't delete it while Reelbird might be using the project.
