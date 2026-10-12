<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/logo-dark.svg">
    <img src="brand/logo.svg" alt="Reelbird" width="360">
  </picture>
</p>

<p align="center">A free, open-source screen recorder for the Mac. Record, get a link when you stop, polish it later under the same link.</p>

<p align="center">
  <a href="#install-from-source">Install</a> ·
  <a href="#command-line">CLI</a> ·
  <a href="#mcp-server">MCP</a> ·
  <a href="docs/SHARING.md">Sharing setup</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture</a>
</p>

---

Reelbird records your screen, camera and microphone. When you stop, a link to the recording is already on your clipboard, and it plays in any browser within a couple of seconds. Later you can open the same take, let Reelbird zoom in on what you clicked and smooth out the cursor, trim it, add captions, and choose **Update link**. Everyone you sent the link to now sees the polished version.

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

**Never loses a take.** Every track is written to disk in 2-second segments from the first frame. If your Mac crashes or the app quits mid-recording, Reelbird recovers the take on the next launch, minus at most the last two seconds.

**Warns you while it matters.** If the microphone is recording silence, capture stalls, audio drifts or the disk is filling up, you see it during the recording, not after.

**Auto-zoom and a smooth cursor.** Reelbird logs clicks, typing and pointer movement next to the video, then plans zooms that follow your work. One slider sets how much it zooms. The cursor is redrawn from that log, so it glides instead of jittering, and you can resize it or hide it after the fact. Preview and export use the same Metal renderer, so the export looks exactly like the preview.

**Instant share links to your own bucket.** With sharing on, Reelbird uploads a 1080p stream while you record. The link is copied the moment you stop. After editing, **Update link** replaces the video and keeps the URL. Setup is in [docs/SHARING.md](docs/SHARING.md).

**Captions and chapters on your Mac.** Captions come from Apple's on-device speech recognition (macOS 26 and later). Titles and chapters come from Apple's on-device language model on Macs with Apple Intelligence. No API keys, and nothing leaves your Mac unless you share it. Reelbird can also find long silences so you can cut them in one go.

**Exports the usual formats.** MP4 (H.264 or HEVC), ProRes and GIF, with hardware encoding.

**Works with agents.** The `reelbird` command line tool and its MCP server let Claude Code, Codex or Cursor list screens, record a demo of the change they just made, export it and hand you the link.

**Open project format.** A recording is a `.reelbird` folder of standard MP4 files, JSON and an event log, with relative paths. Nothing is locked in. See [docs/FORMAT.md](docs/FORMAT.md).

## Install from source

Reelbird isn't on the App Store and doesn't have a signed download yet, so you build it yourself. It takes a few minutes.

You need:

- macOS 15 or later (captions need macOS 26)
- Xcode or just the Command Line Tools. To install the tools, run `xcode-select --install`.

```sh
git clone https://github.com/btahir/reelbird.git
cd reelbird
scripts/build-app.sh
mv build/Reelbird.app /Applications/
open /Applications/Reelbird.app
```

Reelbird lives in the menu bar. Look for the robin.

### Permissions on first run

macOS asks for each permission the first time Reelbird needs it. You can change them later in **System Settings → Privacy & Security**.

| Permission | Needed for |
|---|---|
| Screen & System Audio Recording | Recording the screen and system sound. Required. |
| Microphone | Your voice. |
| Camera | The camera bubble. |
| Accessibility | Optional. Keystroke overlay and zooms that follow the text field you're typing in. |

After you grant Screen Recording, macOS may ask you to quit and reopen Reelbird.

### Keep permissions across rebuilds (optional)

By default `scripts/build-app.sh` signs the app ad hoc. The signature changes with every build, so macOS forgets the Screen Recording permission each time you rebuild. If you build often, create a local signing certificate once:

```sh
scripts/dev-signing.sh
export RB_SIGN_IDENTITY="Reelbird Local Signing"   # add this to your ~/.zshrc
scripts/build-app.sh
```

The script creates a self-signed certificate named "Reelbird Local Signing" in your login keychain and does nothing if it already exists. Every build signed with it has the same identity, so the permission sticks. The first build asks whether `codesign` may use the key. Choose **Always Allow**. `scripts/dev-signing.sh --remove` deletes the certificate. The certificate never leaves your Mac and isn't trusted for anything except signing your own builds.

## Command line

The `reelbird` tool ships inside the app. Put it on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/Reelbird.app/Contents/Helpers/reelbird ~/.local/bin/reelbird
```

```sh
reelbird sources                               # displays and windows you can record
reelbird record --display main --duration 30   # record 30 seconds of the main display
reelbird record --window "Safari" --mic default --share
reelbird list                                  # recent recordings
reelbird export Demo.reelbird --format mp4 --height 1080
reelbird share Demo.reelbird                   # upload and print the link
reelbird captions Demo.reelbird                # write captions.vtt on this Mac
reelbird --help
```

When the CLI records for the first time, macOS may ask for Screen Recording permission for the app that ran it (your terminal or editor).

## MCP server

`reelbird mcp` runs an MCP server over stdio. Agents get tools to list sources, start and stop recordings, export, caption and share.

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

**Cursor** (`~/.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "reelbird": {
      "command": "/Applications/Reelbird.app/Contents/Helpers/reelbird",
      "args": ["mcp"]
    }
  }
}
```

Then ask: "Record a 20-second demo of the settings page you just changed and give me the share link."

## Sharing

Sharing is optional. Reelbird uploads to an S3-compatible bucket that you own and control:

1. Create a Cloudflare R2 bucket and give it a public URL (a custom domain, or the r2.dev URL to start).
2. Create an R2 API token with **Object Read & Write**, limited to that bucket.
3. Paste the endpoint, keys and public URL into **Reelbird → Settings → Sharing** and select **Test connection**.

R2's free tier includes 10 GB of storage and free egress, which covers hours of shared video. AWS S3, Backblaze B2 and MinIO work too. The full walkthrough, costs and privacy notes are in [docs/SHARING.md](docs/SHARING.md).

## How it's built

Seven Swift modules with no third-party dependencies: capture (ScreenCaptureKit, AVFoundation), render (Metal), share (S3 uploads, HLS, viewer page), AI (Speech, Foundation Models), a shared core, the app and the CLI. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the recording pipeline, sharing flow and renderer. [docs/FORMAT.md](docs/FORMAT.md) documents the project format.

## Contributing

Bug reports, fixes and features are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers building, tests and pull requests.

## License

[MIT](LICENSE).

---

Reelbird is free. If it saves you time, you can support it here: https://shotcandy.vercel.app/support/
