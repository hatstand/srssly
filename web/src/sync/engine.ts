import { parseUUID, type UUID } from "../core/uuid";
import type { SyncMeta } from "../store/db";
import type { Library, LocalChange } from "../store/library";
import type { ArticleState } from "../store/model";
import { type SyncBackend, SyncError } from "./backend";
import {
  type ArticleStateFields,
  type CKRecord,
  type SubscriptionFields,
  mergeFields,
  modifiedAtOf,
  remoteWins,
  sameFields,
  stateFields,
  stateFieldsFromRecord,
  stateRecord,
  subscriptionFields,
  subscriptionFieldsFromRecord,
  subscriptionRecord,
  withSubscriptionFields,
} from "./records";

export type SyncStatus =
  | { state: "idle"; lastSync?: number }
  | { state: "syncing" }
  | { state: "error"; code: SyncError["code"]; message: string };

const batchSize = 200;
const pushDelayMs = 1500;

/**
 * Syncs subscriptions and read/starred state with CloudKit, the same way
 * CloudSync does on iOS: each record keeps the server's fields as last seen
 * (the base); a record is dirty while its fields differ from the base;
 * fetched changes merge field by field against that base.
 */
export class SyncEngine {
  private readonly meta = new Map<string, SyncMeta>();
  private pendingDeletes = new Set<string>();
  private syncToken: string | undefined;
  private running: Promise<void> | undefined;
  private again = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private unsubscribe: (() => void) | undefined;
  status: SyncStatus = { state: "idle" };
  private readonly statusListeners = new Set<() => void>();
  private readonly lib: Library;
  private readonly backend: SyncBackend;
  private readonly now: () => number;

  constructor(lib: Library, backend: SyncBackend, now: () => number = Date.now) {
    this.lib = lib;
    this.backend = backend;
    this.now = now;
  }

  onStatus(l: () => void): () => void {
    this.statusListeners.add(l);
    return () => this.statusListeners.delete(l);
  }

  private setStatus(s: SyncStatus): void {
    this.status = s;
    for (const l of this.statusListeners) l();
  }

  async start(): Promise<void> {
    const db = await this.lib.database();
    for (const m of await db.getAll("syncMeta")) this.meta.set(m.recordName, m);
    const token = await db.get("syncState", "syncToken");
    this.syncToken = typeof token === "string" ? token : undefined;
    const deletes = await db.get("syncState", "pendingDeletes");
    this.pendingDeletes = new Set(Array.isArray(deletes) ? deletes.filter((x): x is string => typeof x === "string") : []);
    this.unsubscribe = this.lib.onLocalChange((c) => void this.localChange(c));
    await this.sync();
  }

  stop(): void {
    this.unsubscribe?.();
    if (this.timer) clearTimeout(this.timer);
  }

