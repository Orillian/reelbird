/**
 * Free vs Reelbird Pro. /pricing renders the table and the FAQ (and its FAQPage JSON-LD) from here,
 * and llms-full.txt repeats them, so the facts are said one way. Prices and limits come from PRO in
 * config/site.ts.
 */
import { PRO } from "../config/site";
import type { Faq } from "./faq";

export const PLAN_ROWS: { k: string; free: string; pro: string }[] = [
  { k: "Price", free: "Free", pro: `${PRO.price} a month` },
  { k: "Record, edit, export", free: "Everything, with no watermark and no limits", pro: "The same app" },
  { k: "Account", free: "None needed", pro: "Your email address" },
  { k: "Share links", free: "Hosted in your own bucket: Cloudflare R2 or any S3-compatible storage", pro: "Hosted by Reelbird at watch.reelbird.app" },
  { k: "Setup", free: "About ten minutes, once", pro: "None. Sign in from Settings › Sharing" },
  { k: "Storage", free: "Whatever your bucket holds. R2's free tier covers 10 GB", pro: `Unlimited links, ${PRO.storage}` },
  { k: "Viewer analytics", free: "No", pro: "Views, unique viewers, where people stopped, where they came from, devices" },
  { k: "Update link, same URL", free: "Yes", pro: "Yes" },
  { k: "CLI and MCP", free: "Yes", pro: "Yes, plus reelbird cloud" },
];

export const PRICING_FAQ: Faq[] = [
  {
    id: "is-free",
    q: "Is Reelbird free?",
    a: "Yes. The app is free and MIT licensed: recording, editing, exporting and sharing to your own storage bucket, with no watermark, no limits and no account. Reelbird Pro is an optional $5-a-month plan for people who'd rather not set up storage.",
  },
  {
    id: "what-pro",
    q: "What does Reelbird Pro add?",
    a: `Reelbird hosts your share links, so there's nothing to set up: unlimited hosted links, ${PRO.storage} of storage, and viewer analytics with views, unique viewers, where people stopped watching, where they came from and their devices. The app itself is the same.`,
  },
  {
    id: "need-pro",
    q: "Do I need Pro to share links?",
    a: "No. Links to your own bucket are free. The setup takes about ten minutes, once, and Cloudflare R2's free tier (10 GB, free egress) covers most people. Pro is for skipping that setup and seeing who watched.",
    html: `No. Links to your own bucket are free. The <a href="/docs/sharing/">setup</a> takes about ten minutes, once, and Cloudflare R2's free tier (10 GB, free egress) covers most people. Pro is for skipping that setup and seeing who watched.`,
  },
  {
    id: "free-hosting",
    q: "Is there a free hosted plan?",
    a: "No. Hosted links are Pro only. The free way to share is your own bucket.",
  },
  {
    id: "get-pro",
    q: "How do I get Pro?",
    a: "In Reelbird, open Settings › Sharing › Reelbird Cloud and choose Sign In. Approve the code in your browser, then upgrade. From a terminal, reelbird cloud login does the same.",
    html: `In Reelbird, open <strong>Settings › Sharing › Reelbird Cloud</strong> and choose <strong>Sign In</strong>. Approve the code in your browser, then <a href="${PRO.upgradeURL}">upgrade</a>. From a terminal, <code>reelbird cloud login</code> does the same.`,
  },
  {
    id: "cancel",
    q: "Can I cancel? What happens to my links?",
    a: "Cancel any time from your account page: Manage subscription opens Stripe's billing page. Links you already shared keep playing after Pro ends, and you can delete them from the account page or the app. Without Pro you can't add or update hosted links, but you can switch sharing back to your own bucket.",
    html: `Cancel any time from your <a href="${PRO.accountURL}">account page</a>: <strong>Manage subscription</strong> opens Stripe's billing page. Links you already shared keep playing after Pro ends, and you can delete them from the account page or the app. Without Pro you can't add or update hosted links, but you can switch sharing back to your own bucket.`,
  },
  {
    id: "analytics-privacy",
    q: "How private are the viewer analytics?",
    a: "They use no cookies. A viewer is counted with a daily hash of IP address and browser, so no IP address is stored and nobody can be followed across days or links. Your own views and link-preview bots aren't counted.",
    html: `They use no cookies. A viewer is counted with a daily hash of IP address and browser, so no IP address is stored and nobody can be followed across days or links. Your own views and link-preview bots aren't counted. More on the <a href="/privacy/#pro">privacy page</a>.`,
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
