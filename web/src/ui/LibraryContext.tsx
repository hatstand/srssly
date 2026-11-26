import { createContext, useContext, useSyncExternalStore } from "react";
import type { Library } from "../store/library";

export const LibraryContext = createContext<Library | null>(null);

/** The library, re-rendering whenever it changes. */
export function useLibrary(): Library {
  const lib = useContext(LibraryContext);
  if (!lib) throw new Error("useLibrary outside LibraryContext");
  useSyncExternalStore(lib.subscribe, lib.getVersion);
  return lib;
}
