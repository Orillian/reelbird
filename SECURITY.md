# Security

## Reporting a problem

Please report security problems privately, not in a public issue. Use GitHub's private reporting: open the repository's **Security** tab and choose **Report a vulnerability**, or go straight to https://github.com/btahir/reelbird/security/advisories/new.

Say what you found, how to reproduce it, and what an attacker could do with it. You should hear back within a week. Once a fix is out, the advisory is published with credit to you, unless you'd rather stay anonymous.

## Supported versions

Fixes go into the latest release and `main`. Older versions don't get backports.

## What's in scope

Reelbird has no server, so the areas that matter most are:

- **Sharing credentials.** The S3 secret key is kept in the macOS Keychain. Anything that writes it to disk, logs, CLI output or the bucket is a bug.
- **The viewer page** that Reelbird uploads to your bucket, including how it handles titles, captions and `meta.json`.
- **The MCP server and CLI**, for example input that makes them run code or send data somewhere you didn't configure.
- **Project files** (`.reelbird` folders) opened from someone else.

Problems in your storage provider's configuration (a bucket that lists its contents publicly, for example) are outside Reelbird, but tell us if the docs led you there.
