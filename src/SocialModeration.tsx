import { useEffect, useState } from "react";
import type { SocialReport } from "../shared/social";
import { api } from "./api";
export default function SocialModeration() {
  const [reports, setReports] = useState<SocialReport[]>([]),
    [status, setStatus] = useState("open"),
    [next, setNext] = useState<string | null>(null),
    [reasons, setReasons] = useState<Record<string, string>>({}),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  async function load(cursor?: string) {
    const p = await api<{ reports: SocialReport[]; nextCursor: string | null }>(
      `/social/moderation?status=${status}${cursor ? "&cursor=" + encodeURIComponent(cursor) : ""}`,
    );
    setReports((old) => (cursor ? [...old, ...p.reports] : p.reports));
    setNext(p.nextCursor);
  }
  useEffect(() => {
    void load().catch((e) => setError(e.message));
  }, [status]);
  async function action(r: SocialReport, kind: "moderate" | "resolve") {
    setBusy(true);
    setError("");
    try {
      const reason = reasons[r.id]?.trim();
      if (!reason) throw new Error("Enter a reason for the moderation audit.");
      if (kind === "moderate")
        await api(`/social/comments/${r.commentId}/moderate`, {
          removed: !r.removed,
          reason,
        });
      else await api(`/social/reports/${r.id}/resolve`, { reason });
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="social-moderation">
      <h2>Community reports</h2>
      <label>
        Report status{" "}
        <select value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="open">Open</option>
          <option value="resolved">Resolved</option>
        </select>
      </label>
      {error && <p role="alert">{error}</p>}
      {!reports.length && <p>No {status} comment reports.</p>}
      {reports.map((r) => (
        <article className="social-report" key={r.id}>
          <strong>{r.authorName}</strong>
          <p>{r.body}</p>
          <p>Reported: {r.reason}</p>
          <small>
            {r.targetType} · {r.targetId} ·{" "}
            {r.deleted
              ? "Deleted by author"
              : r.removed
                ? "Removed by staff"
                : "Visible"}
          </small>
          <label>
            Moderation reason
            <input
              maxLength={1000}
              value={reasons[r.id] ?? ""}
              onChange={(e) =>
                setReasons({ ...reasons, [r.id]: e.target.value })
              }
            />
          </label>
          <div>
            {!r.deleted && (
              <button
                disabled={busy}
                onClick={() => void action(r, "moderate")}
              >
                {r.removed ? "Restore comment" : "Remove comment"}
              </button>
            )}
            {r.status === "open" && (
              <button disabled={busy} onClick={() => void action(r, "resolve")}>
                Resolve report
              </button>
            )}
          </div>
        </article>
      ))}
      {next && (
        <button
          disabled={busy}
          onClick={() => void load(next).catch((e) => setError(e.message))}
        >
          Load more reports
        </button>
      )}
    </section>
  );
}
