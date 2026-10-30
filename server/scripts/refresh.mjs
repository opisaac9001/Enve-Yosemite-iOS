import { loadEnv } from "../src/lib/env.js";
import { refreshAll } from "../src/cache.js";

loadEnv();
await refreshAll(console);
