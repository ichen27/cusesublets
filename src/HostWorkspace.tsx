import { useCallback, useEffect, useState, type FormEvent } from "react";
import { Plus, ArrowRight, FileText, MessageCircle } from "lucide-react";
import type {
  Listing,
  User,
  DocumentRecord,
  ConversationSummary,
  Offer,
  Booking,
} from "../shared/types";
import { api, money } from "./api";
import { Busy, Empty, ErrorBox } from "./ui";
export default function HostWorkspace({
  user,
  onSelect,
  onPost,
  onOpen,
}: {
  user: User;
  onSelect: (l: Listing) => void;
  onPost: () => void;
  onOpen: (id: string) => void;
}) {
  const [mine, setMine] = useState<Listing[]>([]),
    [documents, setDocuments] = useState<DocumentRecord[]>([]),
    [conversations, setConversations] = useState<ConversationSummary[]>([]),
    [offers, setOffers] = useState<Offer[]>([]),
    [bookings, setBookings] = useState<Booking[]>([]),
    [loading, setLoading] = useState(true),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const refresh = useCallback(async () => {
    try {
      const [m, c, o, b] = await Promise.all([
        api<{ listings: Listing[]; documents: DocumentRecord[] }>("/mine"),
        api<{ conversations: ConversationSummary[] }>("/conversations"),
        api<{ offers: Offer[] }>("/offers"),
        api<{ bookings: Booking[] }>("/bookings"),
      ]);
      setMine(m.listings);
      setDocuments(m.documents);
      setConversations(c.conversations.filter((c) => c.sellerId === user.id));
      setOffers(o.offers.filter((o) => o.sellerId === user.id));
      setBookings(b.bookings.filter((b) => b.sellerId === user.id));
      setError("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [user.id]);
  useEffect(() => {
    refresh();
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") refresh();
    }, 10000);
    return () => clearInterval(timer);
  }, [refresh]);
  async function upload(e: FormEvent<HTMLFormElement>, id: string) {
    e.preventDefault();
    const body = new FormData(e.currentTarget);
    setBusy(true);
    try {
      await api(`/listings/${id}/documents`, body);
      await refresh();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="workspace">
      <div className="workspace-heading">
        <div>
          <span className="eyebrow">HOST WORKSPACE</span>
          <h1>My listings</h1>
          <p>Your places, incoming conversations, and next steps.</p>
        </div>
        <button className="primary" onClick={onPost}>
          <Plus size={16} /> List a place
        </button>
      </div>
      <ErrorBox message={error} />
      <div className="host-stats">
        <div>
          <b>{mine.length}</b>
          <span>Your listings</span>
        </div>
        <div>
          <b>
            {
              offers.filter(
                (o) => o.status === "pending" && o.proposedBy !== user.id,
              ).length
            }
          </b>
          <span>Offers to review</span>
        </div>
        <div>
          <b>{conversations.length}</b>
          <span>Conversations</span>
        </div>
        <div>
          <b>{bookings.length}</b>
          <span>Reservations</span>
        </div>
      </div>
      {loading ? (
        <Busy />
      ) : (
        <section className="host-listings">
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
                    <button className="text-button" onClick={() => onSelect(l)}>
                      View listing <ArrowRight size={13} />
                    </button>
                  </div>
                </div>
                <div className="host-conversations">
                  <h4>
                    <MessageCircle size={16} /> Conversations & requests
                  </h4>
                  {conversations
                    .filter((c) => c.listingId === l.id)
                    .map((c) => (
                      <button
                        className="host-thread"
                        key={c.id}
                        onClick={() => onOpen(c.id)}
                      >
                        <span>
                          <b>{c.peerName}</b>
                          <small>{c.lastMessage || "Open conversation"}</small>
                        </span>
                        <span>
                          {offers.filter(
                            (o) =>
                              o.conversationId === c.id &&
                              o.status === "pending" &&
                              o.proposedBy !== user.id,
                          ).length
                            ? "Offer to review"
                            : "Open chat"}{" "}
                          <ArrowRight size={14} />
                        </span>
                      </button>
                    ))}
                  {!conversations.some((c) => c.listingId === l.id) && (
                    <p className="muted">
                      Incoming messages and requests will appear here.
                    </p>
                  )}
                  {bookings
                    .filter((b) => b.listingId === l.id)
                    .map((b) => (
                      <p key={b.id}>
                        Reservation · {money(b.amount)} / month ·{" "}
                        {b.status.replaceAll("_", " ")}
                      </p>
                    ))}
                </div>
                <h4>Private review documents</h4>
                <p className="muted">
                  Only you and the review team can access these. Share documents
                  with a renter separately in chat.
                </p>
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
      )}
    </main>
  );
}
