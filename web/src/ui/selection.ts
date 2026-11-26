import type { UUID } from "../core/uuid";

export type Source = { kind: "all" } | { kind: "starred" } | { kind: "feed"; id: UUID } | { kind: "folder"; name: string };

export const sameSource = (a: Source, b: Source): boolean =>
  a.kind === b.kind &&
  (a.kind !== "feed" || (b.kind === "feed" && a.id === b.id)) &&
  (a.kind !== "folder" || (b.kind === "folder" && a.name === b.name));
