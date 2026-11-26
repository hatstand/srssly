import type { CKRecord } from "./records";

/** Errors sync knows how to react to (CloudKit's `ckErrorCode`s). */
export type SyncErrorCode =
  | "AUTHENTICATION_REQUIRED"
  | "ACCESS_DENIED"
  | "ZONE_NOT_FOUND"
  | "CHANGE_TOKEN_EXPIRED"
  | "CONFLICT"
  | "NOT_FOUND"
  | "OTHER";

export class SyncError extends Error {
  readonly code: SyncErrorCode;
  constructor(code: SyncErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

export interface ZoneChanges {
  records: CKRecord[];
  /** Record names deleted on the server. */
  deleted: string[];
  syncToken: string | undefined;
  moreComing: boolean;
}

export type SaveResult =
  | { recordName: string; ok: true; record: CKRecord }
  | { recordName: string; ok: false; code: SyncErrorCode; message: string };

/** The few CloudKit operations sync needs, so the engine can be tested with a fake. */
export interface SyncBackend {
  fetchChanges(syncToken: string | undefined): Promise<ZoneChanges>;
  /** Saves records non-atomically and reports each one. */
  save(records: CKRecord[]): Promise<SaveResult[]>;
  delete(recordNames: string[]): Promise<void>;
  lookup(recordNames: string[]): Promise<CKRecord[]>;
  createZone(): Promise<void>;
}
