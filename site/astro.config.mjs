import { defineConfig, fontProviders } from "astro/config";

// Static output: every page is an HTML file in dist/, served by Tiffin's static edge.
export default defineConfig({
  site: "https://reelbird.shiptiffin.app",
  output: "static",
  trailingSlash: "always",
  build: { format: "directory", inlineStylesheets: "always" },
  compressHTML: true,
  devToolbar: { enabled: false },
  prefetch: false,
  markdown: {
    shikiConfig: { themes: { light: "github-light", dark: "github-dark-dimmed" }, defaultColor: false },
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
