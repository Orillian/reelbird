/**
 * Competitor facts for /compare and the alternative pages. Every row links its source.
 * Re-check prices and features before changing CHECKED.
 */
export const CHECKED = "2026-10-12";
export const CHECKED_LABEL = "12 October 2026";

export interface Product {
  id: string;
  name: string;
  price: string;
  platforms: string;
  openSource: string;
  links: string;
  autoZoom: string;
  notes: string;
  sources: { label: string; href: string }[];
}

export const PRODUCTS: Product[] = [
  {
    id: "reelbird",
    name: "Reelbird",
    price: "Free",
    platforms: "macOS 15+",
    openSource: "Yes, MIT",
    links: "Yes, to your own bucket. The same link updates after editing",
    autoZoom: "Yes",
    notes: "Build from source for now. No account",
    sources: [{ label: "github.com/btahir/reelbird", href: "https://github.com/btahir/reelbird" }],
  },
  {
    id: "loom",
    name: "Loom",
    price: "Starter free (25 videos, 5 min, 720p). Business $18/user/mo, Business + AI $24/user/mo",
    platforms: "Mac, Windows, web, mobile",
    openSource: "No",
    links: "Yes, on Loom's cloud",
    autoZoom: "No",
    notes: "Starter users can't download their videos; downloads need Business or higher",
    sources: [
      { label: "Loom pricing", href: "https://www.loom.com/pricing" },
      { label: "Loom downloads", href: "https://support.atlassian.com/loom/docs/download-your-loom-video/" },
    ],
  },
  {
    id: "screen-studio",
    name: "Screen Studio",
    price: "$29/mo, or $9/mo billed yearly. One-time licences no longer sold to new buyers",
    platforms: "macOS",
    openSource: "No",
    links: "Yes, after export (1080p60, up to 30 min)",
    autoZoom: "Yes",
    notes: "Mature, polished editor",
    sources: [{ label: "screen.studio", href: "https://screen.studio/" }],
  },
  {
    id: "cap",
    name: "Cap",
    price: "Free for personal use (5-min links). Desktop $29/yr or $58 once. Pro $12/user/mo",
    platforms: "Mac, Windows",
    openSource: "Source on GitHub (AGPL)",
    links: "Yes (Instant mode)",
    autoZoom: "Yes (Studio mode)",
    notes: "Custom S3 is a Pro feature. Self-hosting possible",
    sources: [
      { label: "Cap pricing", href: "https://cap.so/pricing" },
      { label: "Cap on GitHub", href: "https://github.com/CapSoftware/Cap" },
    ],
  },
  {
    id: "openscreen",
    name: "OpenScreen",
    price: "Free",
    platforms: "Windows, Mac (13+), Linux",
    openSource: "Yes, MIT",
    links: "No",
    autoZoom: "Yes",
    notes: "Electron. Signed and notarised Mac builds. CLI and MCP",
    sources: [{ label: "OpenScreen on GitHub", href: "https://github.com/getopenscreen/openscreen" }],
  },
  {
    id: "cleanshot",
    name: "CleanShot X",
    price: "$35 once (1 year of updates), or Pro $10/user/mo billed yearly",
    platforms: "macOS",
    openSource: "No",
    links: "Yes (CleanShot Cloud)",
    autoZoom: "Smart zooms in its video editor",
    notes: "A screenshot tool first",
    sources: [{ label: "CleanShot pricing", href: "https://cleanshot.com/pricing" }],
  },
  {
    id: "tella",
    name: "Tella",
    price: "Pro $13/user/mo, Premium $19/user/mo (billed yearly). No free plan listed",
    platforms: "Mac, Windows, Chrome",
    openSource: "No",
    links: "Yes",
    autoZoom: "Yes",
    notes: "Hosted, team-focused",
    sources: [{ label: "Tella pricing", href: "https://www.tella.com/pricing" }],
  },
];

export const byId = (id: string) => PRODUCTS.find((p) => p.id === id)!;
