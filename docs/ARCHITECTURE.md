# Architecture

Reelbird is a native macOS app (Swift 6, SwiftUI + AppKit, Metal) with a command line tool that shares the same engine. It has no server and no third-party Swift dependencies.

```
ReelbirdCore     project format, edit document, events, timeline + motion maths (pure Swift)
ReelbirdCapture  ScreenCaptureKit, camera, microphone, input events, segmented writers, health checks
ReelbirdRender   Metal compositor, preview player, exporter
ReelbirdShare    S3-compatible uploads (SigV4), HLS playlists, static viewer page, Keychain config
ReelbirdAI       on-device captions (SpeechAnalyzer), titles/chapters (Foundation Models), silence detection
ReelbirdApp      the Mac app
ReelbirdCLI      `reelbird` command line tool + MCP server
```

Dependencies flow inward: every module depends on `ReelbirdCore` and nothing else, except the app and the CLI, which compose all of them.

## Recording

One host clock (`CMClockGetHostTimeClock`) drives everything. Timeline zero is the host time of the first screen frame. Media, input events and edits all use seconds on that timeline.

- **Screen:** `SCStream` in `420v` (NV12) at native pixel size. The system cursor is hidden and re-drawn later from the event log. Hardware HEVC (H.264 for the compact preset).
- **Audio:** microphone and system audio captured by ScreenCaptureKit on the same clock (macOS 15+), as separate AAC tracks.
- **Camera:** its own track, so layout can change after recording.
- **Events:** pointer position (sampled at 120 Hz), clicks, scrolls, cursor image changes, optional keystrokes and focused-element frames go to `events.jsonl`.
- **Segments:** every track is written by `AVAssetWriter` as fragmented MP4 with 2-second segments delivered through the writer delegate and written to disk as they arrive. A crash loses at most the segment in progress. Stopping concatenates the segments into one file per track (no re-encoding).
- **Pause:** samples are dropped while paused; the paused ranges go into `project.json` and become cuts in the edit.
- **Health:** the recorder warns while recording if the microphone delivers silence, frames stall, audio drifts, the disk fills up, or uploads fall behind.

## Sharing

Sharing is optional and serverless: the app uploads to an S3-compatible bucket you own (Cloudflare R2 recommended, free egress).

1. When recording starts, the app reserves a short ID and uploads a placeholder viewer page, so the link exists before the first frame.
2. While recording, a second writer produces a 1080p H.264 stream (screen + camera bubble + mixed audio) in 2-second CMAF segments, uploaded as they are written, plus an HLS playlist that grows (`EVENT`).
3. On stop, the link is copied immediately; the last segment and the end marker follow within about a second.
4. After editing, "Update link" uploads the polished MP4 and the viewer page switches to it. The link never changes.

Bucket layout: `r/<id>/index.html` (viewer), `r/<id>/meta.json`, `r/<id>/hls/` (playlist + segments), `r/<id>/video.mp4` (polished), `r/<id>/poster.jpg`, `r/<id>/captions.vtt`.

## Editing and rendering

`edit.json` holds every decision; media is never modified. A render plan is computed once from the manifest, edit and events: the zoom camera path (log-scale zoom, critically damped spring, anchored on the focus point), the smoothed cursor path (resampled, spring-damped) and click effects. The plan is deterministic, so preview and export always match. One Metal compositor draws both: background, padded rounded screen with shadow, zoom, cursor, click effects, camera bubble, annotations, captions.

Export reads tracks with `AVAssetReader`, composites on the GPU and encodes with VideoToolbox through `AVAssetWriter` (H.264, HEVC, ProRes) or ImageIO (GIF).

## Project format

See [FORMAT.md](FORMAT.md).
