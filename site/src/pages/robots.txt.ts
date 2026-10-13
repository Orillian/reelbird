import type { APIRoute } from "astro";
import { SITE_URL } from "../config/site";

// Allow everyone, and name the search and AI retrieval bots explicitly: we want to be found and cited.
const bots = ["Googlebot", "Bingbot", "Applebot", "Applebot-Extended", "Google-Extended", "OAI-SearchBot", "ChatGPT-User", "GPTBot", "Claude-SearchBot", "Claude-User", "ClaudeBot", "PerplexityBot", "Perplexity-User", "DuckDuckBot"];

export const GET: APIRoute = () =>
  new Response(`${bots.map((b) => `User-agent: ${b}\nAllow: /\n`).join("\n")}\nUser-agent: *\nAllow: /\n\nSitemap: ${SITE_URL}/sitemap.xml\n`, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
