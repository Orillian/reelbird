// Copies the repo's docs into src/content/docs/ so /docs stays in sync with README.md and docs/*.md.
//
// - Runs before `astro dev` and `astro build`.
// - When the site is built on its own (only site/ uploaded, no ../docs), it keeps the
//   committed copies and says so. Commit src/content/docs/ after running it.
// - Repo-relative links become site links; anything else in the repo links to GitHub.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";
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

/** Last commit date (YYYY-MM-DD) of a repo file, or today when git isn't available. */
function updated(file) {
  try {
    const d = execFileSync("git", ["log", "-1", "--format=%cs", "--", file], { cwd: repo, encoding: "utf8" }).trim();
    if (d) return d;
  } catch {}
  return new Date().toISOString().slice(0, 10);
}

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
    source: "README.md",
    title: "Install from source",
    seoTitle: "Install Reelbird from source on macOS 15+",
    description: "Clone the repo and run make install. Needs macOS 15 or later and Apple’s Command Line Tools; no Xcode. Permissions and local signing explained.",
    order: 1,
    body: section(readme, "Install from source"),
  },
  {
    id: "sharing",
    source: "docs/SHARING.md",
    title: "Sharing setup with Cloudflare R2",
    seoTitle: "Set up Reelbird share links on Cloudflare R2",
    description: "A one-time, ten-minute setup: an R2 bucket, a scoped API token and a public URL. Costs, privacy and other S3-compatible hosts.",
    order: 2,
    body: splitTitle(readFileSync(join(repo, "docs", "SHARING.md"), "utf8"))[1],
  },
  {
    id: "shortcuts",
    source: "README.md",
    title: "Keyboard shortcuts",
    seoTitle: "Reelbird keyboard shortcuts",
    description: "Every Reelbird keyboard shortcut: start and stop from any app, the picker, the countdown, and the editor timeline.",
    order: 3,
    body: section(readme, "Keyboard shortcuts"),
  },
  {
    id: "cli",
    source: "README.md",
    title: "Command line",
    seoTitle: "Reelbird command-line tool reference",
    description: "Record, edit, export, caption and share from the terminal. Every command takes --json for scripts and agents.",
    order: 4,
    body: section(readme, "Command line"),
  },
  {
    id: "mcp",
    source: "README.md",
    title: "MCP server for Claude Code, Codex and Cursor",
    seoTitle: "Reelbird MCP server: setup for Claude Code and Cursor",
    description: "Add the Reelbird MCP server to Claude Code, Codex or Cursor and let agents list screens, record, export and share.",
    order: 5,
    body: section(readme, "MCP server"),
  },
  {
    id: "troubleshooting",
    source: "README.md",
    title: "Troubleshooting",
    seoTitle: "Reelbird troubleshooting: permissions and fixes",
    description: "Screen Recording permission after a rebuild, Keychain prompts, keystrokes, captions and recovering a take after a crash.",
    order: 6,
    body: section(readme, "Troubleshooting"),
  },
  {
    id: "format",
    source: "docs/FORMAT.md",
    title: "The .reelbird project format",
    seoTitle: "The .reelbird project format",
    description: "A folder of standard MP4 files, JSON and an event log with relative paths. Spec for tools that read or write Reelbird projects.",
    order: 7,
    body: splitTitle(readFileSync(join(repo, "docs", "FORMAT.md"), "utf8"))[1],
  },
  {
    id: "architecture",
    source: "docs/ARCHITECTURE.md",
    title: "Architecture",
    seoTitle: "How Reelbird is built: architecture",
    description: "ScreenCaptureKit capture in 2-second segments, a Metal compositor shared by preview and export, serverless sharing, and on-device audio and captions.",
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
    `seoTitle: ${JSON.stringify(p.seoTitle)}`,
    `description: ${JSON.stringify(p.description)}`,
    `order: ${p.order}`,
    `updated: ${JSON.stringify(updated(p.source))}`,
    `source: ${JSON.stringify(p.source)}`,
    "---",
    "",
    "<!-- Generated by scripts/sync-docs.mjs from the repo's README.md and docs/. Edit those, not this file. -->",
    "",
    "",
  ].join("\n");
  writeFileSync(join(out, `${p.id}.md`), `${fm}${body}\n`);
}
console.log(`sync-docs: wrote ${pages.length} pages to src/content/docs/`);
