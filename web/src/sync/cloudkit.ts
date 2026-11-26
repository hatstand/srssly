import type { SaveResult, SyncBackend, SyncErrorCode, ZoneChanges } from "./backend";
import { SyncError } from "./backend";
import type { CKJS, CKJSContainer, CKJSError, CKJSRecord, CKJSResponse } from "./cloudkitjs";
import { type CKRecord, type FieldValue, containerIdentifier, zoneName } from "./records";

export interface CloudKitConfig {
  apiToken: string;
  environment: "development" | "production";
}

/** Sync settings from the build environment (web/.env.local), if any. */
export function cloudKitConfig(): CloudKitConfig | undefined {
  const apiToken = import.meta.env.VITE_CLOUDKIT_API_TOKEN;
  if (!apiToken) return undefined;
  return { apiToken, environment: import.meta.env.VITE_CLOUDKIT_ENVIRONMENT === "production" ? "production" : "development" };
}

const scriptURL = "https://cdn.apple-cloudkit.com/ck/2/cloudkit.js";
let loading: Promise<CKJS> | undefined;

/** Loads CloudKit JS on demand, after the app has rendered. */
export function loadCloudKit(): Promise<CKJS> {
  loading ??= new Promise<CKJS>((resolve, reject) => {
    if (window.CloudKit) return resolve(window.CloudKit);
    const script = document.createElement("script");
    script.src = scriptURL;
    script.async = true;
    script.onload = () => (window.CloudKit ? resolve(window.CloudKit) : reject(new Error("CloudKit JS did not load")));
    script.onerror = () => reject(new Error("Couldn't load CloudKit JS"));
    document.head.append(script);
  });
  return loading;
}

export const signInButtonID = "apple-sign-in-button";
export const signOutButtonID = "apple-sign-out-button";

export async function configureCloudKit(config: CloudKitConfig): Promise<CKJSContainer> {
  const CloudKit = await loadCloudKit();
  CloudKit.configure({
    containers: [
      {
        containerIdentifier,
        apiTokenAuth: {
          apiToken: config.apiToken,
          persist: true,
          signInButton: { id: signInButtonID, theme: "black" },
          signOutButton: { id: signOutButtonID, theme: "black" },
        },
        environment: config.environment,
      },
    ],
  });
  return CloudKit.getDefaultContainer();
}

const knownCodes: readonly SyncErrorCode[] = [
  "AUTHENTICATION_REQUIRED", "ACCESS_DENIED", "ZONE_NOT_FOUND", "CHANGE_TOKEN_EXPIRED", "CONFLICT", "NOT_FOUND",
];

function codeOf(e: CKJSError): SyncErrorCode {
  const code = e.ckErrorCode ?? e.serverErrorCode ?? "";
  if (code === "SYNC_TOKEN_EXPIRED") return "CHANGE_TOKEN_EXPIRED";
  if (code === "UNKNOWN_ITEM") return "NOT_FOUND";
  return (knownCodes as readonly string[]).includes(code) ? (code as SyncErrorCode) : "OTHER";
}

function toSyncError(e: unknown): SyncError {
  if (e instanceof SyncError) return e;
  if (typeof e === "object" && e !== null) {
    const ck = e as CKJSError;
    return new SyncError(codeOf(ck), ck.reason ?? ck.message ?? ck.ckErrorCode ?? "CloudKit error");
  }
  return new SyncError("OTHER", String(e));
}

async function call<T extends CKJSResponse>(p: Promise<T>): Promise<T> {
  let res: T;
  try {
    res = await p;
  } catch (e) {
    throw toSyncError(e);
  }
  return res;
}

function fromCK(r: CKJSRecord): CKRecord {
  const fields: CKRecord["fields"] = {};
  for (const [k, v] of Object.entries(r.fields ?? {})) {
    const value = v?.value;
    fields[k] = { value: typeof value === "string" || typeof value === "number" ? value : null };
  }
  return {
    recordName: r.recordName,
    recordType: r.recordType,
    fields,
    ...(r.recordChangeTag ? { recordChangeTag: r.recordChangeTag } : {}),
    ...(r.deleted ? { deleted: true } : {}),
  };
}

function toCK(r: CKRecord): CKJSRecord {
  const fields: Record<string, { value: FieldValue; type?: string }> = {};
  for (const [k, v] of Object.entries(r.fields)) if (v) fields[k] = v.type ? { value: v.value, type: v.type } : { value: v.value };
  return {
    recordName: r.recordName,
    recordType: r.recordType,
    zoneID: { zoneName },
    fields,
    ...(r.recordChangeTag ? { recordChangeTag: r.recordChangeTag } : {}),
  };
}

/** The sync backend on CloudKit JS: the user's private database, zone `Srssly`. */
export function cloudKitBackend(container: CKJSContainer): SyncBackend {
  const db = container.privateCloudDatabase;
  const zoneID = { zoneName };
  const firstError = (res: CKJSResponse): void => {
    const e = res.errors?.[0];
    if (res.hasErrors && e) throw toSyncError(e);
  };
  return {
    async fetchChanges(syncToken): Promise<ZoneChanges> {
      const res = await call(db.fetchRecordZoneChanges({ zoneID, ...(syncToken ? { syncToken } : {}) }));
      firstError(res);
      const zone = res.zones?.[0];
      return {
        records: (zone?.records ?? []).map(fromCK),
        deleted: [],
        syncToken: zone?.syncToken,
        moreComing: zone?.moreComing ?? false,
      };
    },
    async save(records): Promise<SaveResult[]> {
      const res = await call(db.saveRecords(records.map(toCK), { zoneID, atomic: false }));
      const saved = new Map((res.records ?? []).map((r) => [r.recordName, fromCK(r)]));
      const failed = new Map((res.errors ?? []).map((e) => [e.recordName ?? "", e]));
      return records.map((r): SaveResult => {
        const ok = saved.get(r.recordName);
        if (ok) return { recordName: r.recordName, ok: true, record: ok };
        const e = failed.get(r.recordName);
        return { recordName: r.recordName, ok: false, code: e ? codeOf(e) : "OTHER", message: e?.reason ?? "not saved" };
      });
    },
    async delete(recordNames): Promise<void> {
      const res = await call(db.deleteRecords(recordNames, { zoneID, atomic: false }));
      // Already gone is fine.
      const e = res.errors?.find((x) => codeOf(x) !== "NOT_FOUND");
      if (e) throw toSyncError(e);
    },
    async lookup(recordNames): Promise<CKRecord[]> {
      const res = await call(db.fetchRecords(recordNames, { zoneID }));
      return (res.records ?? []).map(fromCK);
    },
    async createZone(): Promise<void> {
      firstError(await call(db.saveRecordZones([zoneID])));
    },
  };
}
