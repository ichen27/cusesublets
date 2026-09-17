import { useCallback, useEffect, useState, type FormEvent } from "react";
import {
  ShieldCheck,
  FileText,
  Clock,
  Users,
  ArrowRight,
  Check,
  Search,
  AlertCircle,
  History,
} from "lucide-react";
import type {
  Listing,
  User,
  Booking,
  DocumentRecord,
  Audit,
  ReviewStatus,
} from "../shared/types";
import IdentityReviews from "./IdentityReviews";
import { api, money } from "./api";
import { Busy, Empty, ErrorBox } from "./ui";
interface Data {
  listings: Listing[];
  users: User[];
  documents: DocumentRecord[];
  bookings: Booking[];
  audit: Audit[];
  reports?: {
    id: string;
    listingId: string;
    reporterId: string;
    reason: string;
    status: string;
    createdAt: string;
  }[];
}
export default function Admin({
  user,
  notify,
  onRefresh,
}: {
  user: User | null;
  notify: (s: string) => void;
  onRefresh: () => void;
}) {
  const [data, setData] = useState<Data | null>(null),
    [error, setError] = useState(""),
    [tab, setTab] = useState("reviews"),
    [selected, setSelected] = useState(""),
    [reason, setReason] = useState(""),
    [status, setStatus] = useState("needs_info"),
    [lease, setLease] = useState<ReviewStatus>("pending"),
    [permission, setPermission] = useState<ReviewStatus>("pending"),
    [busy, setBusy] = useState(false),
    [scope, setScope] = useState("pending");
  const refresh = useCallback(async () => {
    try {
      setData(await api<Data>("/admin"));
      setError("");
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);
  useEffect(() => {
    refresh();
  }, [refresh]);
  const current = data?.listings.find((l) => l.id === selected);
  const pick = (l: Listing) => {
    setSelected(l.id);
    setLease(l.leaseStatus);
    setPermission(l.permissionStatus);
    setStatus(l.status);
    setReason("");
  };
  async function action(path: string, body: unknown, msg: string) {
    setBusy(true);
    setError("");
    try {
      await api(path, body);
      notify(msg);
      setReason("");
      await refresh();
      onRefresh();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  function review(e: FormEvent) {
    e.preventDefault();
    action(
      `/admin/listings/${selected}/review`,
      {
        status,
        leaseStatus: lease,
        permissionStatus: permission,
        reason,
        leaseDocumentId: data?.documents
          .filter((d) => d.listingId === selected && d.kind === "lease")
          .sort((a, b) => b.createdAt.localeCompare(a.createdAt))[0]?.id,
        permissionDocumentId: data?.documents
          .filter((d) => d.listingId === selected && d.kind === "permission")
          .sort((a, b) => b.createdAt.localeCompare(a.createdAt))[0]?.id,
      },
      "Review saved with an audit record.",
    );
  }
  if (user?.role !== "admin")
    return (
      <main className="workspace">
        <Empty title="Staff access required.">
          This workspace is available only to authorized reviewers.
        </Empty>
      </main>
    );
  return (
    <main className="workspace admin-workspace">
      <div className="workspace-heading">
        <div>
          <span className="eyebrow">
            <ShieldCheck size={13} /> CUSESUBLETS · ADMIN WORKSPACE
          </span>
          <h1>Trust starts with the details.</h1>
          <p>A thoughtful review for every place, person, and handoff.</p>
        </div>
        <span className="staff-label">
          <span className="status-dot green" /> Authorized reviewer
        </span>
      </div>
      <ErrorBox message={error} />
      {!data ? (
        <Busy />
      ) : (
        <>
          <div className="admin-stats">
            {[
              [
                Clock,
                "Awaiting review",
                data.listings.filter(
                  (l) =>
                    l.status === "pending" ||
                    l.status === "needs_info" ||
                    l.leaseStatus === "pending" ||
                    l.permissionStatus === "pending",
                ).length,
              ],
              [
                ShieldCheck,
                "Published places",
                data.listings.filter((l) => l.status === "approved").length,
              ],
              [Users, "Community members", data.users.length],
              [
                AlertCircle,
                "Open disputes",
                data.bookings.filter((b) => b.disputeStatus === "open").length,
              ],
            ].map(([Icon, label, count]) => {
              const I = Icon as typeof Clock;
              return (
                <div className="panel stat" key={String(label)}>
                  <I size={19} />
                  <strong>{String(count)}</strong>
                  <span>{String(label)}</span>
                </div>
              );
            })}
          </div>
          <div className="tabs">
            <button
              className={tab === "reports" ? "active" : ""}
              onClick={() => setTab("reports")}
            >
              Reports{" "}
              <span>
                {data.reports?.filter((r) => r.status === "open").length || 0}
              </span>
            </button>
            <button
              className={tab === "reviews" ? "active" : ""}
              onClick={() => setTab("reviews")}
            >
              Listing reviews
            </button>
            <button
              className={tab === "users" ? "active" : ""}
              onClick={() => setTab("users")}
            >
              Members & identity
            </button>
            <button
              className={tab === "transactions" ? "active" : ""}
              onClick={() => setTab("transactions")}
            >
              Transactions & disputes
            </button>
            <button
              className={tab === "audit" ? "active" : ""}
              onClick={() => setTab("audit")}
            >
              Audit log
            </button>
          </div>
          {tab === "reviews" ? (
            <div className="review-layout">
              <aside className="panel review-queue">
                <div className="queue-heading">
                  <h3>Review queue</h3>
                  <select
                    aria-label="Review queue filter"
                    value={scope}
                    onChange={(e) => setScope(e.target.value)}
                  >
                    <option value="pending">Needs attention</option>
                    <option value="all">All listings</option>
                  </select>
                </div>
                {data.listings
                  .filter(
                    (l) =>
                      scope === "all" ||
                      l.status === "pending" ||
                      l.status === "needs_info" ||
                      l.leaseStatus === "pending" ||
                      l.permissionStatus === "pending",
                  )
                  .map((l) => (
                    <button
                      className={
                        selected === l.id ? "review-item active" : "review-item"
                      }
                      key={l.id}
                      onClick={() => pick(l)}
                    >
                      <img src={l.images[0] || "/photo-pending.svg"} alt="" />
                      <span>
                        <span className={"status " + l.status}>
                          {l.status.replace("_", " ")}
                        </span>
                        <b>{l.title}</b>
                        <small>
                          {l.hostName} · {money(l.price)}/mo
                        </small>
                      </span>
                      <ArrowRight size={15} />
                    </button>
                  ))}
              </aside>
              <section className="panel review-detail">
                {current ? (
                  <>
                    <div className="section-heading">
                      <div>
                        <span className="eyebrow">LISTING REVIEW</span>
                        <h2>{current.title}</h2>
                        <p>
                          {current.address} · {current.neighborhood}
                        </p>
                      </div>
                      <span className={"status " + current.status}>
                        {current.status.replace("_", " ")}
                      </span>
                    </div>
                    <div className="review-facts">
                      <span>
                        Host <b>{current.hostName}</b>
                      </span>
                      <span>
                        Identity <b>{current.hostIdentity}</b>
                      </span>
                      <span>
                        Dates{" "}
                        <b>
                          {current.startDate} → {current.endDate}
                        </b>
                      </span>
                    </div>
                    <h3>Submitted evidence</h3>
                    <div className="evidence-list">
                      {data.documents.filter((d) => d.listingId === current.id)
                        .length ? (
                        data.documents
                          .filter((d) => d.listingId === current.id)
                          .map((d) => (
                            <a
                              key={d.id}
                              target="_blank"
                              rel="noreferrer"
                              href={`/api/documents/${d.id}`}
                            >
                              <FileText size={22} />
                              <span>
                                <b>{d.name}</b>
                                <small>
                                  {d.kind} · Private reviewer access
                                </small>
                              </span>
                              <ArrowRight size={15} />
                            </a>
                          ))
                      ) : (
                        <div className="notice">
                          No documents submitted yet. Request the lease and
                          sublet authorization before verifying.
                        </div>
                      )}
                    </div>
                    <form className="form-stack" onSubmit={review}>
                      <h3>Review checklist</h3>
                      <p className="muted">
                        Compare tenant name, property address, term dates, and
                        the scope of permission. Verification requires evidence,
                        not just a file upload.
                      </p>
                      <div className="form-grid">
                        <label>
                          Lease review
                          <select
                            value={lease}
                            onChange={(e) =>
                              setLease(e.target.value as ReviewStatus)
                            }
                          >
                            <option value="pending">Pending</option>
                            <option value="verified">
                              Verified against evidence
                            </option>
                            <option value="needs_info">
                              More information needed
                            </option>
                            <option value="rejected">Rejected</option>
                          </select>
                        </label>
                        <label>
                          Sublet permission
                          <select
                            value={permission}
                            onChange={(e) =>
                              setPermission(e.target.value as ReviewStatus)
                            }
                          >
                            <option value="pending">Pending</option>
                            <option value="verified">
                              Verified against evidence
                            </option>
                            <option value="needs_info">
                              More information needed
                            </option>
                            <option value="rejected">Rejected</option>
                          </select>
                        </label>
                      </div>
                      <label>
                        Publication status
                        <select
                          value={status}
                          onChange={(e) => setStatus(e.target.value)}
                        >
                          <option value="pending">Unpublished · pending</option>
                          <option value="needs_info">
                            Unpublished · needs information
                          </option>
                          <option value="approved">
                            Published (independent of badges)
                          </option>
                          <option value="rejected">Reject listing</option>
                          <option value="paused">Pause listing</option>
                        </select>
                      </label>
                      <label>
                        Reason / note for the host
                        <textarea
                          value={reason}
                          onChange={(e) => setReason(e.target.value)}
                          required
                          minLength={5}
                          maxLength={2000}
                          placeholder="Explain your decision and any next steps…"
                        />
                      </label>
                      <button disabled={busy} className="primary">
                        {busy ? "Saving…" : "Save review decision"}
                        <Check size={16} />
                      </button>
                    </form>
                  </>
                ) : (
                  <Empty title="Give every place a careful look.">
                    Select a listing to review its details, evidence, and next
                    steps.
                  </Empty>
                )}
              </section>
            </div>
          ) : tab === "reports" ? (
            <div className="panel">
              {data.reports?.length ? (
                data.reports.map((r) => (
                  <div className="audit-item" key={r.id}>
                    <AlertCircle size={18} />
                    <div>
                      <span className={"status " + r.status}>{r.status}</span>
                      <h3>
                        {data.listings.find((l) => l.id === r.listingId)
                          ?.title || r.listingId}
                      </h3>
                      <p>{r.reason}</p>
                      <small>
                        Reported {new Date(r.createdAt).toLocaleString()}
                      </small>
                      {r.status === "open" && (
                        <div className="button-row">
                          <button
                            className="outline small"
                            onClick={() => {
                              const l = data.listings.find(
                                (l) => l.id === r.listingId,
                              );
                              if (l) {
                                pick(l);
                                setTab("reviews");
                                setScope("all");
                              }
                            }}
                          >
                            Review listing
                          </button>
                          <button
                            className="outline small"
                            disabled={busy}
                            onClick={() => {
                              const reason = prompt(
                                "Explain how this report was investigated and resolved.",
                              );
                              if (reason)
                                action(
                                  `/admin/reports/${r.id}/resolve`,
                                  { reason },
                                  "Report resolution recorded.",
                                );
                            }}
                          >
                            Resolve report
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                ))
              ) : (
                <Empty title="A place for community concerns.">
                  Reports from listings appear here for staff review.
                </Empty>
              )}
            </div>
          ) : tab === "users" ? (
            <div>
              <IdentityReviews user={user} onRefresh={refresh} />
              <div className="panel">
                <h2>Member access</h2>
                <div className="table-scroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Member</th>
                        <th>Role</th>
                        <th>Identity</th>

                        <th>Account access</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.users.map((u) => (
                        <tr key={u.id}>
                          <td>
                            <b>{u.name}</b>
                            <small>{u.email}</small>
                          </td>
                          <td>{u.role}</td>
                          <td>
                            <span className={"status " + u.identity}>
                              {u.identity.replace("_", " ")}
                            </span>
                          </td>
                          <td>
                            <span
                              className={
                                "status " +
                                (u.suspended ? "rejected" : "verified")
                              }
                            >
                              {u.suspended ? "Suspended" : "Active"}
                            </span>
                            {u.role !== "admin" && (
                              <button
                                className="text-button small"
                                disabled={busy}
                                onClick={() => {
                                  const reason = prompt(
                                    u.suspended
                                      ? "Explain why access should be restored."
                                      : "Explain the reason for suspension. Existing dispute access remains available.",
                                  );
                                  if (reason)
                                    action(
                                      `/admin/users/${u.id}/status`,
                                      { suspended: !u.suspended, reason },
                                      "Account access updated.",
                                    );
                                }}
                              >
                                {u.suspended ? "Restore access" : "Suspend"}
                              </button>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          ) : tab === "transactions" ? (
            <div className="panel">
              <div className="notice">
                Payouts are blocked by an open dispute. Resolving a dispute
                records the review outcome; it does not send money or issue a
                refund.
              </div>
              {data.bookings.length ? (
                <div className="table-scroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Reservation</th>
                        <th>Monthly rent</th>
                        <th>Payment</th>
                        <th>Dispute</th>
                        <th>Action</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.bookings.map((b) => (
                        <tr key={b.id}>
                          <td>
                            <b>
                              {b.listingTitle ||
                                data.listings.find((l) => l.id === b.listingId)
                                  ?.title ||
                                "Archived listing"}
                            </b>
                            <small>{b.id.slice(0, 12)}</small>
                          </td>
                          <td>{money(b.amount)}</td>
                          <td>{b.paymentStatus.replaceAll("_", " ")}</td>
                          <td>
                            <span className={"status " + b.disputeStatus}>
                              {b.disputeStatus}
                            </span>
                          </td>
                          <td>
                            {b.disputeStatus === "open" ? (
                              <button
                                className="outline small"
                                disabled={busy}
                                onClick={() => {
                                  const r = prompt(
                                    "Explain the resolution and evidence reviewed.",
                                  );
                                  if (r)
                                    action(
                                      `/admin/bookings/${b.id}/resolve`,
                                      { reason: r },
                                      "Dispute resolution recorded.",
                                    );
                                }}
                              >
                                Record resolution
                              </button>
                            ) : (
                              <span className="muted">No open dispute</span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ) : (
                <Empty title="No transactions to review yet.">
                  Accepted offers and payment statuses will appear here.
                </Empty>
              )}
            </div>
          ) : (
            <div className="panel audit-log">
              {data.audit.length ? (
                data.audit.map((a) => (
                  <div className="audit-item" key={a.id}>
                    <History size={18} />
                    <div>
                      <b>{a.action.replaceAll("_", " ")}</b>
                      <p>{a.reason}</p>
                      <small>
                        {a.actorId} · {a.targetId.slice(0, 16)} ·{" "}
                        {new Date(a.createdAt).toLocaleString()}
                      </small>
                    </div>
                  </div>
                ))
              ) : (
                <Empty title="Every decision leaves a record.">
                  Review actions will appear here with the reviewer, reason, and
                  timestamp.
                </Empty>
              )}
            </div>
          )}
        </>
      )}
    </main>
  );
}