  private async localChange(c: LocalChange): Promise<void> {
    if (c.kind === "subscriptionDeleted") {
      const names = [c.id, ...[...this.meta.keys()].filter((k) => k.startsWith(`${c.id}:`))];
      for (const n of names) if (this.meta.has(n)) this.pendingDeletes.add(n);
      await (await this.lib.database()).put("syncState", [...this.pendingDeletes], "pendingDeletes");
    }
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.sync(), pushDelayMs);
  }

  /** Fetches then sends changes. Calls during a run queue one more run. */
  sync(): Promise<void> {
    if (this.running) {
      this.again = true;
      return this.running;
    }
    this.running = (async () => {
      do {
        this.again = false;
        this.setStatus({ state: "syncing" });
        try {
          await this.fetch();
          await this.push();
          this.setStatus({ state: "idle", lastSync: this.now() });
        } catch (e) {
          const err = e instanceof SyncError ? e : new SyncError("OTHER", e instanceof Error ? e.message : String(e));
          this.setStatus({ state: "error", code: err.code, message: err.message });
          break;
        }
      } while (this.again);
    })().finally(() => (this.running = undefined));
    return this.running;
  }

  // MARK: Fetch

  private async fetch(): Promise<void> {
    for (let more = true; more; ) {
      let changes;
      try {
        changes = await this.backend.fetchChanges(this.syncToken);
      } catch (e) {
        if (e instanceof SyncError && e.code === "ZONE_NOT_FOUND") {
          // First device, or the zone was reset: create it and upload everything.
          await this.backend.createZone();
          await this.forgetServerState();
          return;
        }
        if (e instanceof SyncError && e.code === "CHANGE_TOKEN_EXPIRED") {
          await this.saveToken(undefined);
          continue;
        }
        throw e;
      }
      await this.apply(changes.records, changes.deleted);
      await this.saveToken(changes.syncToken);
      more = changes.moreComing;
    }
  }

  private async forgetServerState(): Promise<void> {
    const db = await this.lib.database();
    await db.clear("syncMeta");
    this.meta.clear();
    this.pendingDeletes.clear();
    await db.put("syncState", [], "pendingDeletes");
    await this.saveToken(undefined);
  }

  private async saveToken(token: string | undefined): Promise<void> {
    this.syncToken = token;
    const db = await this.lib.database();
    if (token) await db.put("syncState", token, "syncToken");
    else await db.delete("syncState", "syncToken");
  }

  /** Merges fetched records into the library. */
  async apply(records: CKRecord[], deleted: string[]): Promise<void> {
    const metas: SyncMeta[] = [];
    const states: ArticleState[] = [];
    for (const r of records) {
      if (r.deleted) {
        deleted.push(r.recordName);
        continue;
      }
      if (r.recordType === "Subscription") {
        const m = await this.mergeSubscription(r);
        if (m) metas.push(m);
      } else if (r.recordType === "ArticleState") {
        const merged = this.mergeState(r);
        states.push(merged.state);
        metas.push(merged.meta);
      }
    }
    await this.lib.applyRemoteStates(states);
    for (const name of deleted) {
      this.pendingDeletes.delete(name);
      if (name.includes(":")) await this.lib.removeRemoteState(name);
      else {
        const id = parseUUID(name);
        if (id) await this.lib.removeSubscription(id, false);
      }
    }
    const db = await this.lib.database();
    const tx = db.transaction("syncMeta", "readwrite");
    await Promise.all([
      ...metas.map((m) => tx.store.put(m)),
      ...deleted.map((n) => tx.store.delete(n)),
      tx.done,
    ]);
    for (const m of metas) this.meta.set(m.recordName, m);
    for (const n of deleted) this.meta.delete(n);
  }

  private base<T>(name: string): T | undefined {
    const raw = this.meta.get(name)?.base;
    return raw ? (JSON.parse(raw) as T) : undefined;
  }

  private metaFor(r: CKRecord, fields: object): SyncMeta {
    return {
      recordName: r.recordName,
      ...(r.recordChangeTag ? { recordChangeTag: r.recordChangeTag } : {}),
      base: JSON.stringify(fields),
    };
  }

  private async mergeSubscription(r: CKRecord): Promise<SyncMeta | undefined> {
    const remote = subscriptionFieldsFromRecord(r);
    if (!remote) return undefined;
    const remoteModified = modifiedAtOf(r);
    const local = this.lib.subscriptions.get(r.recordName as UUID);
    let merged = remote;
    let modifiedAt = remoteModified ?? this.now();
    if (local) {
      const localFields = subscriptionFields(local);
      const base = this.base<SubscriptionFields>(r.recordName);
      if (!sameFields(base, localFields)) {
        merged = mergeFields(base, localFields, remote, !remoteWins(local.modifiedAt, remoteModified));
      }
      modifiedAt = Math.max(local.modifiedAt, remoteModified ?? 0);
    }
    const sub = withSubscriptionFields(r.recordName, merged, modifiedAt, local);
    if (!sub) return undefined;
    await this.lib.applyRemoteSubscription(sub);
    return this.metaFor(r, remote);
  }

  private mergeState(r: CKRecord): { state: ArticleState; meta: SyncMeta } {
    const remote = stateFieldsFromRecord(r);
    const remoteModified = modifiedAtOf(r);
    const local = this.lib.states.get(r.recordName);
    let merged = remote;
    let modifiedAt = remoteModified ?? this.now();
    if (local) {
      const localFields = stateFields(local);
      const base = this.base<ArticleStateFields>(r.recordName);
      if (!sameFields(base, localFields)) {
        merged = mergeFields(base, localFields, remote, !remoteWins(local.modifiedAt, remoteModified));
      }
      modifiedAt = Math.max(local.modifiedAt, remoteModified ?? 0);
    }
    const articleKey = typeof r.fields["articleKey"]?.value === "string" ? r.fields["articleKey"].value : r.recordName;
    return { state: { articleKey, ...merged, modifiedAt }, meta: this.metaFor(r, remote) };
  }

  // MARK: Push

  /** Local records whose fields differ from what the server last had. */
  dirtyRecords(): CKRecord[] {
    const out: CKRecord[] = [];
    for (const s of this.lib.subscriptions.values()) {
      if (!sameFields(this.base<SubscriptionFields>(s.id), subscriptionFields(s))) {
        out.push(subscriptionRecord(s, this.meta.get(s.id)?.recordChangeTag));
      }
    }
    for (const s of this.lib.states.values()) {
      if (!sameFields(this.base<ArticleStateFields>(s.articleKey), stateFields(s))) {
        out.push(stateRecord(s, this.meta.get(s.articleKey)?.recordChangeTag));
      }
    }
    return out;
  }

  private async push(): Promise<void> {
    if (this.pendingDeletes.size > 0) {
      const names = [...this.pendingDeletes];
      for (let i = 0; i < names.length; i += batchSize) await this.backend.delete(names.slice(i, i + batchSize));
      const db = await this.lib.database();
      for (const n of names) {
        this.meta.delete(n);
        await db.delete("syncMeta", n);
      }
      this.pendingDeletes.clear();
      await db.put("syncState", [], "pendingDeletes");
    }

    const dirty = this.dirtyRecords();
    for (let i = 0; i < dirty.length; i += batchSize) {
      const batch = dirty.slice(i, i + batchSize);
      const sent = new Map(batch.map((r) => [r.recordName, r]));
      const results = await this.backend.save(batch);
      const saved: CKRecord[] = [];
      const conflicts: string[] = [];
      for (const r of results) {
        // The server now holds exactly what we sent; keep its new change tag.
        if (r.ok) saved.push({ ...(sent.get(r.recordName) ?? r.record), ...(r.record.recordChangeTag ? { recordChangeTag: r.record.recordChangeTag } : {}) });
        else if (r.code === "CONFLICT") conflicts.push(r.recordName);
        else throw new SyncError(r.code, `${r.recordName}: ${r.message}`);
      }
      await this.recordSaved(saved);
      if (conflicts.length > 0) {
        // Someone else saved first: merge their copy now and send ours next run.
        await this.apply(await this.backend.lookup(conflicts), []);
        this.again = true;
      }
    }
  }

  private async recordSaved(records: CKRecord[]): Promise<void> {
    const metas = records.map((r) =>
      this.metaFor(r, r.recordType === "Subscription" ? subscriptionFieldsFromRecord(r) ?? {} : stateFieldsFromRecord(r)),
    );
    const db = await this.lib.database();
    const tx = db.transaction("syncMeta", "readwrite");
    await Promise.all([...metas.map((m) => tx.store.put(m)), tx.done]);
    for (const m of metas) this.meta.set(m.recordName, m);
  }
}
