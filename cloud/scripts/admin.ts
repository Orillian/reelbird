// Operator tasks, run where DATABASE_URL and R2_* point at the service (e.g. `tiffin run` on the box):
//   bun scripts/admin.ts takedown <share id>       remove a reported link and its files now
//   bun scripts/admin.ts delete-account <email>    delete an account on request: links, files, sign-ins
// Stripe isn't touched: cancel a subscription in the Stripe Dashboard first.
import { sql } from "../src/db";
import { takeDown } from "../src/shares";

const [cmd, arg] = process.argv.slice(2);
if (cmd === "takedown" && arg) {
  console.log((await takeDown(arg)) ? `Took down ${arg}.` : `No link ${arg}.`);
} else if (cmd === "delete-account" && arg) {
  const [u] = await sql<{ id: string }[]>`select id from users where lower(email) = ${arg.toLowerCase()}`;
  if (!u) {
    console.log(`No account for ${arg}.`);
  } else {
    const shares = await sql<{ id: string }[]>`select id from shares where user_id = ${u.id}`;
    for (const s of shares) await takeDown(s.id);
    await sql`delete from users where id = ${u.id}`; // sessions and shares go with it
    await sql`delete from login_links where lower(email) = ${arg.toLowerCase()}`;
    await sql`delete from stripe_customers where lower(email) = ${arg.toLowerCase()}`;
    console.log(`Deleted ${arg} and ${shares.length} link(s).`);
  }
} else {
  console.log("Usage: bun scripts/admin.ts takedown <share id> | delete-account <email>");
}
await sql.end();
