import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

const BACKEND_PORT = Number(process.env.VITE_API_PORT) || 3001;
const HTTP = `http://127.0.0.1:${BACKEND_PORT}`;
const WS = `ws://127.0.0.1:${BACKEND_PORT}`;

// Proxy /api, /ws, /healthz to backend (HTTP + WebSocket).
// Frontend code MUST use relative URLs (`fetch("/api/...")`,
// `new WebSocket("/ws/...")`); absolute `http://localhost:3001/...` URLs
// won't work because the browser is on a different host than the
// container — they go through a runtime shim that rewrites them, but
// the canonical fix is to use relative paths.
// HMR is disabled by default for sandbox previews:
//   - The user views the app inside an iframe at /api/preview/{tid}/
//     (proxied through nginx + gateway). Vite's HMR client constructs
//     a WS URL based on its server config; getting that URL to survive
//     the path-prefix proxy + iframe + WS-upgrade chain reliably across
//     all browsers is fragile (browsers drop cookies on iframe WS
//     upgrades; Starlette WS routes don't match empty paths; etc.).
//   - In this product the AGENT edits code and calls
//     ``restart_web_service``; the user doesn't edit the iframe live.
//     HMR's value (instant update on save) doesn't apply.
//   - With ``hmr: false`` Vite never opens a WS, so the console stays
//     clean and there's no proxy plumbing to maintain. If a future
//     agent flow needs HMR, set ``HMR_BASE`` env via spawn.sh and
//     re-enable here using the same ``server.hmr.path`` shape AWS S3
//     presigned URLs / Vercel preview deployments use.
export default defineConfig({
  plugins: [vue()],
  server: {
    host: "0.0.0.0",
    port: Number(process.env.PORT) || 3000,
    strictPort: true,
    hmr: false,
    proxy: {
      "/api": { target: HTTP, changeOrigin: true, ws: true },
      "/ws": { target: WS, ws: true, changeOrigin: true },
      "/healthz": HTTP,
    },
  },
});
