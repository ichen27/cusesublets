import { useEffect, useState } from "react";
import { ArrowLeft, ArrowRight, Bookmark, CalendarDays, Check, ChevronRight, Flag, Home, MapPin, RotateCcw, ShieldCheck, Users } from "lucide-react";
import type { HousingSearch, Listing, User } from "../shared/types";
import { api, date, money, syracuseToday } from "./api";
import { Busy, Empty, ErrorBox } from "./ui";
import MapView from "./MapView";
import ContactNotice, { needsContactNotice } from "./ContactNotice";
import "./matches.css";
type Match = { score: number; reasons: string[]; listing?: Listing; search?: HousingSearch };
const matchKey = (match: Match) => match.listing ? "listing:" + match.listing.id : "search:" + match.search?.id;
const initials = (name: string) => name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("");
export default function Matches({ user, saved, onSave, onListing, onProfile, onChat, onLogin, onActivity, notify }: {
  user: User | null; saved: string[]; onSave: (id: string) => void; onListing: (listing: Listing) => void;
  onProfile: (id: string) => void; onChat: (id: string) => void; onLogin: () => void; onActivity: () => void; notify: (message: string) => void;
}) {
  const [search, setSearch] = useState<HousingSearch | null>(null);
  const [listings, setListings] = useState<Listing[]>([]);
  const [source, setSource] = useState(""), [results, setMatches] = useState<Match[]>([]);
  const [resultSource, setResultSource] = useState("");
  const matches = resultSource === source ? results : [];
  const [loading, setLoading] = useState(!!user), [matching, setMatching] = useState(false), [error, setError] = useState("");
  const [revision, setRevision] = useState(0), [index, setIndex] = useState(0);
  const [notice, setNotice] = useState<Match | null>(null), [contacting, setContacting] = useState(false);
  useEffect(() => {
    setSearch(null); setListings([]); setMatches([]); setSource(""); setIndex(0); setNotice(null);
    if (!user) { setLoading(false); return; }
    let current = true, pending = false;
    setLoading(true);
    const refresh = () => {
      if (pending) return;
      pending = true;
      Promise.all([api<{ search: HousingSearch | null }>("/my-search"), api<{ listings: Listing[] }>("/mine")])
        .then(([mine, places]) => {
          if (!current) return;
          setSearch(mine.search);
          const live = places.listings.filter((l) => l.status === "approved" && l.endDate > syracuseToday());
          setListings(live);
          const sources = [...(mine.search?.status === "active" && mine.search.endDate > syracuseToday() ? ["search:" + mine.search.id] : []), ...live.map((listing) => "listing:" + listing.id)];
          setSource((selected) => sources.includes(selected) ? selected : sources[0] || "");
          setRevision((value) => value + 1); setError("");
        }).catch((cause) => { if (current) setError(cause.message); }).finally(() => { pending = false; if (current) setLoading(false); });
    };
    refresh();
    const timer = setInterval(refresh, 30000);
    window.addEventListener("focus", refresh);
    return () => { current = false; clearInterval(timer); window.removeEventListener("focus", refresh); };
  }, [user?.id]);
  useEffect(() => { setIndex(0); setNotice(null); }, [source]);
  useEffect(() => {
    if (!source) { setMatches([]); return; }
    let current = true;
    setMatching(true);
    const [sourceType, sourceId] = source.split(":");
    api<{ matches: Match[] }>("/matches?sourceType=" + sourceType + "&sourceId=" + encodeURIComponent(sourceId))
      .then((result) => { if (current) { setMatches(result.matches); setResultSource(source); setIndex((position) => Math.min(position, result.matches.length)); setError(""); } })
      .catch((cause) => { if (current) { setError(cause.message); setMatches([]); setResultSource(source); } })
      .finally(() => { if (current) setMatching(false); });
    return () => { current = false; };
  }, [source, revision]);
  const forSearch = source.startsWith("search:");
  const sourceListing = listings.find((l) => "listing:" + l.id === source);
  const current = matches[index], place = current?.listing, person = current?.search;
  const mapListings = forSearch ? matches.flatMap((m) => m.listing ? [m.listing] : []) : sourceListing ? [sourceListing] : [];
  const mapAreas = forSearch ? search?.areas || [] : person?.areas || [];
  const summary = forSearch && search ? `${money(search.maxBudget)} maximum · ${date(search.startDate)} – ${date(search.endDate)}` : sourceListing ? `${sourceListing.title} · ${money(sourceListing.price)} / month` : "";
  async function contact(match: Match) {
    if (contacting) return;
    if (!user) { onLogin(); return; }
    if (match.search && !sourceListing) { notify("Choose a live listing before contacting someone."); return; }
    setContacting(true);
    try {
      const body = match.listing ? { listingId: match.listing.id } : { listingId: sourceListing!.id, requestId: match.search!.id };
      const result = await api<{ conversation: { id: string } }>("/conversations", body);
      setNotice(null); onChat(result.conversation.id);
    } catch (cause) { notify((cause as Error).message); }
    finally { setContacting(false); }
  }
  function interested(match: Match) {
    if (needsContactNotice({ listing: match.listing, person: match.search })) setNotice(match);
    else void contact(match);
  }
  async function report(seeker: HousingSearch) {
    const reason = window.prompt("What concerns you about this search? (At least 10 characters)");
    if (!reason) return;
    try { await api("/requests/" + seeker.id + "/report", { reason }); notify("Report sent to the review team."); }
    catch (cause) { notify((cause as Error).message); }
  }
  const browse = () => { window.location.hash = "browse"; };
  return <main className="matches-page focused-matches">
    <header className="match-page-heading"><div><span className="eyebrow">BASED ON YOUR HOUSING PLANS</span><h1>{source && !forSearch ? "Meet your next subletter." : "A place that fits."}</h1><p>{source && !forSearch ? "People whose housing plans line up with your place." : "Good places. Real people. A little less searching."}</p></div><button className="outline" onClick={onActivity}>{source ? `Edit my ${forSearch ? "search" : "listing"}` : "My activity"} <ArrowRight size={16} /></button></header>
    <ErrorBox message={error} />
    {!user ? <Empty title="Your next place starts with you.">Sign in to set up your housing plans and see places and people that fit.<button className="primary" onClick={onLogin}>Sign in <ArrowRight size={16} /></button></Empty> : loading ? <Busy /> : !source ? <Empty title="Tell us what comes next.">{search?.status === "paused" ? "Turn your search on to discover places that fit, or publish a place you want to sublease." : "Set up a search or publish a sublease to find your matches."}<button className="primary" onClick={onActivity}>Go to My activity <ArrowRight size={16} /></button></Empty> : <>
      <div className="focused-match-controls"><label>Find matches for<select aria-label="Match source" value={source} onChange={(e) => setSource(e.target.value)}>
        {search?.status === "active" && search.endDate > syracuseToday() && <option value={"search:" + search.id}>My search · Places for me</option>}
        {listings.map((l) => <option key={l.id} value={"listing:" + l.id}>My listing · {l.title}</option>)}
      </select></label><span>{matches.length} matching {forSearch ? "places" : "people"}{matching ? " · Updating…" : ""}</span></div>
      {(matching || resultSource !== source) && !matches.length ? <Busy /> : !matches.length ? <Empty title="No full fits just yet.">New places and active searches will appear when they fit your dates, budget, areas, and required conditions.<span className="match-empty-actions"><button className="outline" onClick={onActivity}>Edit my criteria</button><button className="primary" onClick={browse}>Browse the community <ArrowRight size={16} /></button></span></Empty> : !current ? <section className="match-finished"><span className="match-finished-icon"><Check size={32} /></span><h2>You’ve seen your current matches.</h2><p>New fits will appear as people join and places become available. Next only moves through these cards; it doesn’t hide a person or place.</p><div className="match-empty-actions"><button className="outline" onClick={() => setIndex(matches.length - 1)}><ArrowLeft size={16} /> Back</button><button className="primary" onClick={() => setIndex(0)}><RotateCcw size={17} /> Review again</button><button className="text-button" onClick={browse}>Browse the community <ArrowRight size={16} /></button></div></section> : <div className="focused-match-layout">
        <article className="focused-match-card" key={matchKey(current)}>
          {place ? place.images[0] ? <img className="focused-match-hero" src={place.images[0]} alt={place.title} /> : <div className="focused-match-image-empty"><Home size={48} /><span>No photos added yet</span></div> : <div className="focused-person-cover"><Users size={36} /><span>Looking for a place</span><div className="focused-person-areas">{person?.areas.map((area) => <span key={area.id}><MapPin size={14} />{area.label}</span>)}</div></div>}
          <div className="focused-match-body"><button className="focused-match-author" onClick={() => onProfile(place?.ownerId || person!.ownerId)}><span className="match-avatar">{initials(place?.hostName || person!.ownerName)}</span><span><strong>{place?.hostName || person!.ownerName}</strong><small>{place ? `Offering a place · ${place.neighborhood}` : "Looking for a sublease"}</small></span><ArrowRight size={16} /></button>
            <h2>{place?.title || `${person!.ownerName} is looking for a place.`}</h2>
            <strong className="focused-match-price">{place ? money(place.price) : `Up to ${money(person!.maxBudget)}`} <small>/ month</small></strong>
            <div className="focused-match-meta"><span><CalendarDays size={16} />{date((place || person)!.startDate)} – {date((place || person)!.endDate)}</span><span><Home size={16} />{(place || person)!.roomType}{person?.minBedrooms ? ` · ${person.minBedrooms}+ bedrooms` : ""}</span></div>
            <h3 className="fit-reasons-heading">Why it fits</h3><ul className="focused-fit-tags">{current.reasons.map((reason) => <li key={reason}><Check size={15} />{reason}</li>)}</ul>
            <div className="focused-checks">{place ? <>{place.hostIdentity === "verified" && <span><ShieldCheck size={14} /> Identity checked</span>}{place.leaseStatus === "verified" && <span><ShieldCheck size={14} /> Lease checked</span>}{place.permissionStatus === "verified" && <span><ShieldCheck size={14} /> Permission checked</span>}{needsContactNotice({ listing: place }) && <button className="text-button" onClick={() => onListing(place)}>Some checks incomplete <ArrowRight size={14} /></button>}</> : person?.ownerIdentity === "verified" ? <span><ShieldCheck size={14} /> Identity checked</span> : <span className="check-incomplete">Identity not yet verified</span>}</div>
            <p className="focused-match-introduction">{place?.description || person?.introduction || "Get to know each other in a private conversation."}</p>
            <div className="focused-match-actions"><button className="outline" onClick={() => setIndex((position) => position + 1)}>Next <ChevronRight size={17} /></button>{place && <button className="outline match-save" aria-label={saved.includes(place.id) ? "Unsave matching place" : "Save matching place"} aria-pressed={saved.includes(place.id)} onClick={() => onSave(place.id)}><Bookmark size={19} fill={saved.includes(place.id) ? "currentColor" : "none"} /></button>}<button className="primary" disabled={contacting || matching} onClick={() => interested(current)}>{contacting ? "Opening…" : forSearch ? "I’m interested" : "Say hello"} <ArrowRight size={17} /></button></div>
            <button className="text-button focused-full-post" onClick={() => place ? onListing(place) : (window.location.hash = "search/" + person!.id)}>View post & conversation <ArrowRight size={15} /></button>
          </div>
        </article>
        <aside className="focused-match-context"><section><h2>{forSearch ? "In your corner of Syracuse." : "Where they want to live."}</h2><div className="focused-match-map"><MapView key={source} listings={mapListings} areas={mapAreas} selected={place?.id || sourceListing?.id || null} onSelect={(listing) => { const position = matches.findIndex((match) => match.listing?.id === listing.id); if (position >= 0) setIndex(position); else onListing(listing); }} onBoundsChange={() => {}} /></div><p className="match-context-areas"><MapPin size={17} />{mapAreas.map((area) => area.label).join(" · ")}</p><div className="match-context-divider" /><h3>{forSearch ? "Your search" : "Your place"}</h3><p>{summary}</p><button className="text-button" onClick={onActivity}>Edit {forSearch ? "criteria" : "listing"} <ArrowRight size={15} /></button><div className="match-context-divider" /><h3>A good starting point.</h3><p>These matches meet your housing requirements. Get to know each other and review the details before making a commitment.</p></section><nav className="focused-match-pagination" aria-label="Match cards"><button className="text-button" disabled={index === 0} onClick={() => setIndex((position) => Math.max(0, position - 1))}><ArrowLeft size={16} /> Back</button><span aria-live="polite">{index + 1} of {matches.length}</span><button className="text-button" onClick={() => setIndex((position) => position + 1)}>Next <ArrowRight size={16} /></button></nav>{person && <button className="text-button match-report" onClick={() => report(person)}><Flag size={13} /> Report this search</button>}</aside>
      </div>}
    </>}
    {notice && <ContactNotice listing={notice.listing} person={notice.search} busy={contacting} onClose={() => { if (!contacting) setNotice(null); }} onContinue={() => contact(notice)} onChecks={notice.listing ? () => { const listing = notice.listing!; setNotice(null); onListing(listing); } : undefined} />}
  </main>;
}
