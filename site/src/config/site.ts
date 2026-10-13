/**
 * Site-wide settings. This is the only file that holds Stripe URLs, the launch
 * video URL and the prebuilt-download switch. Change them here and rebuild.
 */

export const SITE_URL = "https://reelbird.shiptiffin.app";
export const SITE_NAME = "Reelbird";
export const GITHUB_URL = "https://github.com/btahir/reelbird";
export const GITHUB_ISSUES_URL = `${GITHUB_URL}/issues`;
export const GITHUB_RELEASES_URL = `${GITHUB_URL}/releases`;
export const LICENSE_NAME = "MIT";

export const APP_VERSION = "0.1.0";
export const RELEASE_DATE = "2026-10-12";
export const MIN_MACOS = "macOS 15";

/** One-line description, reused by meta tags, JSON-LD and llms.txt. */
export const SITE_DESCRIPTION =
  "Reelbird is a free, open-source screen recorder for macOS that copies a share link the moment you stop recording, then lets you polish the same take with auto-zoom, a smooth cursor and captions without changing the link.";

/** The canonical three-sentence description (homepage intro, llms.txt, directories). */
export const SITE_DESCRIPTION_LONG = `${SITE_DESCRIPTION} It is a native Swift app with no account, no telemetry and no Reelbird server: share links point at a storage bucket you own, such as Cloudflare R2. It includes a command-line tool and an MCP server so coding agents can record and share demos, and for now you install it by building from source on macOS 15 or later.`;

export const SITE_TAGLINE = "Record. Get a link. Polish it later.";

/** Short form, 120 characters or fewer. */
export const SITE_SHORT = "Free, open-source Mac screen recorder. A share link when you stop; auto-zoom polish later under the same link.";

/**
 * Launch video. Leave `url` empty to show the poster with a "coming soon" note.
 * Set `url` to an MP4 (self-hosted or your bucket) or a YouTube/Vimeo embed URL.
 */
export const LAUNCH_VIDEO = {
  url: "",
  /** "file" plays an MP4 in a <video>; "embed" loads an iframe on click. */
  kind: "file" as "file" | "embed",
  title: "Reelbird in two minutes",
  duration: "",
};

/**
 * Optional prebuilt download from GitHub Releases. Off until a signed,
 * notarised build exists. When `enabled`, /download shows it above the
 * build-from-source steps.
 */
export const PREBUILT = {
  enabled: false,
  url: `${GITHUB_RELEASES_URL}/latest/download/Reelbird.zip`,
  label: "Download Reelbird.zip",
  note: "Signed and notarised. Unzip and move Reelbird to Applications.",
};

/** Donations. The /support page and nothing else reads these. */
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
