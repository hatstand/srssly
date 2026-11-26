import { useEffect, useSyncExternalStore } from "react";
import { signInButtonID, signOutButtonID } from "../sync/cloudkit";
import { type SyncController, describeSyncError } from "../sync/controller";

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

export function SyncPanel({ controller }: { controller: SyncController }) {
  const state = useSyncExternalStore(controller.subscribe, controller.getState);
  useEffect(() => void controller.start(), [controller]);

  let text: string;
  switch (state.kind) {
    case "unconfigured":
      text = "iCloud sync is off (no CloudKit API token in this build).";
      break;
    case "loading":
      text = "Connecting to iCloud…";
      break;
    case "signedOut":
      text = "Sign in to sync subscriptions and read state with your devices.";
      break;
    case "failed":
      text = `iCloud unavailable: ${state.message}`;
      break;
    case "signedIn": {
      const s = state.status;
      text =
        s.state === "syncing" ? "Syncing…" :
        s.state === "error" ? describeSyncError(s.code, s.message) :
        s.lastSync ? `Synced at ${timeFormat.format(new Date(s.lastSync))}` : "Synced";
      break;
    }
  }
  const error = state.kind === "failed" || (state.kind === "signedIn" && state.status.state === "error");
  return (
    <section className="sync">
      <p className={error ? "error" : "hint"}>{text}</p>
      {/* CloudKit JS draws its Sign in with Apple ID buttons into these. */}
      <div id={signInButtonID} hidden={state.kind !== "signedOut"} />
      <div id={signOutButtonID} hidden={state.kind !== "signedIn"} />
      {state.kind === "signedIn" ? (
        <button type="button" className="link" onClick={() => controller.syncNow()}>
          Sync now
        </button>
      ) : null}
    </section>
  );
}
