import { useState } from "react";
import {
  ArrowRight,
  Heart,
  MapPin,
  ShieldCheck,
  Footprints,
  BedDouble,
  Bath,
  CalendarDays,
  MessageCircle,
  Check,
  Box,
  Image,
  Video,
} from "lucide-react";
import type { Listing, User } from "../shared/types";
import { api, money, date, syracuseToday } from "./api";
import { Modal, Badge, ErrorBox } from "./ui";
export default function ListingDetail({
  listing: l,
  user,
  demo,
  saved,
  onSave,
  onClose,
  onLogin,
  notify,
}: {
  listing: Listing;
  user: User | null;
  demo: boolean;
  saved: boolean;
  onSave: () => void;
  onClose: () => void;
  onLogin: () => void;
  notify: (s: string) => void;
}) {
  const [tab, setTab] = useState("photos"),
    [photo, setPhoto] = useState(0),
    [mode, setMode] = useState(""),
    [message, setMessage] = useState(""),
    [amount, setAmount] = useState(l.price),
    [start, setStart] = useState(
      l.startDate > syracuseToday() ? l.startDate : syracuseToday(),
    ),
    [end, setEnd] = useState(l.endDate),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  async function send() {
    setBusy(true);
    setError("");
    try {
      if (mode === "report") {
        await api(`/listings/${l.id}/report`, { reason: message });
        notify("Report sent to the review team. Thank you for flagging it.");
      } else if (mode === "message") {
        await api("/messages", { listingId: l.id, body: message });
        notify("Message sent. Continue the conversation in your inbox.");
      } else {
        await api("/offers", {
          listingId: l.id,
          amount,
          startDate: start,
          endDate: end,
        });
        notify(
          "Request sent. Your host can review it in their offers. No payment was taken.",
        );
      }
      setMode("");
      setMessage("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  const action = (next: string) => {
    if (!user) {
      onLogin();
      return;
    }
    setError("");
    setMode(next);
    if (next === "reserve") setAmount(l.price);
  };
  return (
    <Modal title="Your next place, a little closer." wide onClose={onClose}>
      <div className="detail">
        <div className="detail-heading">
          <div>
            <span className="eyebrow">
              {l.neighborhood.toUpperCase()} · SYRACUSE
            </span>
            <h2>{l.title}</h2>
            <p>
              <MapPin size={14} />
              {l.address} <span>· Approximate location</span>
            </p>
          </div>
          <button className="outline small" onClick={onSave}>
            <Heart size={16} fill={saved ? "currentColor" : "none"} />
            {saved ? "Saved" : "Save"}
          </button>
        </div>
        <div className="media-tabs">
          <button
            className={tab === "photos" ? "active" : ""}
            onClick={() => setTab("photos")}
          >
            <Image size={15} /> Photos
          </button>
          {l.matterportUrl && (
            <button
              className={tab === "tour" ? "active" : ""}
              onClick={() => setTab("tour")}
            >
              <Box size={15} /> 3D tour
            </button>
          )}
          {l.videoUrl && (
            <button
              className={tab === "video" ? "active" : ""}
              onClick={() => setTab("video")}
            >
              <Video size={15} /> Walkthrough
            </button>
          )}
        </div>
        <div className="detail-media">
          {tab === "tour" ? (
            <iframe
              title="Matterport property tour"
              src={l.matterportUrl}
              allow="fullscreen; xr-spatial-tracking"
              referrerPolicy="no-referrer"
            />
          ) : tab === "video" ? (
            <video src={l.videoUrl} controls />
          ) : (
            <>
              <img
                src={l.images[photo] || "/photo-pending.svg"}
                alt={`${l.title}, photo ${photo + 1}`}
              />
              {l.images.length > 1 && (
                <div className="gallery-buttons">
                  {l.images.map((_, i) => (
                    <button
                      className={i === photo ? "active" : ""}
                      key={i}
                      aria-label={`Show photo ${i + 1}`}
                      onClick={() => setPhoto(i)}
                    >
                      {i + 1}
                    </button>
                  ))}
                </div>
              )}
            </>
          )}
          {l.sample && (
            <span className="sample-label">
              Sample listing · Illustrative photography
            </span>
          )}
        </div>
        <div className="detail-columns">
          <div>
            <div className="detail-specs">
              <span>
                <BedDouble />
                {l.beds} bedroom{l.beds > 1 ? "s" : ""}
              </span>
              <span>
                <Bath />
                {l.baths} bathroom{l.baths > 1 ? "s" : ""}
              </span>
              <span>
                <Footprints />
                {l.walkMinutes} min to SU
              </span>
            </div>
            <h3>A little about the place</h3>
            <p className="description">{l.description}</p>
            <h3>The good stuff</h3>
            <div className="amenities">
              {l.amenities.map((a) => (
                <span key={a}>
                  <Check size={15} />
                  {a}
                </span>
              ))}
            </div>
            <div className="host-card">
              <span className="avatar">{l.hostName[0]}</span>
              <div>
                <h3>Meet {l.hostName}</h3>
                <p>
                  Your host ·{" "}
                  {l.hostIdentity === "verified"
                    ? "Identity checked"
                    : "Identity review pending"}
                </p>
              </div>
              <MessageCircle size={20} />
            </div>
            <div className="trust-checks">
              <h3>
                <ShieldCheck size={19} /> Know what’s been checked
              </h3>
              <p>
                <span
                  className={
                    "status-dot " +
                    (l.hostIdentity === "verified" ? "green" : "")
                  }
                />
                Identity{" "}
                {l.hostIdentity === "verified" ? "checked" : "not yet checked"}
              </p>
              <p>
                <span
                  className={
                    "status-dot " +
                    (l.leaseStatus === "verified" ? "green" : "")
                  }
                />
                Lease{" "}
                {l.leaseStatus === "verified" ? "reviewed" : "review pending"}
              </p>
              <p>
                <span
                  className={
                    "status-dot " +
                    (l.permissionStatus === "verified" ? "green" : "")
                  }
                />
                Sublet permission{" "}
                {l.permissionStatus === "verified"
                  ? "reviewed"
                  : "review pending"}
              </p>
              <small>
                These are individual checks, not a guarantee. Ask questions and
                review the agreement before committing.
              </small>
            </div>
          </div>
          <aside className="reservation-box">
            <div className="big-price">
              {money(l.price)}
              <span> / month</span>
            </div>
            <p className="muted">{l.roomType} · USD monthly asking rent</p>
            <div className="availability">
              <CalendarDays size={18} />
              <span>
                <small>AVAILABLE</small>
                {date(l.startDate)} – {date(l.endDate)}, {l.endDate.slice(0, 4)}
              </span>
            </div>
            {l.ownerId === user?.id ? (
              <div className="notice">
                This is your listing. Manage incoming requests in your inbox.
              </div>
            ) : (
              <>
                <button
                  className="primary full"
                  onClick={() => action("reserve")}
                >
                  Request at asking price <ArrowRight size={17} />
                </button>
                <button
                  className="outline full"
                  onClick={() => action("offer")}
                >
                  Make an offer
                </button>
                <button
                  className="text-button full"
                  onClick={() => action("message")}
                >
                  <MessageCircle size={16} /> Message {l.hostName.split(" ")[0]}
                </button>
                <small className="reservation-note">
                  No charge to send a request. Host acceptance, required
                  approvals, and an agreement come first.
                </small>
              </>
            )}
            {user?.id !== l.ownerId && (
              <button
                className="text-button full muted"
                onClick={() => action("report")}
              >
                Report this listing
              </button>
            )}
            {mode && (
              <form
                className="inline-form"
                onSubmit={(e) => {
                  e.preventDefault();
                  send();
                }}
              >
                <h3>
                  {mode === "report"
                    ? "Tell us what concerns you"
                    : mode === "message"
                      ? "Say hello"
                      : mode === "offer"
                        ? "Make it work for you"
                        : "Request these dates"}
                </h3>
                {mode === "message" || mode === "report" ? (
                  <label>
                    {mode === "report" ? "Report reason" : "Your message"}
                    <textarea
                      value={message}
                      onChange={(e) => setMessage(e.target.value)}
                      required
                      maxLength={2000}
                      placeholder="Hi! Is your place still available?"
                    />
                  </label>
                ) : (
                  <>
                    <label>
                      Monthly offer (USD)
                      <input
                        type="number"
                        min="1"
                        max="20000"
                        step="1"
                        required
                        value={amount}
                        disabled={mode === "reserve"}
                        onChange={(e) => setAmount(Number(e.target.value))}
                      />
                    </label>
                    <label>
                      Move in
                      <input
                        type="date"
                        value={start}
                        min={l.startDate}
                        max={l.endDate}
                        required
                        onChange={(e) => setStart(e.target.value)}
                      />
                    </label>
                    <label>
                      Move out
                      <input
                        type="date"
                        value={end}
                        min={start}
                        max={l.endDate}
                        required
                        onChange={(e) => setEnd(e.target.value)}
                      />
                    </label>
                  </>
                )}
                <ErrorBox message={error} />
                <button className="primary full" disabled={busy}>
                  {busy
                    ? "Sending…"
                    : mode === "report"
                      ? "Submit report"
                      : mode === "message"
                        ? "Send message"
                        : "Send request"}
                </button>
                <button
                  type="button"
                  className="text-button full"
                  onClick={() => setMode("")}
                >
                  Cancel
                </button>
              </form>
            )}
            {demo && (
              <div className="mini-note">
                <ShieldCheck size={14} /> Local preview. Payments and agreements
                are simulated.
              </div>
            )}
          </aside>
        </div>
      </div>
    </Modal>
  );
}
