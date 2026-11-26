import { sha256, toHex, utf8 } from "./hash";
import type { UUID } from "./uuid";

export interface ArticleIdentity {
  guid?: string | undefined;
  /** The item's URL as a string. */
  link?: string | undefined;
  title?: string | undefined;
  /** `published ?? updated`. */
  date?: Date | undefined;
}

function nonEmpty(s: string | undefined): string | undefined {
  const t = s?.trim();
  return t ? t : undefined;
}

/**
 * The article's key, `<subscription UUID>:<32 hex chars>`, identical to
 * `ArticleKey.make` on iOS so read/starred state matches across clients.
 */
export async function articleKey(subscriptionID: UUID, item: ArticleIdentity): Promise<string> {
  const guid = nonEmpty(item.guid);
  const link = nonEmpty(item.link);
  let identity: string;
  if (guid !== undefined) {
    identity = `g:${guid}`;
  } else if (link !== undefined) {
    identity = `l:${link}`;
  } else {
    const seconds = item.date ? String(Math.trunc(item.date.getTime() / 1000)) : "";
    identity = `t:${item.title ?? ""}|${seconds}`;
  }
  const hex = toHex((await sha256(utf8(identity))).slice(0, 16));
  return `${subscriptionID}:${hex}`;
}

/** The subscription part of an article key. */
export function subscriptionOf(key: string): string {
  return key.split(":", 1)[0] ?? key;
}
