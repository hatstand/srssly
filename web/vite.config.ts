import react from "@vitejs/plugin-react";
import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";
import { handleProxy } from "./proxy/handler";

/** Serves the feed proxy at /proxy during `vite dev` and `vite preview`. */
function feedProxy(): Plugin {
  const middleware = async (
    req: import("node:http").IncomingMessage,
    res: import("node:http").ServerResponse,
    next: () => void,
  ): Promise<void> => {
    if (!req.url?.startsWith("/proxy")) return next();
    const headers = new Headers();
    if (req.headers.origin) headers.set("Origin", req.headers.origin);
    const response = await handleProxy(new Request(`http://localhost${req.url}`, { method: req.method ?? "GET", headers }), {
      allowedOrigins: ["*"],
      userAgent: "Srssly/0.1 (feed reader, web dev; +https://github.com/hatstand/srssly)",
    });
    res.statusCode = response.status;
    response.headers.forEach((value, key) => res.setHeader(key, value));
    res.end(Buffer.from(await response.arrayBuffer()));
  };
  return {
    name: "srssly-feed-proxy",
    configureServer: (server) => void server.middlewares.use((req, res, next) => void middleware(req, res, next)),
    configurePreviewServer: (server) => void server.middlewares.use((req, res, next) => void middleware(req, res, next)),
  };
}

export default defineConfig({
  plugins: [react(), feedProxy()],
  // Allow serving over Tailscale (`tailscale serve` gives https://<host>.<tailnet>.ts.net,
  // which the app needs: crypto.subtle only exists in secure contexts).
  server: { allowedHosts: [".ts.net"] },
  preview: { allowedHosts: [".ts.net"] },
  test: {
    environment: "jsdom",
  },
});
