/** Release notes. /changelog and /changelog/rss.xml read this. Newest first. */
export interface Release { version: string; date: string; title: string; summary: string; notes: string[] }

export const RELEASES: Release[] = [
  {
    version: "0.2.2",
    date: "2026-10-20",
    title: "Updating a link really replaces it",
    summary: "When you update a shared link with edits, blurs and removed captions now reach everyone: the earlier version's files are deleted. Plus safer edits from agents and a keystroke overlay that respects blurs.",
    notes: [
      "Update Link deletes the earlier version's files after publishing, including the quick stream and any captions or posters you removed. Before, someone with the link could still fetch the unblurred original.",
      "A slow upload that finishes after you've published your edits can no longer put the original back.",
      "The app, the command line and MCP agents can edit the same project at once without losing each other's changes.",
      "The keystroke overlay shows shortcuts only, unless you turn on Include typed text, and never shows typing while a blur is on screen.",
      "Find Sensitive Info says what it checks: the screen, not narration, captions or overlays.",
      "Reelbird Pro is called Reelbird Pro everywhere, and shared pages use the brand's coral and the robin.",
    ],
  },
  {
    version: "0.2.1",
    date: "2026-10-20",
    title: "Fix permissions that look on but don't work",
    summary: "A Reset button for permissions that are switched on in System Settings but still don't apply, and Reelbird Pro in the menus.",
    notes: [
      "Settings › Permissions shows Reset when Screen Recording, Accessibility or Input Monitoring is on in System Settings but not working. It clears the entry an earlier copy of Reelbird left behind, and macOS asks again.",
      "The welcome window offers the same reset on its Screen Recording step.",
      "Reelbird Pro… in the Reelbird menu and the menu bar menu opens your account, or sign-in and upgrade.",
      "A Pricing page on the website compares the free app and Reelbird Pro.",
    ],
  },
  {
    version: "0.2.0",
    date: "2026-10-20",
    title: "Share without setting up storage",
    summary: "Reelbird Pro hosts your links for you, with analytics that show how many people watched and where they stopped. Recording, editing, exporting and sharing to your own bucket stay free.",
    notes: [
      "Reelbird Pro ($5 a month): sign in from Settings › Sharing and Share just works, with no bucket to set up.",
      "Anonymous viewer analytics: views, daily unique viewers, where people stopped and where they came from. View counts show in the Library; the full stats are on your account page.",
      "Sharing to your own bucket is unchanged and free. Links you already shared keep working.",
      "The Share panel offers both ways to get a link. Exports never carry a watermark.",
      "Shared pages now say what Reelbird is: a free screen recorder for Mac.",
    ],
  },
  {
    version: "0.1.2",
    date: "2026-10-19",
    title: "Any speed between 0.5× and 2×",
    summary: "A speed slider for any part of a recording, and Show in Finder that brings Finder forward every time.",
    notes: [
      "Select a part between split points, or a speed segment, and drag the speed slider: anything from 0.5× to 2× in 0.05× steps, such as 1.2×.",
      "Only the selected part changes speed. One drag is one undo step.",
      "R still steps through the preset speeds; 0.25×, 4× and 8× stay in a speed segment's menu.",
      "Show in Finder now brings Finder to the front, instead of sometimes opening it behind Reelbird.",
    ],
  },
  {
    version: "0.1.1",
    date: "2026-10-13",
    title: "Signed and notarised download",
    summary: "The download is now signed with an Apple Developer ID and notarised by Apple, so it opens with no approval step and keeps its permissions across updates.",
    notes: [
      "Signed with an Apple Developer ID and notarised by Apple. No more Open Anyway in System Settings.",
      "macOS keeps Screen Recording and the other permissions when you update.",
      "Privacy blur, arrows, boxes, text and highlights in the editor.",
      "Speed changes, markers and camera layouts on the timeline, a command menu (⌘K) and a shortcut sheet (⌘/).",
      "A movable camera bubble in circle, rounded square or portrait shapes that matches the export exactly.",
    ],
  },
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
