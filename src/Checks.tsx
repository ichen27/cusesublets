import { ShieldCheck, Check, Circle, ArrowUpRight } from "lucide-react";
import type { ReviewStatus } from "../shared/types";
export function IdentityBadge({ status }: { status: ReviewStatus }) {
  return status === "verified" ? (
    <span className="identity-badge">
      <ShieldCheck size={14} /> Identity verified
    </span>
  ) : (
    <span className="identity-unverified">Identity not verified</span>
  );
}
export default function Checks({
  identity,
  lease,
  permission,
  compact = false,
  onLearn,
}: {
  identity: ReviewStatus;
  lease?: ReviewStatus;
  permission?: ReviewStatus;
  compact?: boolean;
  onLearn?: () => void;
}) {
  const rows = [
    {
      label: identity === "verified" ? "Identity verified" : "Identity",
      status: identity,
      explanation: "Manual review of the person’s submitted ID.",
    },
    ...(lease
      ? [
          {
            label: lease === "verified" ? "Lease reviewed" : "Lease",
            status: lease,
            explanation: "Manual review of the lease for this property.",
          },
        ]
      : []),
    ...(permission
      ? [
          {
            label:
              permission === "verified"
                ? "Sublet permission reviewed"
                : "Sublet permission",
            status: permission,
            explanation: "Manual review of permission to sublet.",
          },
        ]
      : []),
  ];
  return (
    <section
      className={"checks-panel " + (compact ? "compact" : "")}
      aria-label="CuseSublets Checks"
    >
      <div className="checks-heading">
        <ShieldCheck size={20} />
        <div>
          <span className="eyebrow">CUSESUBLETS CHECKS</span>
          <h3>What’s been checked</h3>
        </div>
        {onLearn && (
          <button
            className="icon-button"
            aria-label="About CuseSublets Checks"
            onClick={onLearn}
          >
            <ArrowUpRight size={16} />
          </button>
        )}
      </div>
      <div className="checks-rows">
        {rows.map((r) => (
          <div
            className={
              "check-row " + (r.status === "verified" ? "complete" : "")
            }
            key={r.label}
          >
            <span className="check-symbol">
              {r.status === "verified" ? (
                <Check size={14} />
              ) : (
                <Circle size={13} />
              )}
            </span>
            <div>
              <b>{r.label}</b>
              {!compact && <small>{r.explanation}</small>}
            </div>
            <span className="check-state">
              {r.status === "verified"
                ? "Checked"
                : r.status === "needs_info"
                  ? "More info needed"
                  : r.status === "rejected"
                    ? "Not verified"
                    : "Not yet checked"}
            </span>
          </div>
        ))}
      </div>
      {!compact && (
        <p className="checks-note">
          Each check is separate. Published listings may be unverified. These
          checks aren’t a guarantee of a property or person.
        </p>
      )}
    </section>
  );
}
export function ChecksGuide() {
  return (
    <main className="workspace checks-guide">
      <span className="eyebrow">CUSESUBLETS CHECKS</span>
      <h1>Know what’s been checked.</h1>
      <p className="lead">
        Clear signals about the person and the place, wherever your next chapter
        takes you.
      </p>
      <div className="guide-grid">
        {[
          [
            "01",
            "Identity verified",
            "A person submits an ID privately. Our review team checks it before adding the identity badge to their profile.",
          ],
          [
            "02",
            "Lease reviewed",
            "A host submits their lease. Our review team checks the name, property and lease dates before marking the lease reviewed.",
          ],
          [
            "03",
            "Sublet permission reviewed",
            "We separately review the host’s evidence that they have permission to sublet. A lease alone does not automatically confirm permission.",
          ],
        ].map(([n, t, d]) => (
          <article className="panel" key={n}>
            <span className="guide-number">{n}</span>
            <h2>{t}</h2>
            <p>{d}</p>
          </article>
        ))}
      </div>
      <section className="panel">
        <h2>Published doesn’t mean verified.</h2>
        <p>
          You can post a listing immediately. Badges appear only after the
          corresponding manual review. Ask questions in chat, look at the
          property, and understand the agreement before committing.
        </p>
        <h3>Your documents stay private.</h3>
        <p>
          ID and verification documents are available only to you and authorized
          reviewers. Your public profile shows the results, not your documents,
          email or phone number.
        </p>
        <h3>Reviews come from completed leases.</h3>
        <p>
          Only participants in eligible completed reservations can leave a
          review. Signing and live payments are not enabled in this private
          beta.
        </p>
      </section>
    </main>
  );
}
