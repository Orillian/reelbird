# Sharing setup

This page sets up sharing to a storage bucket that you own, which is free. Reelbird uploads a small viewer page and the video to your bucket, and anyone with the link can watch in a browser. Nothing goes through Reelbird's servers.

If you'd rather not set up a bucket, [Reelbird Pro](#reelbird-pro-no-setup) hosts your links for $5 a month.

Cloudflare R2 is the recommended host because it doesn't charge for downloads (egress), so a popular video costs the same as an unwatched one. Any S3-compatible service works too (see [Other S3-compatible services](#other-s3-compatible-services)).

Setup takes about ten minutes, once.

## What Reelbird puts in the bucket

Each share gets a random short ID and lives under one prefix (default `r/`):

```
r/<id>/index.html       the viewer page (the link you send)
r/<id>/  and  r/<id>    copies of the viewer page, so the link works on hosts that don't serve index.html
r/<id>/meta.json        title, duration, chapters, which files to play
r/<id>/card.jpg         title card for link previews
r/<id>/hls/             the stream uploaded while you record (playlist + 2-second segments)
r/<id>/video.<n>.mp4    the polished version, after you edit and choose Update link
r/<id>/poster.<n>.jpg   preview image for link unfurls
r/<id>/captions.<n>.vtt captions, if you made them
```

`<n>` goes up by one with every update, so browsers and caches never show a stale video. Reelbird deletes the previous revision's files after an update.

The link is `https://<your public URL>/r/<id>/`. It never changes, even when you update the video.

## Cloudflare R2

You need a Cloudflare account. R2 needs a payment method on file even if you stay inside the free tier.

### 1. Create a bucket

1. In the Cloudflare dashboard, open **R2 object storage**.
2. Select **Create bucket**.
3. Name it, for example `reelbird`. Leave the location on **Automatic** unless you need data to stay in a jurisdiction (EU, for example). Note: a bucket in a jurisdiction uses a different endpoint, shown in step 3.
4. Select **Create bucket**.

### 2. Give the bucket a public URL

Viewers need to read the files without credentials. Pick one:

**Custom domain (recommended).** Needs a domain whose DNS is on Cloudflare, in the same account.

1. Open the bucket, then **Settings**.
2. Under **Custom Domains**, select **Add**.
3. Enter a subdomain such as `video.example.com`, select **Continue**, review the DNS record, then **Connect Domain**.
4. Wait until the status changes from **Initializing** to **Active** (usually a few minutes).

Your public URL is `https://video.example.com`. A custom domain also gets Cloudflare's cache, so repeat views are fast.

**r2.dev URL (quick start).** No domain needed, but Cloudflare rate-limits it and says it is meant for development, not production. Fine for trying Reelbird or occasional links to a few people.

1. Open the bucket, then **Settings**.
2. Under **Public Development URL**, select **Enable**.
3. Type `allow` to confirm, then select **Allow**.
4. Copy the URL shown, which looks like `https://pub-<long id>.r2.dev`.

You can switch from r2.dev to a custom domain later. Links you already sent keep using the old URL, so leave r2.dev enabled until you no longer need them.

### 3. Create an API token for Reelbird

1. Go back to **R2 object storage** → **Overview**.
2. Under **Account Details**, select **Manage** next to **API Tokens**.
3. Select **Create Account API token** (it keeps working if your user ever leaves the account).
4. Name it `Reelbird`.
5. Under **Permissions**, choose **Object Read & Write**.
6. Limit it to the bucket you created (choose to apply the token to specific buckets, then select it). Reelbird then can't touch anything else in your account.
7. Leave the TTL at forever, or pick an expiry if you prefer to rotate keys.
8. Create the token. Cloudflare shows the **Access Key ID** and the **Secret Access Key**. **Copy the secret now:** Cloudflare never shows it again.

The endpoint is `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`. Buckets in a jurisdiction use `https://<ACCOUNT_ID>.eu.r2.cloudflarestorage.com` (EU) or the matching jurisdiction endpoint. Your account ID is on the R2 overview page.

### 4. Connect Reelbird

Click the Reelbird icon in the menu bar, choose **Settings…**, then **Sharing**, and fill in:

