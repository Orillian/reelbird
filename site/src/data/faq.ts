/**
 * FAQ. /faq renders these and its FAQPage JSON-LD from the same array, so the two never differ.
 * `a` is plain text (used in JSON-LD and llms-full.txt); `html` is optional richer markup for the page.
 */
export interface Faq { id: string; q: string; a: string; html?: string }

export const FAQ: Faq[] = [
  {
    id: "free",
    q: "Is Reelbird free?",
    a: "Yes. It's MIT licensed, with no paid tier, watermark or export limit. Sharing uses your own storage bucket; Cloudflare R2's free tier (10 GB, free egress) covers most people.",
  },
  {
    id: "open-source",
    q: "Is it really open source?",
    a: "Yes, MIT. The code is at github.com/btahir/reelbird, and Reelbird has no third-party Swift dependencies.",
    html: `Yes, MIT. The code is at <a href="https://github.com/btahir/reelbird">github.com/btahir/reelbird</a>, and Reelbird has no third-party Swift dependencies.`,
  },
  {
    id: "account",
    q: "Do I need an account?",
    a: "No. There's no Reelbird account or server.",
  },
  {
    id: "install",
    q: "How do I install it? Is there a download?",
    a: "Not yet. There's no signed or notarized download, so you build it: git clone, then make install. It takes a few minutes and needs Apple's Command Line Tools, not Xcode. A notarized download is on the roadmap.",
    html: `Not yet. There's no signed or notarized download, so you build it: <code>git clone</code>, then <code>make install</code>. It takes a few minutes and needs Apple's Command Line Tools, not Xcode. A notarized download is on the roadmap. The steps are on the <a href="/download/">download page</a>.`,
  },
  {
    id: "requirements",
    q: "What do I need?",
    a: "macOS 15 or later to run it. To build it, the Command Line Tools for Xcode 26 or later (Swift 6.2 and the macOS 26 SDK), which install on macOS 15.6 and later. It's tested on Apple silicon; it compiles for Intel but hasn't been tested there. Some features need newer systems: SpeechAnalyzer captions need macOS 26 (macOS 15 uses on-device speech recognition), and titles and chapters need macOS 26 with Apple Intelligence.",
  },
  {
    id: "windows",
    q: "Does it work on Windows or Linux?",
    a: "No, and it isn't planned. Reelbird is built on Apple frameworks throughout.",
  },
  {
    id: "links",
    q: "How do share links work?",
    a: "With Share while recording on, Reelbird uploads a 1080p stream to your bucket as you record and copies the link when you stop. After editing, Update link replaces the video and the URL stays the same.",
    html: `With <strong>Share while recording</strong> on, Reelbird uploads a 1080p stream to your bucket as you record and copies the link when you stop. After editing, <strong>Update link</strong> replaces the video and the URL stays the same.`,
  },
  {
    id: "sharing-setup",
    q: "Do I have to set up sharing?",
    a: "Only if you want links. Recording, editing and export work with no setup. Sharing needs a one-time bucket setup, about ten minutes for R2 (Cloudflare asks for a payment method on file even on the free tier).",
    html: `Only if you want links. Recording, editing and export work with no setup. Sharing needs a one-time bucket setup, about ten minutes for R2 (Cloudflare asks for a payment method on file even on the free tier). See <a href="/docs/sharing/">Sharing setup</a>.`,
  },
  {
    id: "download-videos",
    q: "Can I download my videos?",
    a: "They never leave your Mac unless you share them. Every take is a folder of standard MP4s, and you can export MP4 (H.264), HEVC, ProRes or GIF.",
  },
  {
    id: "time-limit",
    q: "Is there a time limit?",
    a: "Reelbird sets none. Limits come from your disk and, for links, your bucket.",
  },
  {
    id: "auto-zoom",
    q: "Does it have auto-zoom like Screen Studio?",
    a: "Yes. It plans zooms from your clicks, has a single intensity slider, and every zoom can be edited or deleted on the timeline. With keystroke recording on, typing bursts get zooms too; zooms that track the focused text field are on the roadmap.",
  },
  {
    id: "privacy",
    q: "Is my data private?",
    a: "Recordings, edits and captions stay in ~/Movies/Reelbird. There's no analytics, telemetry, crash reporting or update checks. Captions use Apple's on-device frameworks. Share links are unlisted, not secret. Anyone with a link can watch.",
    html: `Recordings, edits and captions stay in <code>~/Movies/Reelbird</code>. There's no analytics, telemetry, crash reporting or update checks. Captions use Apple's on-device frameworks. Share links are unlisted, not secret. Anyone with a link can watch. More on the <a href="/privacy/">privacy page</a>.`,
  },
  {
    id: "crash",
    q: "What happens if my Mac crashes mid-recording?",
    a: "Reelbird writes 2-second segments from the first frame and recovers the take on next launch, losing at most the last two seconds.",
  },
  {
    id: "agents",
    q: "Can AI agents use it?",
    a: "Yes. The reelbird CLI (with --json) and reelbird mcp let Claude Code, Codex or Cursor record, export, caption and share.",
    html: `Yes. The <code>reelbird</code> CLI (with <code>--json</code>) and <code>reelbird mcp</code> let Claude Code, Codex or Cursor record, export, caption and share. See <a href="/docs/mcp/">MCP setup</a>.`,
  },
  {
    id: "permission-prompts",
    q: "Why does macOS keep asking about Screen Recording?",
    a: "macOS 15 asks you now and then to reconfirm apps that record the screen; that prompt comes from macOS. Separately, ad-hoc builds lose the permission on every rebuild; scripts/dev-signing.sh fixes that.",
    html: `macOS 15 asks you now and then to reconfirm apps that record the screen; that prompt comes from macOS. Separately, ad-hoc builds lose the permission on every rebuild; <code>scripts/dev-signing.sh</code> fixes that (see <a href="/docs/install/#keep-permissions-across-rebuilds-optional">local signing</a>).`,
  },
  {
    id: "vs-loom-screen-studio",
    q: "How is Reelbird different from Loom and Screen Studio?",
    a: "Loom copies a share link when you stop but has no auto-zoom, and its free Starter plan stops each video at 5 minutes, keeps 25 videos, records up to 720p and can't download. Screen Studio has polished auto-zoom but costs $29 a month ($9 billed yearly), and its share link comes after you export. Reelbird copies a link when you stop, lets you add auto-zoom later under the same link, keeps every take as MP4 files on your Mac and is free under the MIT licence. Loom does more for teams (comments, view counts, every platform) and Screen Studio has a more mature editor and a signed download. Prices checked 12 October 2026.",
    html: `Loom copies a share link when you stop but has no auto-zoom, and its free Starter plan stops each video at 5 minutes, keeps 25 videos, records up to 720p and can't download. Screen Studio has polished auto-zoom but costs $29 a month ($9 billed yearly), and its share link comes after you export. Reelbird copies a link when you stop, lets you add auto-zoom later under the same link, keeps every take as MP4 files on your Mac and is free under the MIT licence. Loom does more for teams (comments, view counts, every platform) and Screen Studio has a more mature editor and a signed download. Prices checked 12 October 2026; see the <a href="/compare/">full comparison</a>.`,
  },
  {
    id: "cap-openscreen",
    q: "How is it different from Cap or OpenScreen?",
    a: "Cap also does instant links and auto-zoom, but as separate recording modes (Instant and Studio). It runs on Mac, Windows and Linux, its code is mostly AGPLv3, its free plan is for personal use with 5-minute links, and your own S3 bucket is a Pro feature. OpenScreen is MIT, free and cross-platform with signed Mac builds, but has no share links. Reelbird is Mac-only and native Swift, links to your own bucket for free, and its links update in place after you edit.",
    html: `Cap also does instant links and auto-zoom, but as separate recording modes (Instant and Studio). It runs on Mac, Windows and Linux, its code is mostly AGPLv3, its free plan is for personal use with 5-minute links, and your own S3 bucket is a Pro feature. OpenScreen is MIT, free and cross-platform with signed Mac builds, but has no share links. Reelbird is Mac-only and native Swift, links to your own bucket for free, and its links update in place after you edit. The <a href="/compare/">comparison</a> has the details.`,
  },
];

/** The handful shown on the homepage. */
export const HOME_FAQ = ["vs-loom-screen-studio", "free", "install", "account", "links", "windows", "privacy"].map((id) => FAQ.find((f) => f.id === id)!);
