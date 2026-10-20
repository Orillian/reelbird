// Minimal R2 (S3 API) client: SigV4 header signing, presigned GETs and R2 temporary credentials.
// No SDK: the server only needs a handful of calls, and every one is easy to read here.
import { createHash, createHmac } from "node:crypto";

export type R2Config = { accountId: string; accessKeyId: string; secretAccessKey: string; bucket: string };

export type TempCredentials = {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken: string;
  expiresAt: string;
};

const sha256 = (data: string | Uint8Array) => createHash("sha256").update(data).digest("hex");
const hmac = (key: string | Buffer, data: string) => createHmac("sha256", key).update(data).digest();

/** RFC 3986 encoding, as SigV4 wants it (slashes kept in paths). */
export function uriEncode(s: string, keepSlash = false): string {
  let out = "";
  for (const b of new TextEncoder().encode(s)) {
    const c = String.fromCharCode(b);
    if (/[A-Za-z0-9\-._~]/.test(c) || (keepSlash && c === "/")) out += c;
    else out += "%" + b.toString(16).toUpperCase().padStart(2, "0");
  }
  return out;
}

function amzDate(d: Date) {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

function canonicalQuery(q: [string, string][]) {
  return q
    .map(([k, v]) => [uriEncode(k), uriEncode(v)] as const)
    .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : 1) : a[0] < b[0] ? -1 : 1))
    .map(([k, v]) => `${k}=${v}`)
    .join("&");
}

export class R2 {
  readonly host: string;
  readonly endpoint: string;

  constructor(readonly cfg: R2Config) {
    this.host = `${cfg.accountId}.r2.cloudflarestorage.com`;
    this.endpoint = `https://${this.host}`;
  }

  private signingKey(day: string) {
    return hmac(hmac(hmac(hmac("AWS4" + this.cfg.secretAccessKey, day), "auto"), "s3"), "aws4_request");
  }

  /** Path-style URI for a key in this bucket ("" = the bucket itself). */
  private path(key: string) {
    return "/" + uriEncode(this.cfg.bucket) + (key ? "/" + uriEncode(key, true) : "");
  }

