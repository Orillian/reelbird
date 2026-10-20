// Proves scoped upload keys work: a key for r/<id>/ can write there and nowhere else.
// Usage: bun scripts/check-temp-creds.ts
import { config } from "../src/config";
import { R2 } from "../src/r2";

const admin = new R2(config.r2);
const id = "Check" + "x".repeat(9);
const creds = admin.tempCredentials({ prefixes: [`r/${id}/`], objects: [`r/${id}`], ttlSeconds: 600 });

// A client signing with the temporary key plus the session token header.
class Temp extends R2 {
  constructor() { super({ ...config.r2, accessKeyId: creds.accessKeyId, secretAccessKey: creds.secretAccessKey }); }
  override send(method: string, key: string | null, opts: any = {}) {
    return super.send(method, key, { ...opts, headers: { ...(opts.headers ?? {}), "x-amz-security-token": creds.sessionToken } });
  }
}
const t = new Temp();
const put = async (k: string) => (await t.send("PUT", k, { body: "hi", headers: { "content-type": "text/plain" } })).status;
const results = {
  inside: await put(`r/${id}/test.txt`),
  bareKey: await put(`r/${id}`),
  otherShare: await put(`r/Other${"y".repeat(9)}/test.txt`),
  bucketRoot: await put(`root.txt`),
  listInside: (await t.send("GET", null, { query: [["list-type", "2"], ["prefix", `r/${id}/`]] })).status,
  deleteInside: (await t.send("DELETE", `r/${id}/test.txt`)).status,
};
console.log(results);
await admin.delete(`r/${id}`);
await admin.delete(`r/${id}/test.txt`);
const ok = results.inside === 200 && results.bareKey === 200 && results.otherShare === 403 && results.bucketRoot === 403 && results.deleteInside === 204;
console.log(ok ? "OK: scoped keys behave" : "UNEXPECTED");
