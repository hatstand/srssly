import type { Library } from "../store/library";
import type { CKJSContainer } from "./cloudkitjs";
import { type CloudKitConfig, cloudKitBackend, configureCloudKit } from "./cloudkit";
import { SyncEngine, type SyncStatus } from "./engine";

export type SyncState =
  | { kind: "unconfigured" }
  | { kind: "loading" }
  | { kind: "signedOut" }
  | { kind: "signedIn"; status: SyncStatus }
  | { kind: "failed"; message: string };

const pullEveryMs = 5 * 60_000;

/** Signs in with CloudKit JS and runs a SyncEngine while signed in. */
export class SyncController {
  state: SyncState;
  private engine: SyncEngine | undefined;
  private container: CKJSContainer | undefined;
  private timer: ReturnType<typeof setInterval> | undefined;
  private started = false;
  private readonly listeners = new Set<() => void>();
  private readonly lib: Library;
  private readonly config: CloudKitConfig | undefined;

  constructor(lib: Library, config: CloudKitConfig | undefined) {
    this.lib = lib;
    this.config = config;
    this.state = config ? { kind: "loading" } : { kind: "unconfigured" };
  }

  subscribe = (l: () => void): (() => void) => {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  };

  getState = (): SyncState => this.state;

  private set(state: SyncState): void {
    this.state = state;
    for (const l of this.listeners) l();
  }

  /** Call once the sign-in button's element is in the page. */
  async start(): Promise<void> {
    if (!this.config || this.started) return;
    this.started = true;
    try {
      this.container = await configureCloudKit(this.config);
      const user = await this.container.setUpAuth();
      if (user) await this.signedIn();
      else this.waitForSignIn();
    } catch (e) {
      this.set({ kind: "failed", message: e instanceof Error ? e.message : String(e) });
    }
  }

  syncNow(): void {
    void this.engine?.sync();
  }

  private waitForSignIn(): void {
    this.set({ kind: "signedOut" });
    void this.container?.whenUserSignsIn().then(() => this.signedIn());
  }

  private async signedIn(): Promise<void> {
    if (!this.container) return;
    await this.lib.database();
    const engine = new SyncEngine(this.lib, cloudKitBackend(this.container));
    this.engine = engine;
    engine.onStatus(() => this.set({ kind: "signedIn", status: engine.status }));
    this.set({ kind: "signedIn", status: engine.status });
    void this.container.whenUserSignsOut().then(() => {
      engine.stop();
      this.engine = undefined;
      if (this.timer) clearInterval(this.timer);
      this.waitForSignIn();
    });
    this.timer = setInterval(() => void engine.sync(), pullEveryMs);
    window.addEventListener("focus", () => void this.engine?.sync());
    await engine.start();
  }
}

/** A sentence for a sync error, especially the ones people can fix. */
export function describeSyncError(code: string, message: string): string {
  switch (code) {
    case "ACCESS_DENIED":
      return "iCloud refused web access to your data. Advanced Data Protection can cause this: try turning on Access iCloud Data on the Web (Settings → your name → iCloud) and signing in again.";
    case "AUTHENTICATION_REQUIRED":
      return "Sign in to iCloud again to sync.";
    default:
      return `Sync failed: ${message}`;
  }
}
