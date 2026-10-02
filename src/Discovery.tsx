import { useCallback, useEffect, useMemo, useState } from "react";
import { ArrowRight, CalendarDays, Home, MapPin, MessageCircle, Plus, Sparkles, UserRound } from "lucide-react";
import type { Listing, SeekerRequest, User } from "../shared/types";
import { api, date, money, syracuseToday } from "./api";
import { Busy, Empty, ErrorBox, Modal } from "./ui";
import { IdentityBadge } from "./Checks";
import PostRequest from "./PostRequest";
import { matchListingToRequest } from "../shared/matching";

type Match = { score: number; reasons: string[]; listing?: Listing; request?: SeekerRequest };
type Filter = "all" | "apartments" | "requests";
function timeLabel(value?: string | null) {
  if (!value) return "Earlier listing";
  const days = Math.floor((Date.now() - Date.parse(value)) / 86400000);
  if (days < 1) return "Posted today";
  if (days === 1) return "Posted yesterday";
  return `Posted ${days} days ago`;
}
function Stay({ start, end }: { start: string; end: string }) {
  return <span className="post-stay"><CalendarDays size={14} /> {date(start)} – {date(end)}, {end.slice(0, 4)}</span>;
}
export default function Discovery({ mode, listings, user, onLogin, onPostListing, onListing, onListingChat, onProfile, onChat, notify }: {
  mode: "recent" | "matches";
  listings: Listing[];
  user: User | null;
  onLogin: () => void;
  onPostListing: () => void;
  onListing: (listing: Listing) => void;
  onListingChat: (listing: Listing) => void;
  onProfile: (id: string) => void;
  onChat: (id: string) => void;
  notify: (message: string) => void;
}) {
  const [requests, setRequests] = useState<SeekerRequest[]>([]);
  const [mine, setMine] = useState<SeekerRequest[]>([]);
  const [ownListings, setOwnListings] = useState<Listing[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [source, setSource] = useState("");
  const [matches, setMatches] = useState<Match[]>([]);
  const [matching, setMatching] = useState(false);
  const [post, setPost] = useState(false);
  const [editing, setEditing] = useState<SeekerRequest | null>(null);
  const [contact, setContact] = useState<SeekerRequest | null>(null);
  const [reporting, setReporting] = useState<SeekerRequest | null>(null);
  const [reportReason, setReportReason] = useState("");
  const [contactBusy, setContactBusy] = useState(false);
  const refresh = useCallback(async () => {
    try {
      const [publicData, myData, listingData] = await Promise.all([
        api<{ requests: SeekerRequest[] }>("/requests"),
        user ? api<{ requests: SeekerRequest[] }>("/requests/mine") : Promise.resolve({ requests: [] }),
        user ? api<{ listings: Listing[] }>("/mine") : Promise.resolve({ listings: [] }),
      ]);
      setRequests(publicData.requests);
      setMine(myData.requests);
      setOwnListings(listingData.listings);
      setError("");
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setLoading(false);
    }
  }, [user?.id]);
  useEffect(() => {
    refresh();
    const timer = setInterval(() => { if (document.visibilityState === "visible") refresh(); }, 30000);
    const onFocus = () => refresh();
    window.addEventListener("focus", onFocus);
    return () => { clearInterval(timer); window.removeEventListener("focus", onFocus); };
  }, [refresh]);
  useEffect(() => {
    if (!user) { setSource(""); setMatches([]); return; }
    const options = [
      ...mine.filter((item) => item.status === "active").map((item) => `request:${item.id}`),
      ...ownListings.filter((item) => item.status === "approved").map((item) => `listing:${item.id}`),
    ];
    if (!options.includes(source)) setSource(options[0] || "");
  }, [mine, ownListings, user?.id, source]);
  useEffect(() => {
    if (mode !== "matches" || !source) { setMatches([]); return; }
    let active = true;
    const [sourceType, sourceId] = source.split(":");
    setMatching(true);
    api<{ matches: Match[] }>(`/matches?sourceType=${sourceType}&sourceId=${encodeURIComponent(sourceId)}`)
      .then((result) => { if (active) { setMatches(result.matches); setError(""); } })
      .catch((cause) => { if (active) setError((cause as Error).message); })
      .finally(() => { if (active) setMatching(false); });
    return () => { active = false; };
  }, [mode, source, requests, listings]);
  const posts = useMemo(() => {
    const combined = [
      ...listings.filter((listing) => listing.endDate > syracuseToday()).map((listing) => ({ kind: "apartment" as const, item: listing, createdAt: listing.createdAt || "" })),
      ...requests.map((request) => ({ kind: "request" as const, item: request, createdAt: request.createdAt })),
    ];
    return combined.filter((post) => filter === "all" || (filter === "apartments" ? post.kind === "apartment" : post.kind === "request"))
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }, [listings, requests, filter]);
  const availableHomes = ownListings.filter((listing) => listing.status === "approved");
  const fittingHomes = (request: SeekerRequest) => availableHomes.filter((listing) => matchListingToRequest(listing, request));
  async function changeStatus(request: SeekerRequest, status: "active" | "paused" | "closed") {
    try {
      await api(`/requests/${encodeURIComponent(request.id)}`, { status });
      await refresh();
      notify(status === "active" ? "Your request is visible again." : "Request updated.");
    } catch (cause) { notify((cause as Error).message); }
  }
  async function openRequestConversation(request: SeekerRequest, listing: Listing) {
    setContactBusy(true);
    try {
      const { conversation } = await api<{ conversation: { id: string } }>("/conversations", { listingId: listing.id, requestId: request.id });
      setContact(null); onChat(conversation.id);
    } catch (cause) { notify((cause as Error).message); }
    finally { setContactBusy(false); }
  }
  function respondToRequest(request: SeekerRequest) {
    if (!user) { onLogin(); return; }
    if (request.ownerId === user.id) return;
    if (!availableHomes.length) { notify("Publish a listing to respond to this request."); onPostListing(); return; }
    const homes = fittingHomes(request);
    if (!homes.length) { notify("Your published places do not cover this request’s dates, budget and room type."); return; }
    const selectedListing = mode === "matches" && source.startsWith("listing:")
      ? homes.find((item) => item.id === source.slice(8)) : null;
    if (selectedListing) { openRequestConversation(request, selectedListing); return; }
    if (homes.length === 1) { openRequestConversation(request, homes[0]); return; }
    setContact(request);
  }
  function RequestCard({ request, reasons }: { request: SeekerRequest; reasons?: string[] }) {
    return <article className="discovery-card request-card" key={request.id}>
      <div className="discovery-card-top"><span className="post-type seeker-type"><UserRound size={14} /> Looking for a sublet</span><span className="post-age">{timeLabel(request.createdAt)}</span></div>
      <h3>{request.title}</h3>
      <button className="post-person" onClick={() => onProfile(request.ownerId)}><span className="person-avatar">{request.ownerName.slice(0, 1).toUpperCase()}</span><span>{request.ownerName}</span>{request.ownerIdentity === "verified" && <IdentityBadge status={request.ownerIdentity} />}</button>
      <p className="post-description">{request.description}</p>
      <div className="post-facts"><Stay start={request.startDate} end={request.endDate} /><span><MapPin size={14} /> {request.neighborhood || "Flexible on area"}</span><span><b>Up to {money(request.maxBudget)}</b> / month</span><span>{request.roomType === "Any" ? "Flexible on room type" : request.roomType}</span></div>
      {request.amenities.length > 0 && <div className="post-tags">{request.amenities.map((item) => <span key={item}>{item}</span>)}</div>}
      {reasons && <div className="match-reasons">{reasons.map((reason) => <span key={reason}>✓ {reason}</span>)}</div>}
      <div className="discovery-card-actions"><button className="text-button" onClick={() => onProfile(request.ownerId)}>View profile <ArrowRight size={14} /></button>{request.ownerId !== user?.id && <div className="discovery-card-secondary"><button className="text-button report-link" onClick={() => user ? setReporting(request) : onLogin()}>Report post</button><button className="primary small" onClick={() => respondToRequest(request)}><MessageCircle size={15} /> Contact seeker</button></div>}</div>
    </article>;
  }
  function ApartmentCard({ listing, reasons }: { listing: Listing; reasons?: string[] }) {
    return <article className="discovery-card apartment-card" key={listing.id}>
      <div className="apartment-card-image"><img src={listing.images[0] || "/photo-pending.svg"} alt={listing.title} loading="lazy" /></div>
      <div className="apartment-card-content"><div className="discovery-card-top"><span className="post-type apartment-type"><Home size={14} /> Available sublet</span><span className="post-age">{timeLabel(listing.createdAt)}</span></div>
      <h3>{listing.title}</h3><button className="post-person" onClick={() => onProfile(listing.ownerId)}><span className="person-avatar">{listing.hostName.slice(0, 1).toUpperCase()}</span><span>{listing.hostName}</span>{listing.hostIdentity === "verified" && <IdentityBadge status={listing.hostIdentity} />}</button>
      <div className="post-facts"><Stay start={listing.startDate} end={listing.endDate} /><span><MapPin size={14} /> {listing.neighborhood}</span><span><b>{money(listing.price)}</b> / month</span><span>{listing.roomType}</span></div>
      {reasons && <div className="match-reasons">{reasons.map((reason) => <span key={reason}>✓ {reason}</span>)}</div>}
      <div className="discovery-card-actions"><button className="text-button" onClick={() => onListing(listing)}>View apartment <ArrowRight size={14} /></button>{listing.ownerId !== user?.id && <button className="primary small" onClick={() => user ? onListingChat(listing) : onLogin()}><MessageCircle size={15} /> Contact host</button>}</div></div>
    </article>;
  }
  return <main className="discovery-page">
    <section className="discovery-intro"><div><span className="eyebrow">CUSE​​SUB​​LETS · TWO SIDES, ONE MARKETPLACE</span><h1>{mode === "recent" ? <>See what’s <em>new.</em></> : <>Your <em>top matches.</em></>}</h1><p>{mode === "recent" ? "Browse places and people looking for a sublet in Syracuse. New posts from both sides appear here." : "Choose one of your posts to see fitting people or places. Every match explains why it appears."}</p></div><div className="discovery-intro-actions"><button className="primary" onClick={() => { if (user) { setEditing(null); setPost(true); } else onLogin(); }}><Plus size={16} /> Post what you need</button><button className="outline" onClick={() => user ? onPostListing() : onLogin()}><Home size={16} /> List your place</button></div></section>
    <ErrorBox message={error} />
    {loading ? <Busy /> : mode === "recent" ? <>
      {user && mine.length > 0 && <section className="my-requests"><div className="section-heading"><div><span className="eyebrow">YOUR SIDE OF THE MARKETPLACE</span><h2>My requests</h2></div></div><div className="my-request-list">{mine.map((request) => <div className="my-request" key={request.id}><div><b>{request.title}</b><span>{request.status === "active" && request.endDate <= syracuseToday() ? "Expired" : request.status === "active" ? "Public" : request.status === "paused" ? "Paused" : request.status === "closed" ? "Closed" : "Removed"} · {date(request.startDate)} – {date(request.endDate)}</span></div>{request.status !== "removed" && <div><button className="outline small" onClick={() => { setEditing(request); setPost(true); }}>Edit</button>{request.status === "active" ? <button className="outline small" onClick={() => changeStatus(request, "paused")}>Pause</button> : request.endDate > syracuseToday() ? <button className="outline small" onClick={() => changeStatus(request, "active")}>Repost</button> : null}{request.status !== "closed" && <button className="text-button" onClick={() => changeStatus(request, "closed")}>Close</button>}</div>}</div>)}</div></section>}
      <div className="discovery-list-heading"><div><span className="eyebrow">THE LATEST POSTS</span><h2>Recent activity</h2><p>{posts.length} {posts.length === 1 ? "post" : "posts"} to explore</p></div><div className="discovery-tabs" role="group" aria-label="Filter posts"><button className={filter === "all" ? "selected" : ""} onClick={() => setFilter("all")}>All posts</button><button className={filter === "apartments" ? "selected" : ""} onClick={() => setFilter("apartments")}>Apartments</button><button className={filter === "requests" ? "selected" : ""} onClick={() => setFilter("requests")}>Looking for</button></div></div>
      <div className="discovery-feed">{posts.length ? posts.map((post) => post.kind === "request" ? <RequestCard key={post.item.id} request={post.item} /> : <ApartmentCard key={post.item.id} listing={post.item} />) : <Empty title="No posts yet.">Start the conversation by posting a place or what you’re looking for.</Empty>}</div>
    </> : !user ? <Empty title="Sign in to see your matches."><button className="primary" onClick={onLogin}>Log in</button></Empty> : !source ? <Empty title="Create a post to start matching.">Post what you need or list a place. Your best fits will appear here.</Empty> : <>
      <div className="matches-toolbar"><label>Find matches for<select value={source} onChange={(event) => setSource(event.target.value)}>{mine.filter((item) => item.status === "active").map((item) => <option key={item.id} value={`request:${item.id}`}>Looking for: {item.title}</option>)}{ownListings.filter((item) => item.status === "approved").map((item) => <option key={item.id} value={`listing:${item.id}`}>Listing: {item.title}</option>)}</select></label><span><Sparkles size={16} /> Ranked by dates, budget, area and preferences</span></div>
      {matching ? <Busy /> : <div className="discovery-feed">{matches.length ? matches.map((match) => match.listing ? <ApartmentCard key={match.listing.id} listing={match.listing} reasons={match.reasons} /> : match.request ? <RequestCard key={match.request.id} request={match.request} reasons={match.reasons} /> : null) : <Empty title="No full matches yet.">As new posts come in, matches that cover the dates and budget will appear here. You can still browse all posts in Recent.</Empty>}</div>}
    </>}
    {post && <PostRequest existing={editing || undefined} onClose={() => { setPost(false); setEditing(null); }} onCreated={(request) => { setMine((current) => [request, ...current.filter((item) => item.id !== request.id)]); setRequests((current) => [request, ...current.filter((item) => item.id !== request.id)]); setSource(`request:${request.id}`); notify(editing ? "Request updated." : "Your request is live."); }} />}
    {reporting && <Modal title="Report this request" onClose={() => { setReporting(null); setReportReason(""); }}><form className="report-request-form" onSubmit={async (event) => { event.preventDefault(); setContactBusy(true); try { await api(`/requests/${encodeURIComponent(reporting.id)}/report`, { reason: reportReason }); notify("Report sent to the review team."); setReporting(null); setReportReason(""); } catch (cause) { notify((cause as Error).message); } finally { setContactBusy(false); } }}><p>Tell the review team what concerns you about this post.</p><label>Reason<textarea required minLength={10} maxLength={2000} rows={4} value={reportReason} onChange={(event) => setReportReason(event.target.value)} /></label><button className="primary" disabled={contactBusy}>Send report</button></form></Modal>}
    {contact && <Modal title="Choose a listing to share" onClose={() => setContact(null)}><div className="contact-choices"><p>Select which of your published places fits {contact.ownerName}’s request.</p>{fittingHomes(contact).map((listing) => <button key={listing.id} disabled={contactBusy} onClick={() => openRequestConversation(contact, listing)}><span><b>{listing.title}</b><small>{listing.neighborhood} · {money(listing.price)} / month</small></span><ArrowRight size={16} /></button>)}</div></Modal>}
  </main>;
}
