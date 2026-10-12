# Sharing setup

Reelbird has no server. Share links point at a storage bucket that you own. Reelbird uploads a small viewer page and the video to it, and anyone with the link can watch in a browser. Nothing goes through us.

Cloudflare R2 is the recommended host because it doesn't charge for downloads (egress), so a popular video costs the same as an unwatched one. Any S3-compatible service works too (see [Other S3-compatible services](#other-s3-compatible-services)).

Setup takes about ten minutes, once.

## What Reelbird puts in the bucket

Each share gets a random short ID and lives under one prefix (default `r/`):

```
r/<id>/index.html     the viewer page (the link you send)
r/<id>/meta.json      title, duration, chapters
r/<id>/hls/           the stream uploaded while you record (playlist + 2-second segments)
r/<id>/video.mp4      the polished version, after you edit and choose Update link
r/<id>/poster.jpg     preview image for link unfurls
r/<id>/captions.vtt   captions, if you made them
```

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

Open Reelbird → **Settings** → **Sharing** and fill in:

| Field | Value |
|---|---|
| Endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |
| Bucket | `reelbird` (your bucket name) |
| Region | `auto` |
| Access key ID | from step 3 |
| Secret access key | from step 3 |
| Public URL | your custom domain or `https://pub-….r2.dev` |
| Prefix | `r` (default) |

Select **Test connection**. Reelbird checks that it can write to the bucket with these keys and that the public URL serves what it wrote.

The secret key is stored in your macOS Keychain. The other fields are stored in Reelbird's preferences.

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

In practice storage is the only number that matters. A 1080p share uses roughly 30 to 40 MB per minute, so the free 10 GB holds about 4 to 5 hours of shared video. Past that, 100 GB costs about $1.35 a month. Uploads while recording are one write per 2-second segment (about 30 per minute), so a month would need around 550 hours of recording to use the free million. Delete old shares to keep storage down.

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
- **Deleting a share.** In Reelbird, open the recording and choose **Stop sharing**. Reelbird deletes every file under `r/<id>/` and the link stops working. You can also delete the `r/<id>/` folder in the Cloudflare dashboard (**R2 object storage** → your bucket → select the folder → **Delete**).
- **Caches and copies.** With a custom domain, Cloudflare's cache may keep serving a deleted file for a short time. Anyone who already downloaded the video keeps their copy.
- **Captions and titles** are generated on your Mac. They're uploaded only as part of a share you publish.
- **Your keys stay on your Mac.** The secret key lives in the macOS Keychain and is only sent to your storage endpoint, as a request signature, never in plain text.
