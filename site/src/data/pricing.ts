/**
 * Free vs Reelbird Pro. /pricing renders the table and the FAQ (and its FAQPage JSON-LD) from here,
 * and llms-full.txt repeats them, so the facts are said one way. Prices and limits come from PRO in
 * config/site.ts.
 */
import { PRO } from "../config/site";
import type { Faq } from "./faq";

/** The plan columns on /pricing. Short, and only what differs; the table below has the detail. */
export const FREE_POINTS = [
  "Record, edit and export, with no watermark and no limits",
  "No account, nothing leaves your Mac unless you share",
  `Share links from your own bucket, such as Cloudflare R2. <a href="/docs/sharing/">About ten minutes to set up</a>, once`,
  "CLI and MCP server for scripts and agents",
];
export const PRO_POINTS = [
  "Share links hosted by Reelbird, with nothing to set up",
  `Unlimited links and ${PRO.storage} of video`,
  "Views and unique viewers for every link",
  "Where viewers stop, where they came from, and their devices",
];

export const PLAN_ROWS: { k: string; free: string; pro: string }[] = [
  { k: "Price", free: "Free", pro: `${PRO.price} a month` },
  { k: "Record, edit, export", free: "Everything, with no watermark and no limits", pro: "The same app" },
  { k: "Account", free: "None needed", pro: "Your email address" },
  { k: "Share links", free: "Hosted in your own bucket: Cloudflare R2 or any S3-compatible storage", pro: "Hosted by Reelbird at watch.reelbird.app" },
  { k: "Setup", free: "About ten minutes, once", pro: "None. Sign in from the Share button" },
  { k: "Storage", free: "Whatever your bucket holds. R2's free tier covers 10 GB", pro: `Unlimited links, ${PRO.storage}` },
  { k: "Viewer analytics", free: "No", pro: "Anonymous: views, daily unique viewers, where people stop, where they came from, devices" },
  { k: "If you cancel", free: "—", pro: "Links you've shared keep playing. New links need Pro or your own bucket" },
  { k: "Update link, same URL", free: "Yes", pro: "Yes" },
  { k: "CLI and MCP", free: "Yes", pro: "Yes, plus the reelbird cloud commands" },
];

export const PRICING_FAQ: Faq[] = [
  {
    id: "is-free",
    q: "Is Reelbird free? Why?",
    a: "Yes. The app is free and MIT licensed: recording, editing, exporting and sharing to your own storage bucket, with no watermark, no limits and no account. A recorder runs on your Mac and costs nothing to give away. Hosting links costs money every month, so that part is the paid plan: Reelbird Pro, $5 a month, for people who'd rather not set up storage.",
  },
  {
    id: "what-pro",
    q: "What does Reelbird Pro add?",
    a: `Reelbird hosts your share links, so there's nothing to set up: unlimited hosted links, ${PRO.storage} of storage, and anonymous viewer analytics: views, daily unique viewers, where people stopped watching, where they came from and their devices. The app itself is the same.`,
  },
  {
    id: "need-pro",
    q: "Do I need Pro to share links?",
    a: "No. Links to your own bucket are free. The setup takes about ten minutes, once, and Cloudflare R2's free tier (10 GB, free egress) covers most people. Pro is for skipping that setup and seeing how many people watched and where they stopped.",
    html: `No. Links to your own bucket are free. The <a href="/docs/sharing/">setup</a> takes about ten minutes, once, and Cloudflare R2's free tier (10 GB, free egress) covers most people. Pro is for skipping that setup and seeing how many people watched and where they stopped.`,
  },
  {
    id: "free-hosting",
    q: "Is there a free hosted plan?",
    a: "No. Hosted links are Pro only. The free way to share is your own bucket.",
  },
  {
    id: "get-pro",
    q: "How do I get Pro?",
    a: "In Reelbird, press Share on a recording and choose Get Reelbird Pro, or open Settings › Sharing › Reelbird Pro and choose Sign In. Approve the code in your browser, then upgrade. From a terminal, reelbird cloud login does the same.",
    html: `In Reelbird, press <strong>Share</strong> on a recording and choose <strong>Get Reelbird Pro</strong>, or open <strong>Settings › Sharing › Reelbird Pro</strong> and choose <strong>Sign In</strong>. Approve the code in your browser, then <a href="${PRO.upgradeURL}">upgrade</a>. From a terminal, <code>reelbird cloud login</code> does the same.`,
  },
  {
    id: "cancel",
    q: "Can I cancel? What happens to my links?",
    a: "Cancel any time from your account page: Manage billing opens Stripe's billing page. Links you already shared keep playing after Pro ends, and you can delete them from the account page or the app. Without Pro you can't add or update hosted links, but you can switch sharing back to your own bucket.",
    html: `Cancel any time from your <a href="${PRO.accountURL}">account page</a>: <strong>Manage billing</strong> opens Stripe's billing page. Links you already shared keep playing after Pro ends, and you can delete them from the account page or the app. Without Pro you can't add or update hosted links, but you can switch sharing back to your own bucket.`,
  },
  {
    id: "analytics-privacy",
    q: "How private are the viewer analytics?",
    a: "They're anonymous: you see how many people watched and how far, never who. They use no cookies. A view counts once at least 3 seconds have played (or most of a shorter video). A viewer is counted with a daily hash of IP address and browser, so no IP address is stored and nobody can be followed across days or links; it also means one person who watches on three different days counts as three viewers. Your own views while signed in and link-preview bots aren't counted.",
    html: `They're anonymous: you see how many people watched and how far, never who. They use no cookies. A view counts once at least 3 seconds have played (or most of a shorter video). A viewer is counted with a daily hash of IP address and browser, so no IP address is stored and nobody can be followed across days or links; it also means one person who watches on three different days counts as three viewers. Your own views while signed in and link-preview bots aren't counted. More on the <a href="/privacy/#pro">privacy page</a>.`,
  },
  {
    id: "what-counts",
    q: "What counts as a view?",
    a: "A view is someone playing the video for at least three seconds. Opening the page without playing isn't a view, and neither are your own plays while you're signed in or link previews from Slack, iMessage and the like. Unique viewers are counted once a day per link.",
  },
  {
    id: "viewers",
    q: "What do viewers see?",
    a: "A plain page with your video at watch.reelbird.app/r/<id>/. It plays in any browser with no sign-in, and a small footer says it was made with Reelbird. Link previews show the video's title and poster.",
  },
  {
    id: "cli",
    q: "Does Pro work from the command line and for agents?",
    a: "Yes. reelbird cloud login signs in, reelbird cloud links and reelbird cloud stats show views, and reelbird cloud use bucket switches back to your own bucket. Scripts and agents can set REELBIRD_CLOUD_TOKEN instead of signing in.",
    html: `Yes. <code>reelbird cloud login</code> signs in, <code>reelbird cloud links</code> and <code>reelbird cloud stats</code> show views, and <code>reelbird cloud use bucket</code> switches back to your own bucket. Scripts and agents can set <code>REELBIRD_CLOUD_TOKEN</code> instead of signing in.`,
  },
  {
    id: "money",
    q: "Where does the money go?",
    a: "Into Reelbird: the hosting, fixes and new features. Pro is the best way to support the project. If you don't need hosting, you can also give once or monthly.",
    html: `Into Reelbird: the hosting, fixes and new features. Pro is the best way to support the project. If you don't need hosting, you can also <a href="/support/">give once or monthly</a>.`,
  },
];
