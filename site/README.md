# reelbird.shiptiffin.app

The Reelbird website: a static [Astro](https://astro.build) site with no UI framework and a few
small inline scripts (theme toggle, copy buttons, video loading).

## Develop

```sh
cd site
bun install
bun run dev        # http://localhost:4321
bun run build      # writes dist/
bun run preview    # serves dist/
```

`bun run dev` and `bun run build` first run `scripts/sync-docs.mjs`, which copies the repo's
`README.md` and `docs/*.md` into `src/content/docs/`. Commit those copies: when only `site/` is
uploaded (no `../docs`), the build uses them and says so.

## Deploy (Tiffin static app)

The site is a Tiffin `static` app. In the project's `tiffin.config.ts`:

```ts
apps: {
  site: {
    framework: "static",
    path: "site",
    build: "bun run build",
    output: "dist",
  },
}
```

- **Install and build:** the box sees `bun.lock`, so it runs `bun install` then `bun run build`.
  Astro 7 needs Node.js 22.12 or later if it runs under Node; it also builds under Bun.
- **Output:** `dist/`. Pages are `dist/<page>/index.html`, so `/download` redirects to
  `/download/` and every canonical URL ends in a slash. `dist/404.html` is served with status 404
  for unknown paths. There is no client-side router, so no `index.html` fallback is needed.
- **Caching:** Astro's fingerprinted files in `/_astro/` (CSS, JS, fonts, optimised images) are
  cached for a year by the edge. Everything else (`/media/*.mp4`, `/og/*.png`, favicons,
  `sitemap.xml`, `llms.txt`) is revalidated with an ETag on each visit.
- **Headers:** the edge adds `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy` and
  `frame-ancestors 'none'`. Nothing else is required.
- **Env:** none. No secrets, no analytics.
- **Build time:** about 6 s cold on an M-series Mac (most of it is image optimisation, cached in
  `node_modules/.astro` afterwards), about 1 s warm.

## Where things live

| What | Where |
|---|---|
| Site URL, GitHub URL, version, requirements, **Stripe links**, launch video, prebuilt download switch | `src/config/site.ts` (the only file with Stripe URLs) |
| FAQ (page and `FAQPage` JSON-LD) | `src/data/faq.ts` |
| Competitor facts, with sources and the date checked | `src/data/compare.ts` |
| Release notes (page and RSS) | `src/data/changelog.ts` |
| Design tokens (paper and ink themes) | `src/styles/global.css` |
| Fonts (Fraunces, Instrument Sans, Commit Mono; OFL, subset woff2) | `src/assets/fonts/`, registered in `astro.config.mjs` |
| Screenshots and illustrations (copies of `brand/`) | `src/assets/shots/`, `src/assets/illustrations/` |
| Hero clip and auto-zoom loop | `public/media/` |
| Open Graph images (1200×630, committed) | `public/og/`, rendered by `scripts/og.sh` |
| `llms.txt`, `llms-full.txt`, `robots.txt`, RSS | `src/pages/*.ts` endpoints |
| `sitemap.xml` | written after the build by the small integration in `astro.config.mjs` |

### Launch video

Set `LAUNCH_VIDEO.url` in `src/config/site.ts` to an MP4 URL (`kind: "file"`) or an embed URL
such as `https://www.youtube-nocookie.com/embed/<id>` (`kind: "embed"`), then rebuild. Until
then the home page shows a poster and says the video is on its way.

### Prebuilt download

`PREBUILT.enabled` is `false`. When a release zip from `scripts/dist.sh` is on GitHub Releases,
check `PREBUILT.url` and `PREBUILT.note`, set `enabled: true` and rebuild. `/download` then shows
it above the build-from-source steps.

### Open Graph images

They are plain PNGs, so the build needs no browser. After changing a page title, re-render them
from a full checkout (needs Chrome or Chromium; `pngquant` is used when installed):

```sh
site/scripts/og.sh
```

The template is `brand/src/og.html`. Each page names its image with the `og` prop of its layout.
