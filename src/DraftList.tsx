import { useEffect, useState } from "react";
import { ArrowRight, FilePenLine, Trash2 } from "lucide-react";
import type { PrivateDraft, ListingDraftData } from "../shared/drafts";
import { api } from "./api";
import { ErrorBox } from "./ui";
export default function DraftList({
  onSearch,
  onListing,
  onChange,
}: {
  onSearch: () => void;
  onListing: (draftId: string) => void;
  onChange?: () => void;
}) {
  const [drafts, setDrafts] = useState<PrivateDraft[]>([]),
    [error, setError] = useState(""),
    [busy, setBusy] = useState("");
  async function load() {
    try {
      setDrafts((await api<{ drafts: PrivateDraft[] }>("/drafts")).drafts);
      setError("");
    } catch (cause) {
      setError((cause as Error).message);
    }
  }
  useEffect(() => {
    void load();
    const refresh = () => {
      void load();
    };
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, []);
  async function discard(draft: PrivateDraft) {
    setBusy(draft.id);
    setError("");
    try {
      await api(`/drafts/${draft.id}/delete`, { revision: draft.revision });
      await load();
      onChange?.();
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy("");
    }
  }
  if (!drafts.length && !error) return null;
  return (
    <section className="private-drafts">
      <header>
        <span className="eyebrow">ONLY YOU CAN SEE THESE</span>
        <h2>Pick up where you left off.</h2>
        <p>
          Drafts stay private until you publish a place or turn on your search.
        </p>
      </header>
      <ErrorBox message={error} />
      {drafts.map((draft) => (
        <article className="draft-row" key={draft.id}>
          <FilePenLine size={23} />
          <div>
            <h3>
              {draft.kind === "search"
                ? "My search"
                : (draft.data as ListingDraftData).title || "My place"}
            </h3>
            <small>
              Step {draft.step} of 4 · Saved{" "}
              {new Date(draft.updatedAt).toLocaleDateString()}
            </small>
          </div>
          <button
            className="outline"
            onClick={() =>
              draft.kind === "search" ? onSearch() : onListing(draft.id)
            }
          >
            Continue <ArrowRight size={16} />
          </button>
          <button
            className="icon-button"
            aria-label={`Delete ${draft.kind} draft`}
            disabled={busy === draft.id}
            onClick={() => {
              if (
                window.confirm(
                  "Delete this private draft? Published places and your active search will stay as they are.",
                )
              )
                void discard(draft);
            }}
          >
            <Trash2 size={17} />
          </button>
        </article>
      ))}
    </section>
  );
}