| Field | Value |
|---|---|
| Endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| Bucket | `reelbird` (your bucket name) |
| Region | `auto` |
| Access key ID | from step 3 |
| Secret access key | from step 3 |
| Public URL | your custom domain or `https://pub-….r2.dev` |
| Prefix | `r` (default) |

Choose **Test Connection**. Reelbird uploads a small test file, reads it back with your keys and through your public URL, then deletes it. If both work, choose **Save**.

The secret key is stored in your macOS Keychain. The other fields are saved in `~/Library/Application Support/Reelbird/share.json`. The `reelbird` command line tool uses the same settings.

### CORS

Not needed. The viewer page, playlist and video are all served from the same origin (your public URL), so the browser never makes a cross-origin request. You only need a CORS rule if you embed Reelbird videos on a different website. In that case, add a rule in the bucket's **Settings** → **CORS Policy** that allows `GET` and `HEAD` from that site.

### What it costs

R2 pricing as of October 2026 ([Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/)):

| | Free each month | Then |
|---|---|---|
| Storage (Standard) | 10 GB | $0.015 per GB-month |
| Writes (Class A: uploads) | 1 million | $4.50 per million |
| Reads (Class B: views) | 10 million | $0.36 per million |
| Egress (data sent to viewers) | unlimited | free |

In practice storage is the only number that matters. The stream uploaded while you record uses roughly 30 MB per minute, and a polished update adds the size of your export (both are kept, so the link still plays if the polished file is ever missing). The free 10 GB holds a few hours of shared video. Past that, 100 GB costs about $1.35 a month. Uploads while recording are one write per 2-second segment (about 30 per minute), so a month would need around 550 hours of recording to use the free million. Delete old shares to keep storage down.

## Reelbird Pro (no setup)

Reelbird Pro is the optional paid way to share: Reelbird hosts your links, so there's no bucket, token or public URL to set up. It costs $5 a month and includes unlimited hosted links, 100 GB of storage and viewer analytics. Recording, editing, exporting and sharing to your own bucket stay free.

