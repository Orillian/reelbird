<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/logo-dark.svg">
    <img src="brand/logo.svg" alt="Reelbird" width="360">
  </picture>
</p>

<p align="center">A free, open-source screen recorder for the Mac. Record, get a link when you stop, polish it later under the same link.</p>

<p align="center">
  <a href="#install-from-source">Install</a> ·
  <a href="#keyboard-shortcuts">Shortcuts</a> ·
  <a href="#command-line">CLI</a> ·
  <a href="#mcp-server">MCP</a> ·
  <a href="docs/SHARING.md">Sharing setup</a> ·
  <a href="#troubleshooting">Troubleshooting</a>
</p>

---

Reelbird records your screen, camera and microphone. When you stop, a link to the recording is already on your clipboard, and it plays in any browser a moment later. Later you can open the same take, let Reelbird zoom in on what you clicked and smooth out the cursor, trim it, add captions, and choose **Update link**. Everyone you sent the link to now sees the polished version.

It does what Loom and Screen Studio do, in one app, for free. It is a native Mac app written in Swift, with ScreenCaptureKit for capture and Metal for rendering. There is no Electron, no account and no Reelbird server. Share links point at a storage bucket you own, and Cloudflare R2's free tier covers most people.

<!--
Screenshots go in brand/screenshots/. Uncomment once they exist.
<p align="center">
  <img src="brand/screenshots/editor.png" alt="The Reelbird editor with auto-zoom regions on the timeline" width="880">
</p>
| Recording | Instant link | Viewer page |
|---|---|---|
| ![](brand/screenshots/recording.png) | ![](brand/screenshots/link.png) | ![](brand/screenshots/viewer.png) |
-->

## What it does

**Records what you need, as separate tracks.** A display, a window or an area, plus camera, microphone and system audio. Camera and audio stay on their own tracks, so you can move the camera bubble or mute system sound after recording.

**Never loses a take.** Every track is written to disk in 2-second segments from the first frame. If your Mac crashes or the app quits mid-recording, Reelbird recovers the take the next time it opens, minus at most the last two seconds.

**Warns you while it matters.** If the microphone is recording silence, capture stalls, audio drifts, the disk is filling up or uploads fall behind, you see it during the recording, not after.

**Auto-zoom and a smooth cursor.** Reelbird logs clicks, scrolls and pointer movement next to the video, then plans zooms that follow your clicks. One slider sets how much it zooms, from subtle to punchy, and you can add, move or delete zooms on the timeline. The cursor is redrawn from that log, so it glides instead of jittering, and you can resize it or hide it after the fact. Preview and export use the same Metal renderer, so the export looks exactly like the preview.

**Instant share links to your own bucket.** With **Share while recording** on, Reelbird uploads a 1080p stream as you record. The link is copied the moment you stop. After editing, **Update link** replaces the video and keeps the URL. Setup is in [docs/SHARING.md](docs/SHARING.md).

**Captions on your Mac.** Captions come from Apple's on-device speech recognition. You can burn them into the export, and share links offer them as a track viewers can turn on. **Cut Long Silences** removes the pauses in one go. From the command line, `reelbird suggest` writes a title and chapters with Apple's on-device model on Macs with Apple Intelligence. No API keys, and nothing leaves your Mac unless you share it.

**Exports the usual formats.** MP4 (H.264), HEVC, ProRes and GIF, with hardware encoding.

**Works with agents.** The `reelbird` command line tool and its MCP server let Claude Code, Codex or Cursor list screens, record a demo of the change they just made, export it and hand you the link.

**Open project format.** A recording is a `.reelbird` folder of standard MP4 files, JSON and an event log, with relative paths. Nothing is locked in. See [docs/FORMAT.md](docs/FORMAT.md).

## Install from source

Reelbird isn't on the App Store and doesn't have a signed download yet, so you build it yourself. It takes a few minutes and needs no Xcode.

You need:

- macOS 15 or later, on Apple silicon. It also compiles for Intel Macs that run macOS 15, but it hasn't been tested on one yet.
- The Command Line Tools (`xcode-select --install`). Xcode works too but isn't required.

```sh
git clone https://github.com/btahir/reelbird.git
cd reelbird
make install
```

`make install` builds a release copy of the app and copies it to `/Applications`, asking first if Reelbird is already there. Then open it:

```sh
open /Applications/Reelbird.app
```

Reelbird lives in the menu bar. Look for the robin.

Some Command Line Tools installs ship a stale SwiftPM file that breaks every `Package.swift`. The scripts detect this and work around it on their own (see `scripts/env.sh`), so you don't need to do anything. Run `make` to see every target.

### Permissions on first run

