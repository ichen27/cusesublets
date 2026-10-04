import { useState } from "react";
import { api } from "./api";
import type { Listing } from "../shared/types";
export default function LegacyBookmarks({ listings }: { listings: Listing[] }) {
  const [ids, setIds] = useState<string[]>(() => {
      try {
        const x = JSON.parse(localStorage.getItem("cusesublets-saved") || "[]");
        return Array.isArray(x) ? x.filter((v) => typeof v === "string") : [];
      } catch {
        return [];
      }
    }),
    [busy, setBusy] = useState(false),
    [message, setMessage] = useState("");
  if (!ids.length) return message ? <p role="status">{message}</p> : null;
  async function importBookmarks() {
    setBusy(true);
    const imported: string[] = [];
    try {
      for (const id of ids.filter((id) => listings.some((l) => l.id === id))) {
        await api("/social/listing/" + encodeURIComponent(id) + "/save", {
          saved: true,
        });
        imported.push(id);
      }
    } catch (e) {
      setMessage((e as Error).message);
    } finally {
      const remaining = ids.filter((id) => !imported.includes(id));
      localStorage.setItem("cusesublets-saved", JSON.stringify(remaining));
      setIds(remaining);
      setMessage(
        `${imported.length} available bookmarks added to your account.`,
      );
      setBusy(false);
      window.dispatchEvent(new Event("social-saved-changed"));
    }
  }
  return (
    <section className="legacy-bookmarks">
      <strong>Bookmarks from the previous design</strong>
      <p>
        This browser has {ids.length} saved places. Add the available ones to
        your private account shortlist.
      </p>
      <button
        className="outline"
        disabled={busy}
        onClick={() => void importBookmarks()}
      >
        {busy ? "Adding…" : "Add my browser bookmarks"}
      </button>
      {message && <p role="status">{message}</p>}
    </section>
  );
}
