/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_PROXY_URL?: string;
  /** CloudKit Console → API Access → API Tokens. Enables iCloud sync. */
  readonly VITE_CLOUDKIT_API_TOKEN?: string;
  readonly VITE_CLOUDKIT_ENVIRONMENT?: "development" | "production";
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
