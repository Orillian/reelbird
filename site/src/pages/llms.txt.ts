import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { SITE_URL, SITE_DESCRIPTION, SITE_DESCRIPTION_LONG, GITHUB_URL, REQUIREMENTS } from "../config/site";

export const GET: APIRoute = async () => {
  const docs = (await getCollection("docs")).sort((a, b) => a.data.order - b.data.order);
  const u = (p: string) => `${SITE_URL}${p}`;
  const txt = `# Reelbird

> ${SITE_DESCRIPTION}

${SITE_DESCRIPTION_LONG.replace(SITE_DESCRIPTION, "").trim()}

## Key facts

- Licence: MIT, free, no paid tier, no watermark
- Platform: macOS only. Runs on ${REQUIREMENTS.runs}. ${REQUIREMENTS.hardware}
- Build requirement: ${REQUIREMENTS.tools} (${REQUIREMENTS.toolsDetail.replace(/\.$/, "")})
- Install: git clone ${GITHUB_URL}.git && cd reelbird && make install (no signed download yet)
- No account, no telemetry, no Reelbird server; share links point at your own S3-compatible bucket (Cloudflare R2 recommended)
- Agents: reelbird CLI (--json) and an MCP server (reelbird mcp) for Claude Code, Codex and Cursor
- Repository: ${GITHUB_URL}
- Website: ${SITE_URL}/

## Docs

${docs.map((d) => `- [${d.data.title}](${u(`/docs/${d.id}.md`)}): ${d.data.description}`).join("\n")}
- [Download and build](${u("/download/")}): Step-by-step install, permissions, local signing, updating and troubleshooting
- [FAQ](${u("/faq/")}): Straight answers about price, install, requirements, links and privacy

## Features

- [Auto-zoom and smooth cursor](${u("/features/auto-zoom/")})
- [Instant share links to your own bucket](${u("/features/share-links/")})
- [Audio and on-device captions](${u("/features/audio-captions/")})
- [CLI and MCP for coding agents](${u("/features/agents/")})

## Comparisons

- [Free, open-source Loom alternative for Mac](${u("/loom-alternative/")})
- [Free, open-source Screen Studio alternative](${u("/screen-studio-alternative/")})
- [Mac screen recorders compared](${u("/compare/")}): Loom, Screen Studio, Cap, OpenScreen, CleanShot X, Tella

## Optional

- [Changelog](${u("/changelog/")})
- [Privacy](${u("/privacy/")})
- [Support Reelbird](${u("/support/")})
- [Full text for LLMs](${u("/llms-full.txt")})
`;
  return new Response(txt, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
};
