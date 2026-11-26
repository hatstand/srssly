import { handleProxy } from "./handler";

/** Cloudflare Worker entry point. Configure ALLOWED_ORIGINS in wrangler.toml. */
interface Env {
  ALLOWED_ORIGINS?: string;
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleProxy(request, {
      allowedOrigins: (env.ALLOWED_ORIGINS ?? "").split(",").map((s) => s.trim()).filter(Boolean),
      userAgent: "Srssly/0.1 (feed reader; +https://github.com/hatstand/srssly)",
    });
  },
};