The welcome tour asks for each permission in turn. You can change them later in **Settings… → Permissions** or in **System Settings → Privacy & Security**.

| Permission | Needed for |
|---|---|
| Screen & System Audio Recording | Recording the screen and system sound. Required. |
| Microphone | Your voice. |
| Camera | The camera bubble. |
| Accessibility and Input Monitoring | Optional. The keystroke overlay (**Settings… → Recording → Record keystrokes**). |
| Speech Recognition | Captions on macOS 15 only. macOS 26 and later doesn't ask. |

**Screen Recording takes effect only after Reelbird reopens.** After you turn it on, choose **Quit & Reopen** in Reelbird (or quit it from the menu bar and open it again).

### Keep permissions across rebuilds (optional)

By default the app is signed ad hoc. That signature changes with every build, so macOS forgets the Screen Recording permission each time you rebuild. If you build often, create a local signing certificate once:

```sh
scripts/dev-signing.sh
export RB_SIGN_IDENTITY="Reelbird Local Signing"   # add this to your ~/.zshrc
make install
```

The script creates a self-signed certificate named "Reelbird Local Signing" in your login keychain and does nothing if it already exists. Every build signed with it has the same identity, so the permission sticks. The first build asks whether `codesign` may use the key. Choose **Always Allow**. `scripts/dev-signing.sh --remove` deletes the certificate. It never leaves your Mac and isn't trusted for anything except signing your own builds.

## Keyboard shortcuts

These two work in every app. Change them in **Settings… → General**.

| Shortcut | Action |
|---|---|
| ⌥⇧R | New recording; while recording, stop |
| ⌥⇧P | Pause or resume |

While picking what to record, Return starts and Esc closes the picker. During the countdown, Return, Space or a click skips it and Esc cancels. When selecting an area, Return records and Esc cancels.

In the editor:

| Key | Action |
|---|---|
| Space | Play or pause |
| J / K / L | Back 2 seconds / pause / play |
| ← / → | Step back or forward 1/30 second (with ⇧: one second) |
| Home / End | Jump to start or end |
| S | Split at the playhead |
| Z | Add a zoom at the playhead |
| Delete | Cut the selected part, delete the selected zoom, or restore a cut |
| Esc | Clear the selection |
| ⌘1 to ⌘7 | Background, Cursor, Zoom, Camera, Canvas, Audio, Captions |
| ⌘= / ⌘− | Zoom the timeline in or out |
| ⌘E | Export |
| ⌘Z / ⇧⌘Z | Undo / redo |

Elsewhere: ⌘N starts a new recording, ⇧⌘L opens the library, ⌘O opens a `.reelbird` project, ⇧⌘E shares or copies the link, ⇧⌘R shows the recording in Finder, ⌘⌫ moves it to the Trash, and ⌘, opens Settings.

## Command line

