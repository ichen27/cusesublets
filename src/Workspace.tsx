import { isPaymentComplete } from "./booking-state";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import {
  Plus,
  MessageCircle,
  ArrowRight,
  LogOut,
  ShieldCheck,
  FileText,
  Send,
  Check,
  CalendarDays,
} from "lucide-react";
import type {
  Listing,
  User,
  Message,
  Offer,
  Booking,
  DocumentRecord,
} from "../shared/types";
import { api, money, date } from "./api";
import { Busy, Empty, ErrorBox } from "./ui";
type BookingView = Booking & {
  payoutEligible?: boolean;
  payoutBlockers?: string[];
  totalCents?: number;
};
export default function Workspace({
  view,
  user,
  demo,
  notify,
  onSelect,
  onPost,
  onLogout,
}: {
  view: string;
  user: User;
  demo: boolean;
  notify: (s: string) => void;
  onSelect: (l: Listing) => void;
  onPost: () => void;
  onLogout: () => void;
}) {
  const [tab, setTab] = useState("messages"),
    [messages, setMessages] = useState<Message[]>([]),
    [listings, setListings] = useState<Listing[]>([]),
    [mine, setMine] = useState<Listing[]>([]),
    [offers, setOffers] = useState<Offer[]>([]),
    [bookings, setBookings] = useState<BookingView[]>([]),
    [documents, setDocuments] = useState<DocumentRecord[]>([]),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [thread, setThread] = useState(""),
    [reply, setReply] = useState("");
  const refresh = useCallback(async () => {
    try {
      const [m, o, b, l] = await Promise.all([
        api<{ messages: Message[]; listings: Listing[] }>("/messages"),
        api<{ offers: Offer[] }>("/offers"),
        api<{ bookings: BookingView[] }>("/bookings"),
        api<{ listings: Listing[]; documents: DocumentRecord[] }>("/mine"),
      ]);
      setMessages(m.messages);
      setListings(m.listings);
      setOffers(o.offers);
      setBookings(b.bookings);
      setMine(l.listings);
      setDocuments(l.documents);
      setError("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [user.id]);
  useEffect(() => {
    refresh();
    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") refresh();
    }, 10000);
    const onFocus = () => {
      refresh();
    };
    window.addEventListener("focus", onFocus);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", onFocus);
    };
  }, [refresh]);
  const threads = Array.from(
    new Set(
      messages.map(
        (m) =>
          `${m.listingId}|${m.senderId === user.id ? m.recipientId : m.senderId}`,
      ),
    ),
  );
  const active = thread || threads[0] || "";
  const [lid, peer] = active.split("|");
  const conversation = messages.filter(
    (m) =>
      m.listingId === lid && (m.senderId === peer || m.recipientId === peer),
  );
  async function act(fn: () => Promise<unknown>, success: string) {
    setBusy(true);
    setError("");
    try {
      await fn();
      notify(success);
      await refresh();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function upload(e: FormEvent<HTMLFormElement>, id: string) {
    e.preventDefault();
    const data = new FormData(e.currentTarget);
    await act(
      () => api(`/listings/${id}/documents`, data),
      "Document uploaded. Review is pending.",
    );
  }
  return (
    <main className="workspace">
      <div className="workspace-heading">
        <div>
          <span className="eyebrow">YOUR CUSESUBLETS</span>
          <h1>
            {view === "account"
              ? `Hey, ${user.name.split(" ")[0]}.`
              : "Good conversations. Better handoffs."}
          </h1>
          <p>
            {view === "account"
              ? "Your places, your profile, and your next steps."
              : "Keep the details, decisions, and next steps together."}
          </p>
        </div>
        {view === "account" ? (
          <button className="outline" onClick={onLogout}>
            <LogOut size={15} /> Log out
          </button>
        ) : (
          <MessageCircle size={34} />
        )}
      </div>
      {user.suspended && (
        <div className="notice">
          Your account is suspended. Existing reservations and issue reporting
          remain accessible; contact the review team to resolve your account
          status.
        </div>
      )}
      <ErrorBox message={error} />
      {loading ? (
        <Busy />
      ) : view === "account" ? (
        <div className="account-layout">
          <aside className="panel profile-card">
            <span className="avatar large">{user.name[0]}</span>
            <h2>{user.name}</h2>
            <p>{user.email}</p>
            <span className={"status " + user.identity}>
              {user.identity === "verified"
                ? "Identity checked"
                : "Identity review pending"}
            </span>
            <p className="muted">
              {demo
                ? "This is a demo profile. Verification states are illustrative."
                : "Identity verification will be completed with the configured provider."}
            </p>
            <div className="notice">
              Your lease and permission to sublet are reviewed for each listing
              separately.
            </div>
          </aside>
          <section>
            <div className="section-heading">
              <h2>Your listings</h2>
              <button className="primary small" onClick={onPost}>
                <Plus size={16} /> List a place
              </button>
            </div>
            {mine.length ? (
              mine.map((l) => (
                <div className="panel my-listing" key={l.id}>
                  <div className="my-listing-heading">
                    <img
                      src={l.images[0] || "/photo-pending.svg"}
                      alt={l.title}
                    />
                    <div>
                      <span className={"status " + l.status}>
                        {l.status.replace("_", " ")}
                      </span>
                      <h3>{l.title}</h3>
                      <p>
                        {money(l.price)} / month · {l.neighborhood}
                      </p>
                      <button
                        className="text-button"
                        onClick={() => onSelect(l)}
                      >
                        View listing <ArrowRight size={13} />
                      </button>
                    </div>
                  </div>
                  {l.reviewNote && (
                    <div className="notice">Reviewer note: {l.reviewNote}</div>
                  )}
                  <div className="review-statuses">
                    <span>
                      Lease: <b>{l.leaseStatus.replace("_", " ")}</b>
                    </span>
                    <span>
                      Permission: <b>{l.permissionStatus.replace("_", " ")}</b>
                    </span>
                  </div>
                  <div className="document-links">
                    {documents
                      .filter((d) => d.listingId === l.id)
                      .map((d) => (
                        <a
                          href={`/api/documents/${d.id}`}
                          key={d.id}
                          target="_blank"
                          rel="noreferrer"
                        >
                          <FileText size={14} />
                          {d.name}
                        </a>
                      ))}
                  </div>
                  <form
                    className="document-upload"
                    onSubmit={(e) => upload(e, l.id)}
                  >
                    <select name="kind" aria-label="Document type">
                      <option value="lease">Lease</option>
                      <option value="permission">Sublet permission</option>
                    </select>
                    <input
                      type="file"
                      name="file"
                      aria-label="Upload review document"
                      accept="application/pdf,image/jpeg,image/png"
                      required
                    />
                    <button className="outline small" disabled={busy}>
                      Upload
                    </button>
                  </form>
                </div>
              ))
            ) : (
              <Empty title="A new chapter for your place.">
                Going abroad or heading home? Give your place a thoughtful
                handoff.
              </Empty>
            )}
          </section>
        </div>
      ) : (
        <>
          <div className="tabs">
            <button
              className={tab === "messages" ? "active" : ""}
              onClick={() => setTab("messages")}
            >
              Messages <span>{threads.length}</span>
            </button>
            <button
              className={tab === "offers" ? "active" : ""}
              onClick={() => setTab("offers")}
            >
              Offers <span>{offers.length}</span>
            </button>
            <button
              className={tab === "bookings" ? "active" : ""}
              onClick={() => setTab("bookings")}
            >
              Reservations <span>{bookings.length}</span>
            </button>
          </div>
          {tab === "messages" ? (
            threads.length ? (
              <div className="inbox-layout panel">
                <aside className="thread-list">
                  {threads.map((t) => {
                    const [id, p] = t.split("|");
                    const l = listings.find((l) => l.id === id);
                    const last = messages
                      .filter(
                        (m) =>
                          m.listingId === id &&
                          (m.senderId === p || m.recipientId === p),
                      )
                      .at(-1);
                    return (
                      <button
                        key={t}
                        className={active === t ? "active" : ""}
                        onClick={() => setThread(t)}
                      >
                        <span className="avatar">{l?.hostName[0] || "C"}</span>
                        <span>
                          <b>{l?.title || "Listing conversation"}</b>
                          <small>{last?.body}</small>
                        </span>
                      </button>
                    );
                  })}
                </aside>
                <section className="conversation">
                  <div className="conversation-heading">
                    <h3>
                      {listings.find((l) => l.id === lid)?.title ||
                        "Your conversation"}
                    </h3>
                    <small>
                      Keep important details here for a clear record.
                    </small>
                  </div>
                  <div className="message-list">
                    {conversation.map((m) => (
                      <div
                        key={m.id}
                        className={
                          "message " +
                          (m.senderId === user.id ? "outgoing" : "")
                        }
                      >
                        <p>{m.body}</p>
                        <small>
                          {m.senderId === user.id ? "You" : "Other participant"}{" "}
                          ·{" "}
                          {new Date(m.createdAt).toLocaleTimeString("en-US", {
                            hour: "numeric",
                            minute: "2-digit",
                          })}
                        </small>
                      </div>
                    ))}
                  </div>
                  <form
                    className="message-form"
                    onSubmit={(e) => {
                      e.preventDefault();
                      act(async () => {
                        await api("/messages", {
                          listingId: lid,
                          recipientId: peer,
                          body: reply,
                        });
                        setReply("");
                      }, "Message sent.");
                    }}
                  >
                    <input
                      aria-label="Your reply"
                      value={reply}
                      onChange={(e) => setReply(e.target.value)}
                      placeholder="Write a thoughtful hello…"
                      required
                      maxLength={2000}
                    />
                    <button
                      className="primary"
                      disabled={busy}
                      aria-label="Send reply"
                    >
                      <Send size={18} />
                    </button>
                  </form>
                </section>
              </div>
            ) : (
              <Empty title="Your next conversation starts with a place.">
                Open a listing and message the host to get things going.
              </Empty>
            )
          ) : tab === "offers" ? (
            offers.length ? (
              <div className="offer-list">
                {offers.map((o) => (
                  <article className="panel offer-card" key={o.id}>
                    <div>
                      <span className={"status " + o.status}>{o.status}</span>
                      <h3>{o.listingTitle || "Sublease offer"}</h3>
                      <p>
                        {date(o.startDate)} – {date(o.endDate)} ·{" "}
                        {o.buyerId === user.id
                          ? "Your request"
                          : o.buyerName || "Renter request"}
                      </p>
                    </div>
                    <div className="offer-price">
                      <b>{money(o.amount)}</b>
                      <small>/ month</small>
                      {o.sellerId === user.id && o.status === "pending" && (
                        <button
                          className="primary small"
                          disabled={busy}
                          onClick={() =>
                            act(async () => {
                              await api(`/offers/${o.id}/accept`, {});
                              setTab("bookings");
                            }, "Offer accepted. Continue with the agreement.")
                          }
                        >
                          Accept offer <Check size={15} />
                        </button>
                      )}
                    </div>
                  </article>
                ))}
              </div>
            ) : (
              <Empty title="Find the right fit, then make an offer.">
                Your requests and incoming offers will show up here.
              </Empty>
            )
          ) : bookings.length ? (
            <div className="booking-list">
              {bookings.map((b) => (
                <article className="panel booking-card" key={b.id}>
                  <div className="section-heading">
                    <div>
                      <span className={"status " + b.status}>
                        {b.status.replaceAll("_", " ")}
                      </span>
                      <h3>{b.listingTitle || "Your reservation"}</h3>
                      <p>
                        {money(b.amount)} / month · {date(b.startDate)} –{" "}
                        {date(b.endDate)}
                      </p>
                    </div>
                    <CalendarDays />
                  </div>
                  <div className="booking-timeline">
                    {[
                      ["Agreement", b.buyerSigned && b.sellerSigned],
                      ["Payment", isPaymentComplete(b.paymentStatus)],
                      ["Move-in", !!b.moveInAt],
                      ["Release eligible", !!b.payoutEligible],
                    ].map(([t, done], i) => (
                      <div key={String(t)} className={done ? "done" : ""}>
                        <span>{done ? <Check size={15} /> : i + 1}</span>
                        <small>{t}</small>
                      </div>
                    ))}
                  </div>
                  <div className="notice">
                    {demo
                      ? "Sandbox reservation: acknowledgments and payments are simulated. No legally binding e-signature or real charge is created."
                      : "Complete the required agreement and payment steps before move-in."}
                  </div>
                  {b.totalCents !== undefined && (
                    <p className="muted" style={{ marginTop: 15 }}>
                      Sample stay total: <b>{money(b.totalCents / 100)}</b> ·
                      Monthly rent prorated using 30-day months. No real charge.
                    </p>
                  )}
                  <div className="booking-info">
                    <span>
                      Renter acknowledgment:{" "}
                      {b.buyerSigned ? "Complete" : "Pending"}
                    </span>
                    <span>
                      Host acknowledgment:{" "}
                      {b.sellerSigned ? "Complete" : "Pending"}
                    </span>
                    <span>Payment: {b.paymentStatus.replaceAll("_", " ")}</span>
                    <span>Dispute: {b.disputeStatus}</span>
                  </div>
                  {b.payoutBlockers?.length ? (
                    <p className="muted">
                      Release waiting on: {b.payoutBlockers.join(", ")}
                    </p>
                  ) : null}
                  <div className="button-row wrap">
                    {!(b.buyerId === user.id
                      ? b.buyerSigned
                      : b.sellerSigned) && (
                      <button
                        disabled={busy}
                        className="outline"
                        onClick={() =>
                          act(
                            () =>
                              api(`/bookings/${b.id}/action`, {
                                action: "sign",
                              }),
                            "Acknowledgment recorded.",
                          )
                        }
                      >
                        {demo
                          ? "Acknowledge demo agreement"
                          : "Review agreement"}
                      </button>
                    )}
                    {b.buyerId === user.id && (
                      <>
                        {!isPaymentComplete(b.paymentStatus) && (
                          <button
                            className="primary"
                            disabled={busy || !b.buyerSigned || !b.sellerSigned}
                            onClick={() =>
                              act(
                                () =>
                                  api(`/bookings/${b.id}/action`, {
                                    action: "pay",
                                  }),
                                "Sandbox payment recorded. No money was charged.",
                              )
                            }
                          >
                            {demo ? "Simulate payment" : "Continue to payment"}
                          </button>
                        )}
                        {isPaymentComplete(b.paymentStatus) && !b.moveInAt && (
                          <button
                            className="outline"
                            disabled={busy}
                            onClick={() =>
                              act(
                                () =>
                                  api(`/bookings/${b.id}/action`, {
                                    action: "confirm-move-in",
                                  }),
                                "Move-in recorded. The review window has started.",
                              )
                            }
                          >
                            Confirm move-in
                          </button>
                        )}
                        {b.disputeStatus !== "open" && (
                          <button
                            className="text-button"
                            disabled={busy}
                            onClick={() => {
                              const reason = prompt(
                                "Describe the issue for the review team.",
                              );
                              if (reason)
                                act(
                                  () =>
                                    api(`/bookings/${b.id}/action`, {
                                      action: "dispute",
                                      reason,
                                    }),
                                  "Issue reported. Payout release is blocked pending review.",
                                );
                            }}
                          >
                            Report an issue
                          </button>
                        )}
                      </>
                    )}
                  </div>
                </article>
              ))}
            </div>
          ) : (
            <Empty title="A clear path to your next place.">
              Accepted offers become reservations. Your agreement, payment, and
              move-in steps will live here.
            </Empty>
          )}
        </>
      )}
    </main>
  );
}
