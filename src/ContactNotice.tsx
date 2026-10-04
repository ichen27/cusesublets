import { useState } from "react";
import { FileCheck2, ShieldCheck, ShieldAlert } from "lucide-react";
import type { HousingSearch, Listing, ReviewStatus } from "../shared/types";
import { ErrorBox, Modal } from "./ui";
import "./matches.css";

type Target = { listing?: Listing; person?: HousingSearch };
export function needsContactNotice({ listing, person }: Target) {
  return listing
    ? listing.hostIdentity !== "verified" || listing.leaseStatus !== "verified" || listing.permissionStatus !== "verified"
    : !!person && person.ownerIdentity !== "verified";
}
const statusText: Record<ReviewStatus, string> = {
  verified: "Checked", pending: "Not yet checked", needs_info: "More information needed", rejected: "Not approved",
};
export default function ContactNotice({ listing, person, onContinue, onClose, onChecks, busy = false, error = "" }: Target & {
  onContinue: () => void; onClose: () => void; onChecks?: () => void; busy?: boolean; error?: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const checks: { name: string; status: ReviewStatus }[] = listing ? [
    { name: "Host identity", status: listing.hostIdentity },
    { name: "Lease", status: listing.leaseStatus },
    { name: "Permission to sublease", status: listing.permissionStatus },
  ] : [{ name: "Identity", status: person?.ownerIdentity || "pending" }];
  const missing = checks.filter((check) => check.status !== "verified");
  const names = missing.map((check) => check.name.toLowerCase());
  const missingText = names.length > 1 ? names.slice(0, -1).join(", ") + " and " + names.at(-1) : names[0];
  return <Modal title={missing.length ? "Before you say hello" : "About these checks"} onClose={() => { if (!busy) onClose(); }}>
    <div className="contact-notice">
      <div className="contact-notice-symbol">{missing.length ? <ShieldAlert size={30} /> : <ShieldCheck size={30} />}</div>
      <p>{missing.length ? listing ? `This listing’s ${missingText} ${missing.length === 1 ? "has" : "have"} not been verified.` : `${person?.ownerName || "This person"}’s identity has not been verified.` : "The checks shown here have been reviewed."}</p>
      <p className="contact-notice-quiet">Review the details before making commitments or sending money. A completed check does not guarantee a person or property is safe.</p>
      {expanded && <ul className="contact-check-list">{checks.map((check) => <li key={check.name}><span>{check.status === "verified" ? <ShieldCheck size={17} /> : <FileCheck2 size={17} />}{check.name}</span><strong>{statusText[check.status]}</strong></li>)}</ul>}
      <ErrorBox message={error} />
      <div className="contact-notice-actions"><button className="outline" disabled={busy} onClick={() => onChecks ? onChecks() : setExpanded(!expanded)}>{expanded ? "Hide checks" : "View checks"}</button><button className="primary" disabled={busy} onClick={onContinue}>{busy ? "Opening conversation…" : "Continue to message"}</button></div>
      <small>Your message is private. Nothing is sent until you choose Send.</small>
    </div>
  </Modal>;
}
