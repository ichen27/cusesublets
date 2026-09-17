import { useCallback, useEffect, useRef, useState } from "react";
import {
  ArrowUpRight,
  FileText,
  Send,
  MessageCircle,
  Paperclip,
} from "lucide-react";
import type {
  ConversationDetail,
  ConversationSummary,
  Listing,
  Offer,
  User,
} from "../shared/types";
import { api, money, date, syracuseToday } from "./api";
import { isPaymentComplete } from "./booking-state";
import { Busy, Empty, ErrorBox } from "./ui";
export type ChatIntent = "message" | "offer" | "request";
export default function ChatWorkspace({
  user,
  demo,
  activeId,
  intent,
  onOpen,
  onSelect,
}: {
  user: User;
  demo: boolean;
  activeId: string;
  intent: ChatIntent;
  onOpen: (id: string) => void;
  onSelect: (l: Listing) => void;
}) {
  const [threads, setThreads] = useState<ConversationSummary[]>([]),
    [detail, setDetail] = useState<ConversationDetail | null>(null);
  const [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [reply, setReply] = useState("");
  const [mode, setMode] = useState<ChatIntent>(intent),
    [parent, setParent] = useState<Offer | null>(null),
    [amount, setAmount] = useState(0),
    [start, setStart] = useState(""),
    [end, setEnd] = useState("");
  const generation = useRef(0),
    timelineRef = useRef<HTMLDivElement>(null),
    activeRef = useRef(activeId);
  activeRef.current = activeId;
  const refresh = useCallback(async () => {
    if (activeRef.current !== activeId) return;
    const current = ++generation.current;
    try {
      const [list, thread] = await Promise.all([
        api<{ conversations: ConversationSummary[] }>("/conversations"),
        activeId
          ? api<ConversationDetail>(`/conversations/${activeId}`)
          : Promise.resolve(null),
      ]);
      if (current !== generation.current) return;
      setThreads(list.conversations);
      setDetail(thread);
      setError("");
    } catch (e) {
      if (current === generation.current) setError((e as Error).message);
    } finally {
      if (current === generation.current) setLoading(false);
    }
  }, [activeId, user.id]);
  useEffect(() => {
    setDetail(null);
    setLoading(true);
    setReply("");
    setParent(null);
    setMode(intent);
    refresh();
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") refresh();
    }, 8000);
    return () => {
      clearInterval(timer);
      generation.current++;
    };
  }, [refresh, intent]);
  useEffect(() => {
    if (!detail) return;
    setAmount(detail.listing.price);
    setStart(
      detail.listing.startDate > syracuseToday()
        ? detail.listing.startDate
        : syracuseToday(),
    );
    setEnd(detail.listing.endDate);
  }, [detail?.conversation.id]);
  useEffect(() => {
    if (timelineRef.current)
      timelineRef.current.scrollTop = timelineRef.current.scrollHeight;
  }, [
    detail?.messages.length,
    detail?.offers.length,
    detail?.attachments.length,
  ]);
  async function act(fn: () => Promise<unknown>) {
    setBusy(true);
    setError("");
    try {
      await fn();
      if (activeRef.current === activeId) await refresh();
    } catch (e) {
      if (activeRef.current === activeId) setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  function proposal(kind: ChatIntent, o?: Offer) {
    setMode(kind);
    setParent(o || null);
    if (detail) {
      setAmount(o?.amount ?? detail.listing.price);
      setStart(
        o?.startDate ??
          (detail.listing.startDate > syracuseToday()
            ? detail.listing.startDate
            : syracuseToday()),
      );
      setEnd(o?.endDate ?? detail.listing.endDate);
    }
  }
  const timeline = detail
    ? [
        ...detail.messages.map((value) => ({
          type: "message" as const,
          value,
        })),
        ...detail.offers.map((value) => ({ type: "offer" as const, value })),
        ...detail.attachments.map((value) => ({
          type: "document" as const,
          value,
        })),
        ...detail.events
          .filter((e) => !e.offerId && e.kind !== "document")
          .map((value) => ({ type: "event" as const, value })),
      ].sort(
        (a, b) =>
          a.value.createdAt.localeCompare(b.value.createdAt) ||
          a.value.id.localeCompare(b.value.id),
      )
    : [];
  return (
    <main className="workspace chat-workspace">
      <div className="workspace-heading">
        <div>
          <span className="eyebrow">YOUR CONVERSATIONS</span>
          <h1>Every detail. One conversation.</h1>
          <p>
            Meet your host or renter, agree on terms, and keep your handoff
            together.
          </p>
        </div>
        <MessageCircle size={32} />
      </div>
      <ErrorBox message={error} />
      <div className="chat-shell">
        <aside className="chat-threads">
          <h2>
            Messages <span>{threads.length}</span>
          </h2>
          {threads.map((t) => (
            <button
              key={t.id}
              className={t.id === activeId ? "active" : ""}
              onClick={() => onOpen(t.id)}
            >
              <img src={t.listingImage || "/photo-pending.svg"} alt="" />
              <span>
                <b>{t.peerName}</b>
                <strong>{t.listingTitle}</strong>
                <small>{t.lastMessage || "Start the conversation"}</small>
              </span>
            </button>
          ))}
          {!loading && !threads.length && (
            <p className="muted">Open a listing and choose Message to start.</p>
          )}
        </aside>
        {loading ? (
          <Busy />
        ) : !detail ? (
          <Empty title="A place to work out the details.">
            Choose a conversation, or message a host from their listing.
          </Empty>
        ) : (
          <>
            <section className="chat-main">
              <div className="chat-heading">
                <span className="avatar">{detail.peer.name[0]}</span>
                <div>
                  <h2>{detail.peer.name}</h2>
                  <p>{detail.listing.title}</p>
                </div>
              </div>
              <div
                className="chat-timeline"
                aria-live="polite"
                ref={timelineRef}
              >
                {!timeline.length && (
                  <div className="chat-welcome">
                    <MessageCircle />
                    <h3>Start with a hello.</h3>
                    <p>
                      Ask about the place, share your dates, or send an offer
                      below.
                    </p>
                  </div>
                )}
                {timeline.map((item) =>
                  item.type === "message" ? (
                    <div
                      className={
                        "chat-bubble " +
                        (item.value.senderId === user.id ? "outgoing" : "")
                      }
                      key={item.value.id}
                    >
                      <p>{item.value.body}</p>
                      <small>
                        {item.value.senderId === user.id
                          ? "You"
                          : detail.peer.name}{" "}
                        · {new Date(item.value.createdAt).toLocaleString()}
                      </small>
                    </div>
                  ) : item.type === "document" ? (
                    <div className="chat-activity" key={item.value.id}>
                      <FileText size={19} />
                      <div>
                        <b>
                          {item.value.senderId === user.id
                            ? "You"
                            : detail.peer.name}{" "}
                          shared a document
                        </b>
                        <a
                          href={`/api/chat-documents/${item.value.id}`}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {item.value.name} <ArrowUpRight size={13} />
                        </a>
                        <small>
                          {Math.ceil(item.value.size / 1024)} KB ·{" "}
                          {new Date(item.value.createdAt).toLocaleString()}
                        </small>
                      </div>
                    </div>
                  ) : item.type === "event" ? (
                    <div className="chat-event" key={item.value.id}>
                      {item.value.body}
                    </div>
                  ) : (
                    <article className="chat-offer" key={item.value.id}>
                      <div className="section-heading">
                        <b>
                          {item.value.parentOfferId
                            ? "Counteroffer"
                            : item.value.kind === "request"
                              ? "Reservation request"
                              : "Offer"}{" "}
                          from{" "}
                          {item.value.proposedBy === user.id
                            ? "you"
                            : detail.peer.name}
                        </b>
                        <span className={"status " + item.value.status}>
                          {item.value.status}
                        </span>
                      </div>
                      <h3>
                        {money(item.value.amount)} <small>/ month</small>
                      </h3>
                      <p>
                        {date(item.value.startDate)} –{" "}
                        {date(item.value.endDate)},{" "}
                        {item.value.endDate.slice(0, 4)}
                      </p>
                      {item.value.status === "pending" && (
                        <div className="button-row wrap">
                          {item.value.proposedBy !== user.id ? (
                            <>
                              <button
                                className="primary small"
                                disabled={busy}
                                onClick={() =>
                                  act(() =>
                                    api(`/offers/${item.value.id}/accept`, {}),
                                  )
                                }
                              >
                                Accept{" "}
                                {item.value.parentOfferId
                                  ? "counteroffer"
                                  : "offer"}
                              </button>
                              <button
                                className="outline small"
                                disabled={busy}
                                onClick={() => proposal("offer", item.value)}
                              >
                                Counteroffer
                              </button>
                              <button
                                className="text-button"
                                disabled={busy}
                                onClick={() =>
                                  act(() =>
                                    api(`/offers/${item.value.id}/decline`, {}),
                                  )
                                }
                              >
                                Decline
                              </button>
                            </>
                          ) : (
                            <button
                              className="text-button"
                              disabled={busy}
                              onClick={() =>
                                act(() =>
                                  api(`/offers/${item.value.id}/withdraw`, {}),
                                )
                              }
                            >
                              Withdraw
                            </button>
                          )}
                        </div>
                      )}
                      <small>
                        No payment is taken by sending or accepting an offer.
                      </small>
                    </article>
                  ),
                )}
              </div>
              <div className="chat-compose">
                <div className="chat-tools">
                  <button
                    className={mode === "message" ? "active" : ""}
                    onClick={() => setMode("message")}
                  >
                    Message
                  </button>
                  {user.id === detail.conversation.buyerId && (
                    <>
                      <button
                        className={mode === "offer" ? "active" : ""}
                        onClick={() => proposal("offer")}
                      >
                        Make an offer
                      </button>
                      <button
                        className={mode === "request" ? "active" : ""}
                        onClick={() => proposal("request")}
                      >
                        Request dates
                      </button>
                    </>
                  )}
                  <label className="chat-file">
                    <Paperclip size={15} /> Share document
                    <input
                      type="file"
                      accept="application/pdf,image/jpeg,image/png"
                      disabled={busy}
                      onChange={(e) => {
                        const file = e.target.files?.[0];
                        if (!file) return;
                        e.target.value = "";
                        if (file.size > 5 * 1024 * 1024) {
                          setError("Choose a document smaller than 5 MB.");
                          return;
                        }
                        const body = new FormData();
                        body.append("file", file);
                        act(() =>
                          api(`/conversations/${activeId}/documents`, body),
                        );
                      }}
                    />
                  </label>
                </div>
                {mode === "message" ? (
                  <form
                    className="message-form"
                    onSubmit={(e) => {
                      e.preventDefault();
                      act(async () => {
                        await api(`/conversations/${activeId}/messages`, {
                          body: reply,
                        });
                        if (activeRef.current === activeId) setReply("");
                      });
                    }}
                  >
                    <textarea
                      aria-label="Your message"
                      value={reply}
                      onChange={(e) => setReply(e.target.value)}
                      placeholder="Ask a question or share an update…"
                      required
                      maxLength={2000}
                    />
                    <button
                      className="primary"
                      disabled={busy || !reply.trim()}
                      aria-label="Send message"
                    >
                      <Send size={18} />
                    </button>
                  </form>
                ) : (
                  <form
                    className="chat-proposal"
                    onSubmit={(e) => {
                      e.preventDefault();
                      act(async () => {
                        await api(`/conversations/${activeId}/offers`, {
                          amount,
                          startDate: start,
                          endDate: end,
                          parentOfferId: parent?.id,
                          kind: mode === "request" ? "request" : "offer",
                        });
                        if (activeRef.current === activeId) {
                          setMode("message");
                          setParent(null);
                        }
                      });
                    }}
                  >
                    <h3>
                      {parent
                        ? "Send a counteroffer"
                        : mode === "request"
                          ? "Request at asking price"
                          : "Make an offer"}
                    </h3>
                    <div className="chat-fields">
                      <label>
                        Monthly rent (USD)
                        <input
                          type="number"
                          min="1"
                          max="20000"
                          required
                          value={amount}
                          disabled={mode === "request"}
                          onChange={(e) => setAmount(Number(e.target.value))}
                        />
                      </label>
                      <label>
                        Move in
                        <input
                          type="date"
                          required
                          min={
                            detail.listing.startDate > syracuseToday()
                              ? detail.listing.startDate
                              : syracuseToday()
                          }
                          max={detail.listing.endDate}
                          value={start}
                          onChange={(e) => setStart(e.target.value)}
                        />
                      </label>
                      <label>
                        Move out
                        <input
                          type="date"
                          required
                          min={start}
                          max={detail.listing.endDate}
                          value={end}
                          onChange={(e) => setEnd(e.target.value)}
                        />
                      </label>
                    </div>
                    <div className="button-row">
                      <button
                        type="button"
                        className="text-button"
                        onClick={() => setMode("message")}
                      >
                        Cancel
                      </button>
                      <button className="primary small" disabled={busy}>
                        Send{" "}
                        {parent
                          ? "counteroffer"
                          : mode === "request"
                            ? "request"
                            : "offer"}
                      </button>
                    </div>
                  </form>
                )}
                <small className="chat-privacy">
                  Documents you share here are visible to this conversation’s
                  participants. PDF, JPG or PNG · up to 5 MB.
                </small>
              </div>
            </section>
            <aside className="chat-property">
              <img
                className="chat-property-photo"
                src={detail.listing.images[0] || "/photo-pending.svg"}
                alt={detail.listing.title}
              />
              <span className="eyebrow">THE PLACE</span>
              <h2>{detail.listing.title}</h2>
              <p>
                {detail.listing.neighborhood} · {detail.listing.roomType}
              </p>
              <h3>
                {money(detail.listing.price)} <small>/ month</small>
              </h3>
              <p>
                {date(detail.listing.startDate)} –{" "}
                {date(detail.listing.endDate)}
              </p>
              <p>
                {detail.listing.beds} bed · {detail.listing.baths} bath ·{" "}
                {detail.listing.walkMinutes} min to SU
              </p>
              <a
                href={`#listing/${encodeURIComponent(detail.listing.id)}`}
                className="outline full"
                onClick={(e) => {
                  e.preventDefault();
                  onSelect(detail.listing);
                }}
              >
                View listing <ArrowUpRight size={15} />
              </a>
              <div className="chat-checks">
                <b>Listing checks</b>
                <p>
                  Identity: {detail.listing.hostIdentity.replaceAll("_", " ")}
                </p>
                <p>Lease: {detail.listing.leaseStatus.replaceAll("_", " ")}</p>
                <p>
                  Sublet permission:{" "}
                  {detail.listing.permissionStatus.replaceAll("_", " ")}
                </p>
              </div>
              <div className="chat-next">
                <h3>Your next steps</h3>
                {!detail.bookings.length && (
                  <p>
                    Agree on an offer first. Your reservation steps will appear
                    here.
                  </p>
                )}
                {detail.bookings.map((b) => (
                  <div className="chat-reservation" key={b.id}>
                    <span className={"status " + b.status}>
                      {b.status.replaceAll("_", " ")}
                    </span>
                    <p>
                      {money(b.amount)} / month
                      <br />
                      {date(b.startDate)} – {date(b.endDate)}
                    </p>
                    <p>
                      Renter acknowledgment:{" "}
                      {b.buyerSigned ? "Complete" : "Pending"}
                      <br />
                      Host acknowledgment:{" "}
                      {b.sellerSigned ? "Complete" : "Pending"}
                      <br />
                      Payment: {b.paymentStatus.replaceAll("_", " ")}
                      <br />
                      Dispute: {b.disputeStatus}
                    </p>
                    {b.disputeStatus === "open" && (
                      <div className="notice">
                        Issue under review. Payout is blocked.
                        {b.disputeReason && <p>{b.disputeReason}</p>}
                      </div>
                    )}
                    {b.payoutBlockers?.length ? (
                      <p>Release waiting on: {b.payoutBlockers.join(", ")}</p>
                    ) : null}
                    {demo && (
                      <>
                        <button
                          className="outline full small"
                          disabled={
                            busy ||
                            (b.buyerId === user.id
                              ? b.buyerSigned
                              : b.sellerSigned)
                          }
                          onClick={() =>
                            act(() =>
                              api(`/bookings/${b.id}/action`, {
                                action: "sign",
                              }),
                            )
                          }
                        >
                          Acknowledge demo agreement
                        </button>
                        {b.buyerId === user.id && (
                          <button
                            className="primary full small"
                            disabled={
                              busy ||
                              !b.buyerSigned ||
                              !b.sellerSigned ||
                              b.paymentStatus !== "unpaid"
                            }
                            onClick={() =>
                              act(() =>
                                api(`/bookings/${b.id}/action`, {
                                  action: "pay",
                                }),
                              )
                            }
                          >
                            Simulate payment
                          </button>
                        )}
                      </>
                    )}
                    {b.buyerId === user.id && (
                      <>
                        {isPaymentComplete(b.paymentStatus) && !b.moveInAt && (
                          <button
                            className="outline full small"
                            disabled={busy}
                            onClick={() =>
                              act(() =>
                                api(`/bookings/${b.id}/action`, {
                                  action: "confirm-move-in",
                                }),
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
                                act(() =>
                                  api(`/bookings/${b.id}/action`, {
                                    action: "dispute",
                                    reason,
                                  }),
                                );
                            }}
                          >
                            Report an issue
                          </button>
                        )}
                      </>
                    )}
                  </div>
                ))}
                {!demo && (
                  <>
                    <button className="outline full small" disabled>
                      Document signing · coming soon
                    </button>
                    <button className="outline full small" disabled>
                      Payments · not enabled
                    </button>
                    <p className="muted">
                      You can share and review documents now. E-signatures and
                      Stripe payments still need provider setup.
                    </p>
                  </>
                )}
                {demo && (
                  <p className="muted">
                    Demo acknowledgments and payments are simulated. No legal
                    signature or charge.
                  </p>
                )}
              </div>
            </aside>
          </>
        )}
      </div>
    </main>
  );
}
