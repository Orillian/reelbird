// Tells Bing, Yandex, Naver, Seznam and the other IndexNow engines which pages changed. Bing's index
// also feeds ChatGPT search, Copilot and DuckDuckGo. Google doesn't use IndexNow; use Search Console.
//
// Run it AFTER a deploy is live, since the engines fetch the key file to check ownership:
//   bun scripts/indexnow.mjs --dry                       list what would be sent, send nothing
//   bun scripts/indexnow.mjs                             every URL in the live sitemap
//   bun scripts/indexnow.mjs --url /pricing/ --url /     just these
//   bun scripts/indexnow.mjs --changed <old-dist> <new-dist>   pages whose HTML differs between two builds
//                                                        (all of them when <old-dist> doesn't exist)
//
// The key is public by design: public/<key>.txt serves it. To rotate it, rename that file and change KEY.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const SITE = "https://reelbird.app";
const KEY = "59c9d85a75bd7eb276a3cad21e935295";
const args = process.argv.slice(2);
const dry = args.includes("--dry");
const values = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));

async function text(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url} returned ${r.status}`);
  return r.text();
}

// Every page in a build, as "/path/" -> HTML.
function pages(dir) {
  const out = new Map();
  const walk = (d, rel) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) { if (!e.name.startsWith("_")) walk(join(d, e.name), `${rel}${e.name}/`); }
      else if (e.name === "index.html") out.set(`/${rel}`, readFileSync(join(d, e.name), "utf8"));
    }
  };
  walk(dir, "");
  return out;
}

let urls;
const changed = args.indexOf("--changed");
if (changed >= 0) {
  const [oldDir, newDir] = args.slice(changed + 1, changed + 3);
  const listed = new Set([...(await text(`${SITE}/sitemap.xml`)).matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]));
  const before = oldDir && existsSync(oldDir) ? pages(oldDir) : new Map();
  urls = [...pages(newDir)].filter(([path, html]) => before.get(path) !== html).map(([path]) => SITE + path).filter((u) => listed.has(u));
} else if (values("--url").length) {
  urls = values("--url").map((u) => (u.startsWith("http") ? u : SITE + u));
} else {
  urls = [...(await text(`${SITE}/sitemap.xml`)).matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
}

if (!urls.length) { console.log("indexnow: nothing changed"); process.exit(0); }
console.log(`indexnow: ${urls.length} URL${urls.length === 1 ? "" : "s"}\n  ${urls.join("\n  ")}`);
if (dry) process.exit(0);

if ((await text(`${SITE}/${KEY}.txt`)).trim() !== KEY) throw new Error(`${SITE}/${KEY}.txt doesn't hold the key. Deploy first.`);
const r = await fetch("https://api.indexnow.org/indexnow", {
  method: "POST",
  headers: { "content-type": "application/json; charset=utf-8" },
  body: JSON.stringify({ host: new URL(SITE).host, key: KEY, keyLocation: `${SITE}/${KEY}.txt`, urlList: urls }),
});
// 200 = accepted, 202 = accepted while the key is still being checked.
console.log(`indexnow: HTTP ${r.status}${r.ok ? "" : ` ${await r.text()}`}`);
if (!r.ok) process.exit(1);
