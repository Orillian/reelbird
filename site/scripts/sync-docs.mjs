// Copies the repo's docs into src/content/docs/ so /docs stays in sync with README.md and docs/*.md.
//
// - Runs before `astro dev` and `astro build`.
// - When the site is built on its own (only site/ uploaded, no ../docs), it keeps the
//   committed copies and says so. Commit src/content/docs/ after running it.
// - Repo-relative links become site links; anything else in the repo links to GitHub.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..", "..");
const out = join(here, "..", "src", "content", "docs");
const GITHUB = "https://github.com/btahir/reelbird";

if (!existsSync(join(repo, "docs", "SHARING.md")) || !existsSync(join(repo, "README.md"))) {
  console.log("sync-docs: repo docs not found next to site/; using the committed copies in src/content/docs/");
  process.exit(0);
}

const readme = readFileSync(join(repo, "README.md"), "utf8");

/** Returns the README section under `## heading` (or `### heading`), without the heading line. */
function section(md, heading) {
  const lines = md.split("\n");
  const start = lines.findIndex((l) => /^#{2,3} /.test(l) && l.replace(/^#+ /, "").trim() === heading);
  if (start < 0) throw new Error(`sync-docs: README has no section "${heading}"`);
  const level = lines[start].match(/^#+/)[0].length;
  let end = lines.length;
  let inFence = false;
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith("```")) inFence = !inFence;
    if (inFence) continue;
    const m = lines[i].match(/^(#+) /);
    if (m && m[1].length <= level) { end = i; break; }
    if (/^---\s*$/.test(lines[i])) { end = i; break; }
  }
  // Promote nested headings by (level - 2) so a ### section reads as ##.
  const shift = level - 2;
  return lines
    .slice(start + 1, end)
    .map((l) => (shift > 0 && /^#{3,6} /.test(l) ? l.slice(shift) : l))
    .join("\n")
    .trim();
}

/** Strips the first `# Title` line of a docs file and returns [title, body]. */
function splitTitle(md) {
  const m = md.match(/^# (.+)\n+/);
  return m ? [m[1].trim(), md.slice(m[0].length).trim()] : ["", md.trim()];
}

const slug = (s) =>
  s.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/\s/g, "-");

const pages = [
  {
    id: "install",
    title: "Install from source",
    description: "Build Reelbird from source on macOS 15 or later with the Command Line Tools, grant permissions, and keep them across rebuilds.",
    order: 1,
    body: section(readme, "Install from source"),
  },
  {
    id: "sharing",
    title: "Sharing setup with Cloudflare R2",
    description: "Connect Reelbird to your own Cloudflare R2 bucket (or any S3-compatible storage) for instant share links. Step by step, with costs and privacy notes.",
    order: 2,
    body: splitTitle(readFileSync(join(repo, "docs", "SHARING.md"), "utf8"))[1],
  },
  {
    id: "shortcuts",
    title: "Keyboard shortcuts",
    description: "Every Reelbird keyboard shortcut: global record and pause, the picker, countdown and the editor timeline.",
    order: 3,
    body: section(readme, "Keyboard shortcuts"),
  },
  {
    id: "cli",
    title: "Command line",
    description: "The reelbird command line tool: list sources, record, edit, export, caption and share from a terminal or script, with JSON output.",
    order: 4,
    body: section(readme, "Command line"),
  },
  {
    id: "mcp",
    title: "MCP server for Claude Code, Codex and Cursor",
    description: "Run reelbird mcp so coding agents can record a demo of their change, export it and hand you the share link. Setup for Claude Code, Codex and Cursor.",
    order: 5,
    body: section(readme, "MCP server"),
  },
  {
    id: "troubleshooting",
    title: "Troubleshooting",
    description: "Fixes for Screen Recording permission loops, Keychain prompts, missing keystrokes, captions on older macOS and recovering a take after a crash.",
    order: 6,
    body: section(readme, "Troubleshooting"),
  },
  {
    id: "format",
    title: "The .reelbird project format",
    description: "How a .reelbird project is laid out: standard MP4 tracks, JSON edits and an event log, with relative paths. The schema for tools that read or write projects.",
    order: 7,
    body: splitTitle(readFileSync(join(repo, "docs", "FORMAT.md"), "utf8"))[1],
  },
  {
    id: "architecture",
    title: "Architecture",
    description: "How Reelbird is built: ScreenCaptureKit capture, segmented writers, the Metal compositor, serverless sharing, on-device audio and captions.",
    order: 8,
    body: splitTitle(readFileSync(join(repo, "docs", "ARCHITECTURE.md"), "utf8"))[1],
  },
];

// Which page owns each heading, so README anchors (#troubleshooting) resolve across pages.
const owner = new Map();
for (const p of pages) {
  owner.set(slug(p.title), p.id);
  for (const m of p.body.matchAll(/^#{2,6} (.+)$/gm)) owner.set(slug(m[1].replace(/[*`]/g, "")), p.id);
}
// README section names that became page titles.
for (const [name, id] of [["install-from-source", "install"], ["keyboard-shortcuts", "shortcuts"], ["command-line", "cli"], ["mcp-server", "mcp"], ["sharing", "sharing"], ["troubleshooting", "troubleshooting"]]) owner.set(name, id);

const docFile = { "SHARING.md": "sharing", "FORMAT.md": "format", "ARCHITECTURE.md": "architecture" };

function rewriteLink(href, currentId) {
  if (/^(https?:|mailto:)/.test(href)) return href;
  const [path, hash] = href.split("#");
  if (!path) {
    const id = owner.get(hash) ?? currentId;
    return id === currentId ? `#${hash}` : `/docs/${id}/#${hash}`;
  }
  const file = path.replace(/^(\.\/)?(docs\/)?/, "");
  if (docFile[file]) return `/docs/${docFile[file]}/${hash ? `#${hash}` : ""}`;
  if (path === "LICENSE" || path === "CONTRIBUTING.md" || path.startsWith("scripts/") || path.startsWith("Sources/")) {
    return `${GITHUB}/blob/main/${path}${hash ? `#${hash}` : ""}`;
  }
  return href;
}

mkdirSync(out, { recursive: true });
for (const p of pages) {
  const body = p.body
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\[(?:docs\/)?(SHARING|FORMAT|ARCHITECTURE)\.md\]/g, (_, f) => `[${{ SHARING: "Sharing setup", FORMAT: "Project format", ARCHITECTURE: "Architecture" }[f]}]`)
    .replace(/\]\(([^)\s]+)\)/g, (_, href) => `](${rewriteLink(href, p.id)})`)
    .replace(/\n{3,}/g, "\n\n");
  const fm = [
    "---",
    `title: ${JSON.stringify(p.title)}`,
    `description: ${JSON.stringify(p.description)}`,
    `order: ${p.order}`,
    "---",
    "",
    "<!-- Generated by scripts/sync-docs.mjs from the repo's README.md and docs/. Edit those, not this file. -->",
    "",
    "",
  ].join("\n");
  writeFileSync(join(out, `${p.id}.md`), `${fm}${body}\n`);
}
console.log(`sync-docs: wrote ${pages.length} pages to src/content/docs/`);
