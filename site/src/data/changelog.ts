/** Release notes. /changelog and /changelog/rss.xml read this. Newest first. */
export interface Release { version: string; date: string; title: string; summary: string; notes: string[] }

export const RELEASES: Release[] = [
  {
    version: "0.1.0",
    date: "2026-10-12",
    title: "First public release",
    summary: "Reelbird's first open-source release: record, get a link when you stop, polish it later under the same link.",
    notes: [
      "Record a display, a window or an area, with camera, microphone and system audio on separate tracks.",
      "Crash-safe recording in 2-second segments, with recovery on next launch and live warnings for a silent mic, stalls, drift, low disk and upload lag.",
      "Share while recording: a 1080p stream uploads to your own S3-compatible bucket, and the link is copied when you stop. Update link replaces the video and keeps the URL.",
      "Auto-zoom planned from clicks and typing bursts, with one intensity slider and editable zooms on the timeline.",
      "A cursor redrawn from the event log, click effects, backgrounds, padding, corners, shadow and a movable camera bubble. Preview and export share one Metal renderer.",
      "Audio: auto level to −16 LUFS, on-device voice enhance, ducking of system audio, Cut Long Silences, and a limiter on every track.",
      "On-device captions (SpeechAnalyzer on macOS 26, on-device recognition on macOS 15), burned in or offered as a track on share links.",
      "Crop, including a one-click Hide Browser Toolbar.",
      "Export to MP4 (H.264), HEVC, ProRes and GIF in landscape, square, vertical or 4:3.",
      "The reelbird command line tool with --json output, and an MCP server for Claude Code, Codex and Cursor.",
      "The open .reelbird project format: MP4s, JSON and an event log with relative paths.",
    ],
  },
];
