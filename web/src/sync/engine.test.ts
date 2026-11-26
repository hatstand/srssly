import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { openSrsslyDB } from "../store/db";
import { Library } from "../store/library";
import { type SaveResult, type SyncBackend, SyncError, type ZoneChanges } from "./backend";
import { SyncEngine } from "./engine";
import { type CKRecord, mergeFields } from "./records";

/** An in-memory CloudKit zone with change tags and a change log. */
class FakeServer {
  zone = true;
  records = new Map<string, CKRecord>();
  log: { name: string; seq: number }[] = [];
  seq = 0;
  tag = 0;

  backend(): SyncBackend & { calls: string[] } {
    const calls: string[] = [];
    return {
      calls,
      fetchChanges: async (token): Promise<ZoneChanges> => {
        calls.push("fetch");
        if (!this.zone) throw new SyncError("ZONE_NOT_FOUND", "no zone");
        const since = Number(token ?? 0);
        const names = [...new Set(this.log.filter((e) => e.seq > since).map((e) => e.name))];
        const records = names.map((n) => this.records.get(n) ?? { recordName: n, recordType: "", fields: {}, deleted: true });
        return { records: structuredClone(records), deleted: [], syncToken: String(this.seq), moreComing: false };
      },
      save: async (records): Promise<SaveResult[]> => {
        calls.push(`save ${records.length}`);
        return records.map((r) => {
          const current = this.records.get(r.recordName);
          if (current && current.recordChangeTag !== r.recordChangeTag) {
            return { recordName: r.recordName, ok: false, code: "CONFLICT", message: "conflict" };
          }
          const saved = { ...structuredClone(r), recordChangeTag: `t${++this.tag}` };
          this.records.set(r.recordName, saved);
          this.log.push({ name: r.recordName, seq: ++this.seq });
          return { recordName: r.recordName, ok: true, record: structuredClone(saved) };
        });
      },
      delete: async (names) => {
        for (const n of names) {
          this.records.delete(n);
          this.log.push({ name: n, seq: ++this.seq });
        }
      },
      lookup: async (names) => names.flatMap((n) => (this.records.has(n) ? [structuredClone(this.records.get(n)!)] : [])),
      createZone: async () => {
        calls.push("createZone");
        this.zone = true;
      },
    };
  }
}

let n = 0;
async function device(server: FakeServer, clock: { t: number }) {
  const lib = new Library(await openSrsslyDB(`sync-${n++}`), undefined, () => clock.t);
  await lib.load();
  const engine = new SyncEngine(lib, server.backend(), () => clock.t);
  await engine.start();
  return { lib, engine };
}

const feed = { title: "xkcd", feedURL: "https://xkcd.com/rss.xml" };

describe("SyncEngine", () => {
  it("sends subscriptions and read state from one device to another", async () => {
    const server = new FakeServer();
    const clock = { t: 1_000 };
    const a = await device(server, clock);
    const b = await device(server, clock);

    await a.lib.importOPML([feed]);
    const [sub] = a.lib.sortedSubscriptions();
    await a.lib.setState([`${sub!.id}:abc`], { isRead: true });
    await a.engine.sync();
    expect(server.records.get(sub!.id)?.fields["feedURL"]?.value).toBe(feed.feedURL);
    expect(server.records.get(`${sub!.id}:abc`)?.fields["isRead"]?.value).toBe(1);

    await b.engine.sync();
    expect(b.lib.subscriptions.get(sub!.id)?.title).toBe("xkcd");
    expect(b.lib.isRead(`${sub!.id}:abc`)).toBe(true);
    expect(b.engine.dirtyRecords()).toEqual([]);
  });

  it("merges edits to different fields made on two devices", async () => {
    const server = new FakeServer();
    const clock = { t: 1_000 };
    const a = await device(server, clock);
    const b = await device(server, clock);
    await a.lib.importOPML([feed]);
    const id = a.lib.sortedSubscriptions()[0]!.id;
    await a.engine.sync();
    await b.engine.sync();

    clock.t = 2_000;
    await a.lib.updateSubscription(id, (s) => ({ ...s, title: "XKCD" }));
    clock.t = 3_000;
    await b.lib.updateSubscription(id, (s) => ({ ...s, folder: "Comics" }));
    await a.engine.sync();
    await b.engine.sync(); // conflicts, merges, re-sends
    await a.engine.sync();

    for (const d of [a, b]) {
      expect(d.lib.subscriptions.get(id)?.title).toBe("XKCD");
      expect(d.lib.subscriptions.get(id)?.folder).toBe("Comics");
    }
  });

  it("propagates deletions with the subscription's states", async () => {
    const server = new FakeServer();
    const clock = { t: 1_000 };
    const a = await device(server, clock);
    const b = await device(server, clock);
    await a.lib.importOPML([feed]);
    const id = a.lib.sortedSubscriptions()[0]!.id;
    await a.lib.setState([`${id}:x`], { isStarred: true });
    await a.engine.sync();
    await b.engine.sync();

    await b.lib.removeSubscription(id);
    await b.engine.sync();
    expect(server.records.size).toBe(0);
    await a.engine.sync();
    expect(a.lib.subscriptions.size).toBe(0);
    expect(a.lib.states.size).toBe(0);
  });

  it("creates the zone when it is missing and uploads local data", async () => {
    const server = new FakeServer();
    server.zone = false;
    const clock = { t: 1_000 };
    const lib = new Library(await openSrsslyDB(`sync-${n++}`), undefined, () => clock.t);
    await lib.load();
    await lib.importOPML([feed]);
    const backend = server.backend();
    await new SyncEngine(lib, backend, () => clock.t).start();
    expect(backend.calls).toContain("createZone");
    expect(server.records.size).toBe(1);
  });

  it("reports access errors such as Advanced Data Protection", async () => {
    const server = new FakeServer();
    const backend = server.backend();
    backend.fetchChanges = async () => {
      throw new SyncError("ACCESS_DENIED", "private db access disabled for this account");
    };
    const lib = new Library(await openSrsslyDB(`sync-${n++}`));
    const engine = new SyncEngine(lib, backend);
    await engine.start();
    expect(engine.status).toMatchObject({ state: "error", code: "ACCESS_DENIED" });
  });
});

describe("mergeFields (ThreeWay on iOS)", () => {
  it("keeps each side's changes and breaks same-field ties", () => {
    const base = { a: 1, b: 1 };
    expect(mergeFields(base, { a: 2, b: 1 }, { a: 1, b: 3 }, false)).toEqual({ a: 2, b: 3 });
    expect(mergeFields(base, { a: 2, b: 1 }, { a: 4, b: 1 }, true)).toEqual({ a: 2, b: 1 });
    expect(mergeFields(base, { a: 2, b: 1 }, { a: 4, b: 1 }, false)).toEqual({ a: 4, b: 1 });
    expect(mergeFields(undefined, { a: 2, b: 1 }, { a: 4, b: 1 }, false)).toEqual({ a: 4, b: 1 });
  });
});