  /** A signed request. `key` null targets the bucket. */
  async send(method: string, key: string | null, opts: { query?: [string, string][]; body?: Uint8Array | string; headers?: Record<string, string> } = {}) {
    const query = opts.query ?? [];
    const body = typeof opts.body === "string" ? new TextEncoder().encode(opts.body) : opts.body;
    const payloadHash = sha256(body ?? "");
    const now = new Date();
    const date = amzDate(now);
    const day = date.slice(0, 8);
    const headers: Record<string, string> = { ...(opts.headers ?? {}), host: this.host, "x-amz-date": date, "x-amz-content-sha256": payloadHash };
    const names = Object.keys(headers).map((h) => h.toLowerCase()).sort();
    const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v.trim()]));
    const canonical = [method, this.path(key ?? ""), canonicalQuery(query), names.map((n) => `${n}:${lower[n]}\n`).join(""), names.join(";"), payloadHash].join("\n");
    const scope = `${day}/auto/s3/aws4_request`;
    const toSign = ["AWS4-HMAC-SHA256", date, scope, sha256(canonical)].join("\n");
    const signature = createHmac("sha256", this.signingKey(day)).update(toSign).digest("hex");
    const { host: _host, ...sendHeaders } = lower;
    sendHeaders.authorization = `AWS4-HMAC-SHA256 Credential=${this.cfg.accessKeyId}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}`;
    const qs = canonicalQuery(query);
    return fetch(`${this.endpoint}${this.path(key ?? "")}${qs ? "?" + qs : ""}`, { method, headers: sendHeaders, body: body as BodyInit | undefined });
  }

  /** GET an object; null when missing. */
  async get(key: string): Promise<Response | null> {
    const r = await this.send("GET", key);
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`R2 GET ${key}: ${r.status} ${await r.text()}`);
    return r;
  }

  async put(key: string, body: string | Uint8Array, contentType: string) {
    const r = await this.send("PUT", key, { body, headers: { "content-type": contentType } });
    if (!r.ok) throw new Error(`R2 PUT ${key}: ${r.status} ${await r.text()}`);
  }

  async delete(key: string) {
    const r = await this.send("DELETE", key);
    if (!r.ok && r.status !== 404) throw new Error(`R2 DELETE ${key}: ${r.status}`);
  }

  /** Every object under a prefix. */
  async list(prefix: string): Promise<{ key: string; size: number }[]> {
    const out: { key: string; size: number }[] = [];
    let token: string | undefined;
    do {
      const q: [string, string][] = [["list-type", "2"], ["prefix", prefix], ["max-keys", "1000"]];
      if (token) q.push(["continuation-token", token]);
      const r = await this.send("GET", null, { query: q });
      if (!r.ok) throw new Error(`R2 LIST ${prefix}: ${r.status} ${await r.text()}`);
      const xml = await r.text();
      for (const m of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
        const key = m[1].match(/<Key>([\s\S]*?)<\/Key>/)?.[1];
        const size = Number(m[1].match(/<Size>(\d+)<\/Size>/)?.[1] ?? 0);
        if (key) out.push({ key: decodeXml(key), size });
      }
      token = xml.includes("<IsTruncated>true</IsTruncated>") ? decodeXml(xml.match(/<NextContinuationToken>([\s\S]*?)<\/NextContinuationToken>/)?.[1] ?? "") : undefined;
    } while (token);
    return out;
  }

  /** Total bytes stored under a prefix. */
  async size(prefix: string) {
    return (await this.list(prefix)).reduce((n, o) => n + o.size, 0);
  }

  /** Deletes a share: everything under "<key>/" plus the bare "<key>" object. */
  async deleteShare(key: string) {
    if (!/^r\/[1-9A-HJ-NP-Za-km-z]{14}$/.test(key)) throw new Error(`refusing to delete ${key}`);
    const objects = await this.list(key + "/");
    for (let i = 0; i < objects.length; i += 1000) {
      const batch = objects.slice(i, i + 1000);
      const xml = `<Delete><Quiet>true</Quiet>${batch.map((o) => `<Object><Key>${encodeXml(o.key)}</Key></Object>`).join("")}</Delete>`;
      const md5 = new Bun.CryptoHasher("md5").update(xml).digest("base64");
      const r = await this.send("POST", null, { query: [["delete", ""]], body: xml, headers: { "content-type": "application/xml", "content-md5": md5 } });
      if (!r.ok) throw new Error(`R2 DeleteObjects: ${r.status} ${await r.text()}`);
    }
    await this.delete(key);
  }

  /**
   * A presigned GET URL. `window` rounds the signing time down so every request within it gets the
   * same URL, which lets browsers and the CDN cache the media.
   */
  presignGet(key: string, opts: { window?: number; expires?: number; contentDisposition?: string } = {}) {
    const window = opts.window ?? 3600;
    const expires = opts.expires ?? window * 2;
    const at = new Date(Math.floor(Date.now() / 1000 / window) * window * 1000);
    const date = amzDate(at);
    const day = date.slice(0, 8);
    const scope = `${day}/auto/s3/aws4_request`;
    const query: [string, string][] = [
      ["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
      ["X-Amz-Credential", `${this.cfg.accessKeyId}/${scope}`],
      ["X-Amz-Date", date],
      ["X-Amz-Expires", String(expires)],
      ["X-Amz-SignedHeaders", "host"],
    ];
    if (opts.contentDisposition) query.push(["response-content-disposition", opts.contentDisposition]);
    const canonical = ["GET", this.path(key), canonicalQuery(query), `host:${this.host}\n`, "host", "UNSIGNED-PAYLOAD"].join("\n");
    const toSign = ["AWS4-HMAC-SHA256", date, scope, sha256(canonical)].join("\n");
    const sig = createHmac("sha256", this.signingKey(day)).update(toSign).digest("hex");
    return `${this.endpoint}${this.path(key)}?${canonicalQuery(query)}&X-Amz-Signature=${sig}`;
  }

  /**
   * R2 temporary credentials, signed locally (no Cloudflare API call): a JWT signed with the parent
   * secret. Limited to this bucket and to the given key prefixes and exact keys.
   * https://developers.cloudflare.com/r2/examples/authenticate-r2-temp-credentials/
   */
  tempCredentials(opts: { prefixes: string[]; objects?: string[]; ttlSeconds: number }): TempCredentials {
    const iat = Math.floor(Date.now() / 1000);
    const exp = iat + opts.ttlSeconds;
    const b64 = (v: object | Buffer) => (Buffer.isBuffer(v) ? v : Buffer.from(JSON.stringify(v))).toString("base64url");
    const header = b64({ alg: "HS256", typ: "JWT" });
    const payload = b64({
      bucket: this.cfg.bucket,
      scope: "object-read-write",
      paths: { prefixPaths: opts.prefixes, objectPaths: opts.objects ?? [] },
      sub: this.cfg.accountId,
      iss: this.cfg.accessKeyId,
      aud: this.host,
      iat,
      exp,
    });
    const jwt = `${header}.${payload}.${b64(hmac(this.cfg.secretAccessKey, `${header}.${payload}`))}`;
    return {
      accessKeyId: this.cfg.accessKeyId,
      secretAccessKey: sha256(jwt),
      sessionToken: Buffer.from("jwt/" + jwt).toString("base64"),
      expiresAt: new Date(exp * 1000).toISOString(),
    };
  }

  /** Creates the bucket if it doesn't exist (setup only). */
  async ensureBucket() {
    const head = await this.send("HEAD", null);
    if (head.ok) return "exists";
    const r = await this.send("PUT", null);
    if (!r.ok) throw new Error(`CreateBucket ${this.cfg.bucket}: ${r.status} ${await r.text()}`);
    return "created";
  }

  /** Lets the viewer's origin fetch media through redirects (hls.js uses fetch/XHR). */
  async setCors(origins: string[]) {
    const xml = `<CORSConfiguration><CORSRule>${origins.map((o) => `<AllowedOrigin>${encodeXml(o)}</AllowedOrigin>`).join("")}<AllowedMethod>GET</AllowedMethod><AllowedMethod>HEAD</AllowedMethod><AllowedHeader>*</AllowedHeader><ExposeHeader>Content-Length</ExposeHeader><ExposeHeader>Content-Range</ExposeHeader><MaxAgeSeconds>3600</MaxAgeSeconds></CORSRule></CORSConfiguration>`;
    const md5 = new Bun.CryptoHasher("md5").update(xml).digest("base64");
    const r = await this.send("PUT", null, { query: [["cors", ""]], body: xml, headers: { "content-type": "application/xml", "content-md5": md5 } });
    if (!r.ok) throw new Error(`PutBucketCors: ${r.status} ${await r.text()}`);
  }
}

function decodeXml(s: string) {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
}
function encodeXml(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
