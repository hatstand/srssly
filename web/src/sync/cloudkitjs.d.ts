/**
 * The small part of Apple's CloudKit JS (https://cdn.apple-cloudkit.com/ck/2/cloudkit.js)
 * that Srssly uses. Apple ships no TypeScript types; these follow the
 * CloudKit JS reference.
 */
export interface CKJSZoneID {
  zoneName: string;
  ownerRecordName?: string;
}

export interface CKJSRecord {
  recordName: string;
  recordType: string;
  recordChangeTag?: string;
  deleted?: boolean;
  zoneID?: CKJSZoneID;
  fields?: Record<string, { value: unknown; type?: string } | undefined>;
}

export interface CKJSError {
  ckErrorCode?: string;
  serverErrorCode?: string;
  reason?: string;
  recordName?: string;
  message?: string;
}

export interface CKJSResponse {
  hasErrors?: boolean;
  errors?: CKJSError[];
  records?: CKJSRecord[];
}

export interface CKJSZoneChangesResponse extends CKJSResponse {
  zones?: { zoneID: CKJSZoneID; records?: CKJSRecord[]; syncToken?: string; moreComing?: boolean }[];
}

export interface CKJSDatabase {
  fetchRecordZoneChanges(
    request: { zoneID: CKJSZoneID; syncToken?: string; resultsLimit?: number },
  ): Promise<CKJSZoneChangesResponse>;
  saveRecords(records: CKJSRecord[], options: { zoneID: CKJSZoneID; atomic?: boolean }): Promise<CKJSResponse>;
  deleteRecords(recordNames: string[], options: { zoneID: CKJSZoneID; atomic?: boolean }): Promise<CKJSResponse>;
  fetchRecords(recordNames: string[], options: { zoneID: CKJSZoneID }): Promise<CKJSResponse>;
  saveRecordZones(zones: CKJSZoneID[]): Promise<CKJSResponse>;
}

export interface CKJSUserIdentity {
  userRecordName?: string;
  nameComponents?: { givenName?: string; familyName?: string };
}

export interface CKJSContainer {
  privateCloudDatabase: CKJSDatabase;
  setUpAuth(): Promise<CKJSUserIdentity | null>;
  whenUserSignsIn(): Promise<CKJSUserIdentity>;
  whenUserSignsOut(): Promise<void>;
}

export interface CKJS {
  configure(config: {
    containers: {
      containerIdentifier: string;
      apiTokenAuth: {
        apiToken: string;
        persist: boolean;
        signInButton?: { id: string; theme?: string };
        signOutButton?: { id: string; theme?: string };
      };
      environment: "development" | "production";
    }[];
  }): void;
  getDefaultContainer(): CKJSContainer;
}

declare global {
  interface Window {
    CloudKit?: CKJS;
  }
}
