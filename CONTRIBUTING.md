# Contributing

Thanks for helping. Bug reports with steps to reproduce are as useful as code.

## Build and test

You need macOS 15 or later and the Command Line Tools (`xcode-select --install`). Xcode is optional. There are no third-party dependencies to fetch.

```sh
make build      # debug build of every module
make test       # the test suite (swift-testing)
make app        # build/Reelbird.app, release (Developer ID, local signing or ad hoc)
make install    # build the app and copy it to /Applications
make dist       # build/Reelbird-<version>.zip and its SHA-256, for a download
make icon       # regenerate the icon and menu bar glyphs from brand/*.svg
```

Each target calls a script in `scripts/`, which you can also run directly. `scripts/test.sh --filter ReelbirdShareTests` runs one suite, and `scripts/build.sh -c release` passes flags through to `swift build`.

Use the scripts rather than calling `swift` yourself. They source `scripts/env.sh`, which works around a stale SwiftPM file in some Command Line Tools installs, and `scripts/test.sh` adds the swift-testing plugin path. If you call `swift` directly, run `source scripts/env.sh` first. Set `RB_SCRATCH` to a folder to build into a separate directory, for example when you work in several git worktrees at once.

Tests run without Screen Recording, camera or microphone permission. Capture code sits behind protocols with synthetic sources (generated frames and audio), so new capture, render or share code should come with a test that runs end to end on synthetic data. The CLI can do the same: `reelbird record --synthetic --duration 3` records generated frames and tones.

If you rebuild the app often, run `scripts/dev-signing.sh` once so macOS keeps the Screen Recording permission between builds (see the README).

## Things that work without Xcode

The build uses only what the Command Line Tools ship, so a few things are done differently on purpose:

- Metal shaders are Swift string literals compiled at runtime (`device.makeLibrary(source:options:)`). There is no `.metal` file.
- No asset catalogs, storyboards or SwiftPM resources. Images and HTML templates are embedded as Swift strings. Resource bundles also break signing of the `.app`.
- The `.app` is assembled by `scripts/build-app.sh` from `packaging/Info.plist` and `packaging/Reelbird.entitlements`.

## Code style

- Swift 6 language mode with strict concurrency and `ExistentialAny`. No new warnings.
- Apple frameworks only. Adding a dependency needs a good reason in the pull request.
- macOS 15 is the floor. Gate newer APIs with `if #available(macOS 26, *)`.
- No force-unwraps on anything that comes from the user, the disk or the network.
- Keep capture and encode work off the main thread, and avoid allocations in per-frame code.
- Document public API with `///`. Comment the why, not the what.
- Match the style of the file you're editing.

## Pull requests

- One change per pull request, with a short description of what and why.
- Include screenshots or a short recording for UI changes. Reelbird can make one.
- `make test` passes.
- Changes to the project format update [docs/FORMAT.md](docs/FORMAT.md) and keep old projects opening.
- Changes to commands, flags or UI labels update the README and docs.
- Brand assets are SVG sources in `brand/`. After editing `brand/icon.svg` or the menu bar glyphs, run `make icon` and commit the regenerated files.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
