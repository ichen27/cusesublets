import { useCallback, useEffect, useState } from "react";
import { FileText, ShieldCheck } from "lucide-react";
import type { IdentitySubmission, User } from "../shared/types";
import { api } from "./api";
import { Busy, Empty, ErrorBox } from "./ui";
export default function IdentityReviews({
  user,
  onRefresh,
}: {
  user: User;
  onRefresh: () => void;
}) {
  const [items, setItems] = useState<IdentitySubmission[]>([]),
    [loading, setLoading] = useState(true),
    [selected, setSelected] = useState(""),
    [reason, setReason] = useState(""),
    [status, setStatus] = useState("needs_info"),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const load = useCallback(async () => {
    try {
      const r = await api<{ submissions: IdentitySubmission[] }>(
        "/admin/identities",
      );
      setItems(r.submissions);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    load();
  }, [load]);
  const current = items.find((i) => i.userId === selected),
    latest = current?.documents[0];
  return (
    <section className="identity-reviews">
      <ErrorBox message={error} />
      <div className="notice">
        Manual identity review · Check the current ID against the member’s name.
        Never copy ID details into public notes. You cannot verify your own
        identity.
      </div>
      {loading ? (
        <Busy />
      ) : (
        <div className="review-layout">
          <aside className="panel review-queue">
            <h3>Identity submissions</h3>
            {items.length ? (
              items.map((i) => (
                <button
                  className={
                    "review-item " + (selected === i.userId ? "active" : "")
                  }
                  key={i.userId}
                  onClick={() => {
                    setSelected(i.userId);
                    setReason("");
                    setStatus("needs_info");
                  }}
                >
                  <ShieldCheck size={20} />
                  <span>
                    <b>{i.name}</b>
                    <small>{i.email}</small>
                    <span className={"status " + i.identity}>
                      {i.identity.replaceAll("_", " ")}
                    </span>
                  </span>
                </button>
              ))
            ) : (
              <Empty title="No identity submissions yet.">
                Uploaded IDs will appear here.
              </Empty>
            )}
          </aside>
          <div className="panel">
            {current ? (
              <>
                <span className="eyebrow">IDENTITY REVIEW</span>
                <h2>{current.name}</h2>
                <p>{current.email}</p>
                {current.identityNote && (
                  <div className="notice">
                    Last review: {current.identityNote}
                  </div>
                )}
                <h3>Current evidence</h3>
                {latest ? (
                  <a
                    className="identity-evidence"
                    href={`/api/identity-documents/${latest.id}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <FileText size={22} />
                    <span>
                      <b>{latest.name}</b>
                      <small>
                        Submitted {new Date(latest.createdAt).toLocaleString()}
                      </small>
                    </span>
                  </a>
                ) : (
                  <p>No ID submitted.</p>
                )}
                <form
                  className="form-stack"
                  onSubmit={async (e) => {
                    e.preventDefault();
                    if (!latest) return;
                    setBusy(true);
                    setError("");
                    try {
                      await api(
                        `/admin/identities/${encodeURIComponent(current.userId)}/review`,
                        { status, reason, documentId: latest.id },
                      );
                      await load();
                      onRefresh();
                      setReason("");
                    } catch (e) {
                      setError((e as Error).message);
                    } finally {
                      setBusy(false);
                    }
                  }}
                >
                  <label>
                    Review result
                    <select
                      value={status}
                      onChange={(e) => setStatus(e.target.value)}
                    >
                      <option value="needs_info">
                        Request clearer or additional evidence
                      </option>
                      <option value="verified">
                        Verify identity against current ID
                      </option>
                      <option value="rejected">Do not verify</option>
                    </select>
                  </label>
                  <label>
                    Private note to the member
                    <textarea
                      required
                      minLength={5}
                      maxLength={2000}
                      value={reason}
                      onChange={(e) => setReason(e.target.value)}
                      placeholder="Explain the review outcome without recording ID numbers or other unnecessary personal details."
                    />
                  </label>
                  <button
                    className="primary"
                    disabled={busy || !latest || current.userId === user.id}
                  >
                    {busy ? "Saving…" : "Save identity review"}
                  </button>
                  {current.userId === user.id && (
                    <p className="muted">
                      Another authorized reviewer must review your identity.
                    </p>
                  )}
                </form>
              </>
            ) : (
              <Empty title="Review the person behind the profile.">
                Select a submission to inspect its private evidence.
              </Empty>
            )}
          </div>
        </div>
      )}
    </section>
  );
}
