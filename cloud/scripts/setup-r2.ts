// One-time setup of the hosted bucket: create it (private) and allow the viewer origin in CORS.
// Usage: bun scripts/setup-r2.ts
import { config } from "../src/config";
import { R2 } from "../src/r2";

const r2 = new R2(config.r2);
console.log(`bucket ${config.r2.bucket}: ${await r2.ensureBucket()}`);
const origins = [config.publicURL, ...(config.dev ? ["http://127.0.0.1:" + config.port] : [])];
await r2.setCors(origins);
console.log(`CORS allows ${origins.join(", ")}`);
