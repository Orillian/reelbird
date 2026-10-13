import { defineConfig, fontProviders } from "astro/config";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const SITE = "https://reelbird.app";

// Writes dist/sitemap.xml from the pages the build produced: every index.html except 404 and
// pages marked noindex. No dependency, and it can't miss a page.
const sitemap = () => ({
  name: "reelbird-sitemap",
  hooks: {
    "astro:build:done": ({ dir }) => {
      const root = fileURLToPath(dir);
      const urls = [];
      const walk = (d, rel) => {
        for (const e of readdirSync(d, { withFileTypes: true })) {
          if (e.isDirectory()) { if (!e.name.startsWith("_")) walk(join(d, e.name), `${rel}${e.name}/`); continue; }
          if (e.name !== "index.html") continue;
          const html = readFileSync(join(d, e.name), "utf8");
          if (/<meta name="robots" content="noindex"/.test(html)) continue;
          urls.push(`/${rel}`);
        }
      };
      walk(root, "");
      const prio = (u) => (u === "/" ? "1.0" : /^\/(download|features|docs|loom-alternative|screen-studio-alternative|compare)\/$/.test(u) ? "0.8" : "0.6");
      const today = new Date().toISOString().slice(0, 10);
      const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.sort().map((u) => `  <url><loc>${SITE}${u}</loc><lastmod>${today}</lastmod><priority>${prio(u)}</priority></url>`).join("\n")}\n</urlset>\n`;
      writeFileSync(join(root, "sitemap.xml"), xml);
    },
  },
});

// Static output: every page is an HTML file in dist/, so any static host can serve it.
export default defineConfig({
  site: SITE,
  integrations: [sitemap()],
  output: "static",
  trailingSlash: "always",
  build: { format: "directory", inlineStylesheets: "always" },
  compressHTML: true,
  devToolbar: { enabled: false },
  prefetch: false,
  markdown: {
    shikiConfig: { themes: { light: "github-light-high-contrast", dark: "github-dark-dimmed" }, defaultColor: false },
  },
  fonts: [
    {
      provider: fontProviders.local(),
      name: "Fraunces",
      cssVariable: "--font-display",
      fallbacks: ["Georgia", "serif"],
      options: {
        variants: [{ src: ["./src/assets/fonts/fraunces-var.woff2"], weight: "400 650", style: "normal", display: "swap" }],
      },
    },
    {
      provider: fontProviders.local(),
      name: "Instrument Sans",
      cssVariable: "--font-sans",
      fallbacks: ["system-ui", "sans-serif"],
      options: {
        variants: [
          { src: ["./src/assets/fonts/instrument-sans-var.woff2"], weight: "400 700", style: "normal", display: "swap" },
          { src: ["./src/assets/fonts/instrument-sans-italic.woff2"], weight: "400", style: "italic", display: "swap" },
        ],
      },
    },
    {
      provider: fontProviders.local(),
      name: "Commit Mono",
      cssVariable: "--font-mono",
      fallbacks: ["ui-monospace", "monospace"],
      options: {
        variants: [{ src: ["./src/assets/fonts/commit-mono-400.woff2"], weight: "400", style: "normal", display: "swap" }],
      },
    },
  ],
});
