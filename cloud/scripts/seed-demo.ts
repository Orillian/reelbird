// Demo account for screenshots and design work: demo@example.com on Pro, with a few links and a
// month of plausible views. Development databases only. Run from cloud/: bun scripts/seed-demo.ts
import { randomUUID } from "node:crypto";
import { config } from "../src/config";
import { sql } from "../src/db";

if (!config.dev || !/127\.0\.0\.1|localhost/.test(process.env.DATABASE_URL ?? "")) {
  console.error("seed-demo only runs against a local development database (DEV=1).");
  process.exit(1);
}

const EMAIL = "demo@example.com";
const LINKS = [
  { id: "DemoQ3Roadmap1", title: "Q3 roadmap walkthrough", duration: 312, views: 64, bytes: 182e6, daysAgo: 21 },
  { id: "DemoBugRepro22", title: "Checkout bug: steps to reproduce", duration: 94, views: 23, bytes: 41e6, daysAgo: 9 },
  { id: "DemoNewDesign3", title: "Onboarding for new designers", duration: 618, views: 41, bytes: 356e6, daysAgo: 16 },
  { id: "DemoPRReview44", title: "PR #482 review notes", duration: 186, views: 7, bytes: 77e6, daysAgo: 2 },
];
const SOURCES = [null, null, null, "slack.com", "slack.com", "mail.google.com", "linear.app", "github.com", "notion.so"];
const DEVICES: [string, string][] = [["Desktop", "Chrome"], ["Desktop", "Chrome"], ["Desktop", "Safari"], ["Desktop", "Firefox"], ["Mobile", "Safari"], ["Desktop", "Edge"]];
const COUNTRIES = ["US", "US", "US", "GB", "DE", "CA", "IN", "NL"];

let seed = 7;
const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const pick = <T>(a: T[]) => a[Math.floor(rand() * a.length)]!;

const [user] = await sql<{ id: string }[]>`
  insert into users (email, plan) values (${EMAIL}, 'pro')
  on conflict (email) do update set plan = 'pro' returning id`;
await sql`delete from shares where user_id = ${user!.id}`;

for (const l of LINKS) {
  const created = new Date(Date.now() - l.daysAgo * 86_400_000);
  await sql`insert into shares (id, user_id, title, bytes, created_at, touched_at) values (${l.id}, ${user!.id}, ${l.title}, ${l.bytes}, ${created}, ${created})`;
  const chunks = Math.ceil(l.duration / 2);
  for (let v = 0; v < l.views; v++) {
    // Most viewers stay for the first minute, some skim, a third finish.
    const finish = rand() < 0.36;
    const stop = finish ? 1 : Math.min(1, Math.max(0.04, rand() ** 1.6 * 1.1));
    const bits = new Uint8Array(Math.ceil(chunks / 8));
    let seen = 0;
    for (let c = 0; c < chunks; c++) {
      if (c / chunks <= stop) { bits[c >> 3]! |= 1 << (c & 7); seen++; }
    }
    const age = Math.min(l.daysAgo, Math.floor(rand() ** 2.2 * (l.daysAgo + 1)));
    const at = new Date(Date.now() - age * 86_400_000 - rand() * 36e6);
    const [device, browser] = pick(DEVICES);
    await sql`insert into views (id, share_id, viewer, started_at, last_at, rev, duration, max_pos, watched_seconds, watched, completed, referrer, country, device, browser)
              values (${randomUUID()}, ${l.id}, ${"demo" + Math.floor(rand() * l.views * 0.8)}, ${at}, ${at}, 0, ${l.duration}, ${stop * l.duration},
                      ${seen * 2}, ${Buffer.from(bits)}, ${finish}, ${pick(SOURCES)}, ${pick(COUNTRIES)}, ${device}, ${browser})`;
  }
  await sql`insert into opens (share_id, day, n) values (${l.id}, current_date, ${Math.round(l.views * 1.3)})`;
}
console.log(`Seeded ${EMAIL} with ${LINKS.length} links. Sign in at ${config.publicURL}/login with that address.`);
await sql.end();
