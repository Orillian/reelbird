# Reelbird Cloud

Reelbird Pro: hosted share links and view analytics, $5/month. Optional: sharing to your own bucket stays free and needs none of this.

- **Links** live in one private R2 bucket. The server serves the viewer page at `<PUBLIC_URL>/r/<id>/` and redirects video, segments and images to short-lived signed R2 URLs, so video bytes go straight from R2 to the viewer.
- **Uploads** come from the app, using the same code as for your own bucket. The server hands out R2 temporary keys limited to one share's folder (`r/<id>/`), valid for an hour and signed locally.
- **Analytics** come from `/e.js`, which the server adds to the viewer page. It has no cookies. A viewer is a daily hash of IP, browser and link. It records views, unique viewers, a retention curve (2-second chunks), sources and devices. The owner's own views and link-preview bots don't count.
- **Pro only.** Hosted links need Reelbird Pro ($5/month): unlimited links, 100 GB and full analytics. There is no free hosted tier; sharing to your own bucket is the free option. An account without Pro can sign in and pay, and its existing links keep playing. An upload that was in progress (touched in the last day) may finish, but it can't create or update links. In development, `/dev/plan` (or `reelbird cloud plan pro`) switches Pro on and off.
- **Billing** uses one Stripe product and one link, with no SDK and no secret key:
  - `/upgrade` sends a signed-in person to the Reelbird Pro Payment Link (`STRIPE_PRO_LINK`, default `buy.stripe.com/5kQ8wO88gaXs9h57Yn3ks05`, ID `plink_1USVjtBbj7zje3qW3ZISlMYw`). The link is tagged with `client_reference_id` and `prefilled_email`, and after payment it returns to `https://watch.reelbird.app/account?welcome=pro`.
  - `POST /stripe/webhook` (signed with `STRIPE_WEBHOOK_SECRET`) only acts on checkouts from that link and on subscriptions to the Reelbird Pro product (`prod_VTSee5NkgzYUpl`, $5/month price `price_1USVjUBbj7zje3qWrQ56SdEO`). The account is Pro while that subscription is active or trialing. The open-source support tiers and anything else on the Stripe account are ignored.
  - Someone who pays through the link before having an account gets Pro when they sign in with the same email.
  - `/billing` opens Stripe's no-code customer portal (`STRIPE_PORTAL_LINK`).
- **Sign-in:** the app and CLI use a device code. The person approves it in the browser and the app receives a token (only its SHA-256 is stored). In development, `/login` signs you in without email.

## Run locally

```sh
cd cloud
bun install
scripts/db.sh start          # Postgres 18 in cloud/.pgdata, port 54329
bun run migrate
bun scripts/setup-r2.ts      # creates the bucket (private) and its CORS rule, once
bun run dev                  # http://localhost:8788
```

`cloud/.env` (gitignored) needs:

```
DATABASE_URL=postgres://postgres@127.0.0.1:54329/reelbird_cloud
PUBLIC_URL=http://localhost:8788
PORT=8788
DEV=1
STATS_SECRET=<random hex>
R2_ACCOUNT_ID=…
R2_ACCESS_KEY_ID=…
R2_SECRET_ACCESS_KEY=…
R2_BUCKET=reelbird-cloud-dev
```

Then, from the repo root (with `export REELBIRD_CLOUD_URL=http://localhost:8788`):

```sh
.build/debug/reelbird cloud login        # approve the code in the browser
.build/debug/reelbird record --synthetic --duration 12 --share --mic none --no-system-audio
.build/debug/reelbird cloud links
.build/debug/reelbird cloud stats <share id>
```

The app's Settings › Sharing has a Reelbird Cloud tab that does the same sign-in. Set `REELBIRD_CLOUD_URL=http://localhost:8788` for the app and CLI to show Cloud and use the local server; without it, Cloud stays hidden until launch.

## Tests

```sh
bun run check   # TypeScript
bun test        # end to end against the dev bucket and reelbird_cloud_test
```

## Before launch

- **Launch switches.** Reelbird Cloud is hidden in released builds until these are flipped. `CloudSettings.launched` (`Sources/ReelbirdShare/Cloud.swift`) controls the app and CLI; with it off, setting `REELBIRD_CLOUD_URL` still shows Cloud for development. `PRO.launched` (`site/src/config/site.ts`) adds the Pro section to /support. Flip both only once the server is live.

- **R2 key.** Replace the dev key with an R2 token limited to the hosted bucket (Object Read & Write). The temporary keys can never exceed their parent key's access.
- **Email.** Magic-link sign-in through Tiffin auth and a mail service (Resend or similar). Until then only `DEV=1` can sign in.
- **Stripe.** In the Dashboard:
  - Add a webhook endpoint `<PUBLIC_URL>/stripe/webhook` for `checkout.session.completed` and `customer.subscription.*`, and put its signing secret in `STRIPE_WEBHOOK_SECRET`.
  - Turn on the no-code customer portal and set `STRIPE_PORTAL_LINK`.
  - The Reelbird Pro link exists (live). Its return URL assumes the production host `watch.reelbird.app`; change it in the Dashboard if the host differs.
  - For local tests: `stripe listen --forward-to localhost:8788/stripe/webhook` in test mode.
  - `/dev/plan` goes away in production (it only exists with `DEV=1`).
- **Legal.** Terms, privacy page, DMCA agent, a report link on the viewer page, and an admin kill switch.
- **Deploy.** Add this as an app in the `reelbird` Tiffin project on its own host, e.g. `watch.reelbird.app`. That's an A record at Namecheap, like the site, so no Cloudflare DNS is needed because the bucket is never public. Set the release command to `bun run migrate`, use Tiffin Postgres for `DATABASE_URL` and Valkey for the event rate limit, and run `measureRecent` from a cron instead of `setInterval`. Then point `CloudSettings.defaultServer` at the production URL.
- **Country.** Countries need a GeoIP lookup (DB-IP Lite, as Tiffin's analytics uses). Today they're empty unless a proxy sends `cf-ipcountry`.
