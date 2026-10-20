import postgres from "postgres";
import { config } from "./config";

// prepare: false because production goes through Tiffin's transaction pooler (see Tiffin docs, data.md).
const g = globalThis as { __sql?: postgres.Sql };
export const sql = (g.__sql ??= postgres(config.databaseURL, { prepare: false, max: Number(process.env.DATABASE_POOL_MAX) || 5, idle_timeout: 20, onnotice: () => {} }));