The `reelbird` tool ships inside the app. Put it on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/Reelbird.app/Contents/Helpers/reelbird ~/.local/bin/reelbird
```

```sh
reelbird sources                               # displays, windows, microphones and cameras, with IDs
reelbird record --display 1 --duration 30      # 30 seconds of the main display
reelbird record --window 1234 --share          # a window by ID from `sources`; Ctrl-C stops
reelbird list                                  # recent recordings
reelbird edit latest --set zoom.intensity=0.7 --trim 0:05-end
reelbird export latest --format mp4 --height 1080
reelbird captions latest                       # captions.vtt, made on this Mac
reelbird share latest                          # upload and print the link
reelbird share latest --polished               # render the edit, same link
reelbird help record
```

A project can be a `.reelbird` path, a name from `reelbird list`, or `latest`. Every command takes `--json` for machine-readable output and `--library DIR` to use another folder (the default is `~/Movies/Reelbird`, or `$REELBIRD_LIBRARY`).

Sharing settings made in the app are used by the CLI too. To set them from the terminal, run `reelbird config share --help`.

When you record from a terminal, macOS asks for Screen Recording permission for the terminal app (Terminal, iTerm, your editor), not for Reelbird.

## MCP server

`reelbird mcp` runs an MCP server over stdio. Agents get tools to list sources, start and stop recordings, list and inspect projects, edit, export, caption, find silences, suggest chapters, and share or unshare.

**Claude Code**

```sh
claude mcp add reelbird -- /Applications/Reelbird.app/Contents/Helpers/reelbird mcp
```

**Codex**

```sh
codex mcp add reelbird -- /Applications/Reelbird.app/Contents/Helpers/reelbird mcp
```

or in `~/.codex/config.toml`:

```toml
[mcp_servers.reelbird]
command = "/Applications/Reelbird.app/Contents/Helpers/reelbird"
args = ["mcp"]
```

**Cursor** (`~/.cursor/mcp.json`, or `.cursor/mcp.json` in a project)

```json
{
  "mcpServers": {
    "reelbird": {
      "type": "stdio",
      "command": "/Applications/Reelbird.app/Contents/Helpers/reelbird",
      "args": ["mcp"]
    }
  }
}
```

Then ask: "Record a 20-second demo of the settings page you just changed and give me the share link."

Recording through an agent needs Screen Recording permission for the app that runs the agent (your terminal or editor).

## Sharing

Sharing is optional. Reelbird uploads to an S3-compatible bucket that you own:

1. Create a Cloudflare R2 bucket and give it a public URL (a custom domain, or the r2.dev URL to start).
2. Create an R2 API token with **Object Read & Write**, limited to that bucket.
3. Paste the endpoint, keys and public URL into **Settings… → Sharing** and choose **Test Connection**, then **Save**.

R2's free tier includes 10 GB of storage and free egress, which covers hours of shared video. AWS S3, Backblaze B2 and MinIO work too. The full walkthrough, costs and privacy notes are in [docs/SHARING.md](docs/SHARING.md).

## Troubleshooting

**Reelbird says Screen Recording is off, but the switch is on.** Quit and reopen Reelbird; the permission only applies after a restart. If it still fails, you probably rebuilt an ad-hoc signed copy, and macOS is holding the permission for the old build. Remove Reelbird from the Screen Recording list (select it, then the minus button), reopen Reelbird and allow it again. To stop this happening on every rebuild, set up [local signing](#keep-permissions-across-rebuilds-optional).

**macOS asks again every month whether Reelbird may record your screen.** That prompt comes from macOS, not Reelbird. Since macOS 15, the system asks you now and then to confirm apps that record the screen. Choose to keep allowing it.

**A Keychain prompt asks to use "app.reelbird.share".** That's your sharing secret. It appears when the CLI reads a secret the app saved, or after a rebuild changed the app's signature. Enter your login password and choose **Always Allow**. Local signing makes the answer stick across rebuilds. For CI, set `REELBIRD_S3_SECRET_ACCESS_KEY` instead (see [docs/SHARING.md](docs/SHARING.md#command-line-and-ci)).

**Keystrokes don't show up.** Recording key presses needs Input Monitoring as well as Accessibility. Turn on Reelbird under **System Settings → Privacy & Security → Input Monitoring** (add it with the plus button if it isn't listed), then reopen Reelbird. Keystrokes are only recorded when **Record keystrokes** is on before you start.

**Captions say they need a newer macOS.** On macOS 26 and later, captions use Apple's SpeechAnalyzer and download the language model on first use. On macOS 15 they need on-device speech recognition for your language and the Speech Recognition permission.

**The app quit while recording.** Open Reelbird again. It finishes the take from the segments on disk. From the terminal, `reelbird recover PROJECT` does the same.

## Privacy

- Recordings, edits, captions and transcripts stay on your Mac, in `~/Movies/Reelbird` unless you choose another folder.
- Captions and titles are made on-device by Apple's frameworks. No API keys and no cloud services. (On macOS 26, macOS downloads Apple's speech model the first time you make captions.)
- Nothing is uploaded unless you share. Shares go only to the bucket you configured, signed with your own keys. The secret key lives in your macOS Keychain.
- No analytics, no telemetry, no crash reporting, no update checks. The app never contacts a Reelbird server, because there isn't one.
- The shared viewer page plays the polished MP4 directly. While a share still has only the live stream, browsers without built-in HLS (Chrome, Firefox) load the hls.js player from jsDelivr, pinned to a version and integrity-checked.

## Roadmap

- **Joining clips.** The project format can already append other takes; the editor doesn't have a UI for it yet.
- **Focus-follow zoom.** Zooms that follow the text field you're typing in. Today zooms follow clicks.
- **Annotations.** Arrows, boxes, text and blur. The renderer draws them; the editor can't add them yet.
- **Titles and chapters in the app.** Available from the CLI and MCP today.
- **A signed, notarized download**, so you don't have to build from source.
- **Windows and Linux are not planned.** Reelbird is built on Apple frameworks from top to bottom.

## How it's built

Seven Swift modules with no third-party dependencies: capture (ScreenCaptureKit, AVFoundation), render (Metal), share (S3 uploads, HLS, viewer page), AI (Speech, Foundation Models), a shared core, the app and the CLI. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the recording pipeline, sharing flow and renderer. [docs/FORMAT.md](docs/FORMAT.md) documents the project format.

## Contributing

Bug reports, fixes and features are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers building, tests and pull requests.

## License

[MIT](LICENSE).

---

Reelbird is free. If it saves you time, you can support it here: https://reelbird.shiptiffin.app/support/
