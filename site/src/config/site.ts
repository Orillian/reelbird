/**
 * Site-wide settings. This is the only file that holds Stripe URLs, the launch
 * video URL and the prebuilt-download switch. Change them here and rebuild.
 */

export const SITE_URL = "https://reelbird.app";
export const SITE_NAME = "Reelbird";
export const GITHUB_URL = "https://github.com/btahir/reelbird";
export const GITHUB_ISSUES_URL = `${GITHUB_URL}/issues`;
export const GITHUB_RELEASES_URL = `${GITHUB_URL}/releases`;
export const LICENSE_NAME = "MIT";

export const APP_VERSION = "0.1.2";
export const RELEASE_DATE = "2026-10-19";
export const MIN_MACOS = "macOS 15";

/** What it takes to build and run Reelbird. Say it the same way everywhere. */
export const REQUIREMENTS = {
  runs: "macOS 15 or later",
  tools: "Command Line Tools for Xcode 26 or later",
  toolsDetail: "Swift 6.2 and the macOS 26 SDK. They install on macOS 15.6 and later.",
  hardware: "Tested on Apple silicon. It also compiles for Intel Macs on macOS 15, but hasn't been tested on one yet.",
};

/** One-line description, reused by meta tags, JSON-LD and llms.txt. */
export const SITE_DESCRIPTION =
  "Reelbird is a free, open-source screen recorder for macOS that copies a share link the moment you stop recording, then lets you polish the same take with auto-zoom, a smooth cursor and captions without changing the link.";

/** The canonical three-sentence description (homepage intro, llms.txt, directories). */
export const SITE_DESCRIPTION_LONG = `${SITE_DESCRIPTION} It is a native Swift app with no account, no telemetry and no Reelbird server: share links point at a storage bucket you own, such as Cloudflare R2. It includes a command-line tool and an MCP server so coding agents can record and share demos, and you can download it, signed and notarised by Apple, or build it from source, on macOS 15 or later.`;

export const SITE_TAGLINE = "Record. Get a link. Polish it later.";

/** Short form, 120 characters or fewer. */
export const SITE_SHORT = "Free, open-source Mac screen recorder. A share link when you stop; auto-zoom polish later under the same link.";

/**
 * Launch video. Leave `url` empty to show the poster with a "coming soon" note.
 * Set `url` to an MP4 (self-hosted or your bucket) or a YouTube/Vimeo embed URL.
 */
export const LAUNCH_VIDEO = {
  url: "https://www.youtube-nocookie.com/embed/NFlK-cOgRRE",
  /** "file" plays an MP4 in a <video>; "embed" loads an iframe on click. */
  kind: "embed" as "file" | "embed",
  youtubeId: "NFlK-cOgRRE",
  uploadDate: "2026-10-13",
  name: "Free, open-source Loom and Screen Studio alternative for Mac | Reelbird",
  title: "Watch the launch film",
  duration: "0:58",
};

/**
 * Prebuilt download from GitHub Releases (signed with a Developer ID and
 * notarised by `make dist`). When `enabled`, /download shows it above the
 * build-from-source steps.
 */
export const PREBUILT = {
  enabled: true,
  url: `${GITHUB_RELEASES_URL}/download/v${APP_VERSION}/Reelbird-${APP_VERSION}.zip`,
  label: `Download Reelbird ${APP_VERSION} (.zip)`,
  note: "For Apple silicon Macs on macOS 15 or later. Signed and notarised by Apple, so it opens like any other app.",
  sha256: "36e0d1c8855301ee55882896470be768c3a0fb762e604144d354bff701851422",
};

/** Donations. Read by the /support page and the thank-you after a download. */
export const DONATION_LINKS = {
  once: "https://buy.stripe.com/fZu14m0FO3v050PfqP3ks00",
  monthly: [
    { amount: "$5", name: "Supporter", href: "https://buy.stripe.com/9B68wOewEaXsgJxdiH3ks01" },
    { amount: "$15", name: "Backer", href: "https://buy.stripe.com/7sYbJ088g3v0gJx4Mb3ks02" },
    { amount: "$50", name: "Sponsor", href: "https://buy.stripe.com/28EeVc88g5D80Kz2E33ks03" },
    { amount: "$100", name: "Company sponsor", href: "https://buy.stripe.com/00w14m6088PkbpdceD3ks04" },
  ],
} as const;

/** Absolute URL for a site path such as "/support/". */
export const abs = (path: string): string => new URL(path, SITE_URL).toString();

/**
 * Self-hosted Umami (cookieless page counts). Set PUBLIC_UMAMI_WEBSITE_ID at build time to turn it on;
 * without it no analytics script is added, so forks of this site don't report to our dashboard.
 */
export const UMAMI = {
  script: import.meta.env.PUBLIC_UMAMI_SCRIPT ?? "https://project-analytics.shiptiffin.app/script.js",
  websiteId: import.meta.env.PUBLIC_UMAMI_WEBSITE_ID ?? "",
} as const;
