// Reelbird's website and cloud on ShipTiffin. Pushes to main deploy: the box builds each
// app from its folder, and only when a push touches that folder (watch).
// After an edit: tiffin plan, then tiffin apply --confirm <hash>. Secrets live on the box.
export default {
  project: "reelbird",
  sleepAfter: "24h",
  keepVersions: 2,
  env: {
    // Public site id for the self-hosted Umami at project-analytics.shiptiffin.app.
    PUBLIC_UMAMI_WEBSITE_ID: "415f1047-be59-47fa-a877-e57c2f25e010",
  },
  apps: {
    // reelbird.app: the Astro site. Its build copies README.md and docs/ into the docs pages.
    site: {
      framework: "static",
      routes: ["reelbird", "reelbird.app"],
      output: "dist",
      git: { repo: "btahir/reelbird", branch: "main", path: "site", previews: "off" },
      watch: ["site/**", "docs/**", "README.md"],
    },
    // watch.reelbird.app: hosted links, analytics and Pro billing.
    cloud: {
      framework: "hono",
      routes: ["reelbird-cloud", "watch.reelbird.app"],
      healthcheck: "/healthz",
      release: "bun run migrate",
      git: { repo: "btahir/reelbird", branch: "main", path: "cloud", previews: "off" },
      watch: ["cloud/**"],
    },
  },
  services: {
    analytics: { attribution: {} },
  },
  domains: {
    "reelbird.app": { www: "redirect", primary: true },
    "watch.reelbird.app": { primary: true },
  },
};
