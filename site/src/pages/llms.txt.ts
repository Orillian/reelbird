import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { SITE_URL, SITE_DESCRIPTION, SITE_DESCRIPTION_LONG, SITE_SHORT, GITHUB_URL, REQUIREMENTS, PREBUILT, PRO } from "../config/site";
import { VS_STATEMENTS, CHECKED_LABEL } from "../data/compare";

export const GET: APIRoute = async () => {
  const docs = (await getCollection("docs")).sort((a, b) => a.data.order - b.data.order);
  const u = (p: string) => `${SITE_URL}${p}`;
  const txt = `# Reelbird

> ${SITE_DESCRIPTION}

${SITE_DESCRIPTION_LONG.replace(SITE_DESCRIPTION, "").trim()}

## Key facts

- Price: free and open source (MIT). Recording, editing and exporting have no watermark, no limits and need no account
- Sharing, free: share links to your own S3-compatible bucket (Cloudflare R2 recommended), about ten minutes of setup, once; nothing goes through Reelbird's servers
- Sharing, paid (optional): Reelbird Pro, ${PRO.price}/month, hosts your links with nothing to set up: unlimited hosted links, ${PRO.storage} of storage, and anonymous viewer analytics (views, daily unique viewers, retention, referrers, devices) without cookies. Cancel any time; links keep playing after Pro ends. There is no free hosted tier
- Platform: macOS only. Runs on ${REQUIREMENTS.runs}. ${REQUIREMENTS.hardware}
- Download: ${PREBUILT.url} (signed and notarised by Apple)
- Build from source: git clone ${GITHUB_URL}.git && cd reelbird && make install. Needs ${REQUIREMENTS.tools} (${REQUIREMENTS.toolsDetail.replace(/\.$/, "")})
- Privacy: no telemetry, analytics or update checks in the app; recordings stay on your Mac unless you share
- Agents: reelbird CLI (--json) and an MCP server (reelbird mcp) for Claude Code, Codex and Cursor
- Repository: ${GITHUB_URL}
- Website: ${SITE_URL}/
- Short description: ${SITE_SHORT}
- Category: open-source screen recorder for the Mac that does the Loom job (instant link) and the Screen Studio job (auto-zoom polish) from one take

## How Reelbird compares (checked ${CHECKED_LABEL})

${VS_STATEMENTS.map((v) => `- ${v.text}`).join("\n")}

## Docs

${docs.map((d) => `- [${d.data.title}](${u(`/docs/${d.id}.md`)}): ${d.data.description}`).join("\n")}
- [Download and build](${u("/download/")}): Step-by-step install, permissions, local signing, updating and troubleshooting
- [Pricing](${u("/pricing/")}): Free vs Reelbird Pro (${PRO.price}/month for hosted links and viewer analytics), cancelling, and analytics privacy
- [FAQ](${u("/faq/")}): Straight answers about price, install, requirements, links and privacy

## Features

- [Auto-zoom and smooth cursor](${u("/features/auto-zoom/")})
- [Instant share links, to your own bucket or hosted by Reelbird Pro](${u("/features/share-links/")})
- [Audio and on-device captions](${u("/features/audio-captions/")})
- [CLI and MCP for coding agents](${u("/features/agents/")})

## Comparisons

- [Free, open-source Loom alternative for Mac](${u("/loom-alternative/")}): no 5-minute cap, no 25-video limit, files stay on your Mac
- [Free, open-source Screen Studio alternative](${u("/screen-studio-alternative/")}): auto-zoom without a subscription, plus a link the moment you stop
- [Mac screen recorders compared](${u("/compare/")}): Reelbird, Loom, Screen Studio, Cap, OpenScreen, CleanShot X, Tella and Screenity, with prices, free-plan limits, licences, share links and auto-zoom

## Optional

- [Changelog](${u("/changelog/")})
- [Privacy](${u("/privacy/")})
- [Full text for LLMs](${u("/llms-full.txt")})
`;
  return new Response(txt, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
};
