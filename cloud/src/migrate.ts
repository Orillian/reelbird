// Applies migrations/*.sql in order, once each. Run with `bun run migrate` (Tiffin: the release command).
import { readdir } from "node:fs/promises";
import postgres from "postgres";

export async function migrate(url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!) {
  const sql = postgres(url, { max: 1, onnotice: () => {} });
  try {
    await sql`create table if not exists schema_migrations (name text primary key, applied_at timestamptz not null default now())`;
    const done = new Set((await sql<{ name: string }[]>`select name from schema_migrations`).map((r) => r.name));
    const dir = new URL("../migrations/", import.meta.url);
    for (const file of (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort()) {
      if (done.has(file)) continue;
      const text = await Bun.file(new URL(file, dir)).text();
      await sql.begin(async (tx) => {
        await tx.unsafe(text);
        await tx`insert into schema_migrations (name) values (${file})`;
      });
      console.log(`migrated ${file}`);
    }
  } finally {
    await sql.end();
  }
}

if (import.meta.main) await migrate();