1. Click the Reelbird icon in the menu bar, choose **Settings…**, then **Sharing** › **Reelbird Cloud**, and choose **Sign In**.
2. Approve the code in your browser. Your account is your email address.
3. Upgrade at [watch.reelbird.app/upgrade](https://watch.reelbird.app/upgrade).

New shares then go to Reelbird's hosting, and links look like `https://watch.reelbird.app/r/<id>/`. **Share while recording**, **Update link** and **Stop sharing** work the same as with your own bucket.

- **Analytics.** Each link shows views, unique viewers, where people stopped watching (a retention curve), where they came from and their devices, in the Library and on your [account page](https://watch.reelbird.app/account). There are no cookies: a viewer is counted with a daily hash of IP address and browser, and no IP address is stored. Your own views and link-preview bots don't count.
- **What viewers see.** The video page plays in any browser with no sign-in, with a small "Made with Reelbird" footer. Link previews show the video's title and poster.
- **Cancelling.** Choose **Manage subscription** on your account page. Links you already shared keep playing after Pro ends; you can delete them from the account page or the app. To share again without Pro, switch back to your own bucket.
- **Command line.** `reelbird cloud login` signs in, `reelbird cloud status` shows your plan and usage, `reelbird cloud links` lists your hosted links with view counts, `reelbird cloud stats PROJECT` shows one link's views, retention and sources, `reelbird cloud use bucket` or `use cloud` picks where new shares go, and `reelbird cloud logout` signs out. On a machine without a Keychain, scripts and agents can set `REELBIRD_CLOUD_TOKEN`.

More on [pricing](https://reelbird.app/pricing/) and what Reelbird Pro stores on the [privacy page](https://reelbird.app/privacy/#pro).

## Command line and CI

The CLI reads the settings you saved in the app. To configure it from a terminal instead:

```sh
reelbird config share \
  --endpoint https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
  --bucket reelbird \
  --access-key <ACCESS_KEY_ID> \
  --public-base https://video.example.com \
  --test
```

It prompts for the secret access key (or reads it from stdin with `--secret-stdin`) and stores it in the Keychain. `reelbird config show` prints the current settings without the secret.

On a CI machine without a Keychain, set environment variables instead. They take precedence over saved settings:

| Variable | Value |
|---|---|
| `REELBIRD_S3_ENDPOINT` | endpoint |
| `REELBIRD_S3_BUCKET` | bucket name |
| `REELBIRD_S3_ACCESS_KEY_ID` | access key ID |
| `REELBIRD_S3_SECRET_ACCESS_KEY` | secret access key |
| `REELBIRD_S3_PUBLIC_BASE_URL` | public URL |
| `REELBIRD_S3_REGION` | optional, default `auto` |
| `REELBIRD_S3_PREFIX` | optional, default `r` |

## Other S3-compatible services

Reelbird signs requests with AWS Signature Version 4, so anything that speaks the S3 API works. You need the same seven values: endpoint, bucket, region, access key ID, secret, public URL and prefix. The bucket (or at least the prefix) must be publicly readable but **not** publicly listable.

### AWS S3

- **Endpoint:** `https://s3.<region>.amazonaws.com`, for example `https://s3.us-east-1.amazonaws.com`. **Region:** the bucket's region, for example `us-east-1`.
- **Public URL:** `https://<bucket>.s3.<region>.amazonaws.com`, or a CloudFront distribution in front of the bucket.
- **Public read:** turn off "Block all public access" for this bucket only, and add a bucket policy that allows `s3:GetObject` on `arn:aws:s3:::<bucket>/r/*` for everyone. Don't grant `s3:ListBucket` publicly.
- **Credentials:** an IAM user (or role) limited to this bucket with `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` and `s3:ListBucket`.
- **Cost:** S3 charges for egress, so every view costs money. Check current AWS pricing.

### Backblaze B2

- **Endpoint:** the S3 endpoint shown on the bucket, for example `https://s3.us-west-004.backblazeb2.com`. **Region:** the part after `s3.`, for example `us-west-004`.
- **Public URL:** `https://<bucket>.s3.<region>.backblazeb2.com`, or a CDN in front of it.
- **Public read:** set the bucket to **Public**.
- **Credentials:** create an **Application Key** that can only access this bucket, with read and write. The key ID is the access key ID and the application key is the secret.
- **Cost:** check B2's current storage and egress terms.

### MinIO (self-hosted)

- **Endpoint:** your server, for example `https://minio.example.com`. **Region:** `us-east-1` unless you configured another.
- **Public URL:** the same server plus the bucket, `https://minio.example.com/<bucket>`, behind HTTPS so links work everywhere.
- **Public read:** `mc anonymous set download <alias>/<bucket>/r`.
- **Credentials:** a user or access key with a policy limited to this bucket.

## Privacy

- **Links are unlisted, not secret.** Anyone who has a link can watch the video and forward the link. The random ID makes links impossible to guess, and R2 public URLs don't list the bucket's contents, but there's no password or login. Don't share anything through a link that you wouldn't be comfortable seeing forwarded.
- **Sharing while recording uploads as you go.** If "Share while recording" is on, segments leave your Mac during the recording. If you discard the take, Reelbird deletes everything it uploaded for it.
- **Deleting a share.** In Reelbird, open the recording, click **Copy Link** in the editor toolbar and choose **Stop sharing** (or run `reelbird unshare PROJECT`). Reelbird deletes every file under `r/<id>/` and the link stops working. You can also delete the `r/<id>/` folder in the Cloudflare dashboard (**R2 object storage** → your bucket → select the folder → **Delete**).
- **Caches and copies.** With a custom domain, Cloudflare's cache may keep serving a deleted file for a short time. Anyone who already downloaded the video keeps their copy.
- **Captions and titles** are generated on your Mac. They're uploaded only as part of a share you publish.
- **What viewers load.** The viewer page, video and captions all come from your bucket. While a share has only the live stream, browsers without built-in HLS (Chrome, Firefox) also load the hls.js player from jsDelivr, pinned to one version and integrity-checked. Once you update the link, viewers get a plain MP4 and nothing else.
- **Your keys stay on your Mac.** The secret key lives in the macOS Keychain and is only sent to your storage endpoint, as a request signature, never in plain text.
