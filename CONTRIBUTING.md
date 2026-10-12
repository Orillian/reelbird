# Contributing

Thanks for helping. Bug reports with steps to reproduce are as useful as code.

## Build and test

You need macOS 15 or later and Xcode or the Command Line Tools (`xcode-select --install`). There are no third-party dependencies to fetch.

```sh
scripts/build.sh        # debug build of every module
scripts/test.sh         # the test suite (swift-testing)
scripts/build-app.sh    # build/Reelbird.app, signed ad hoc
```

`scripts/test.sh --filter ReelbirdShareTests` runs one suite. Use the scripts rather than calling `swift` directly: they work around a stale SwiftPM file in some Command Line Tools installs and add the swift-testing plugin path.

Tests run without Screen Recording, camera or microphone permission. Capture code sits behind protocols with synthetic sources (generated frames and audio), so new capture, render or share code should come with a test that runs end to end on synthetic data.

If you rebuild the app often, run `scripts/dev-signing.sh` once so macOS keeps the Screen Recording permission between builds (see the README).

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
- `scripts/test.sh` passes.
- Changes to the project format update [docs/FORMAT.md](docs/FORMAT.md) and keep old projects opening.
- Brand assets are SVG sources in `brand/`. After editing `brand/icon.svg` or the menu bar glyphs, run `scripts/make-icon.sh` and commit the regenerated files.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
