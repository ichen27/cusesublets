import { useEffect, useState } from "react";
import { Map, LayoutGrid, ArrowRight, Sparkles } from "lucide-react";
import type { HousingSearch, Listing, User } from "../shared/types";
import { api, date, money, syracuseToday } from "./api";
import { PlaceCard, PersonCard } from "./HousingCards";
import { Busy, Empty, ErrorBox } from "./ui";
import MapView from "./MapView";
type Match = { score: number; reasons: string[]; listing?: Listing; search?: HousingSearch };
export default function Matches({ user, saved, onSave, onListing, onProfile, onChat, onLogin, onActivity, notify }: {
  user: User | null; saved: string[]; onSave: (id: string) => void; onListing: (listing: Listing) => void;
  onProfile: (id: string) => void; onChat: (id: string) => void; onLogin: () => void; onActivity: () => void; notify: (message: string) => void;
}) {
  const [search, setSearch] = useState<HousingSearch | null>(null);
  const [listings, setListings] = useState<Listing[]>([]);
  const [source, setSource] = useState(""), [matches, setMatches] = useState<Match[]>([]);
  const [loading, setLoading] = useState(!!user), [matching, setMatching] = useState(false), [error, setError] = useState("");
  const [mapMode, setMapMode] = useState(false), [selectedPerson, setSelectedPerson] = useState<string | null>(null);
  useEffect(() => {
    if (!user) { setLoading(false); setSource(""); return; }
    let current = true;
    setLoading(true);
    Promise.all([api<{ search: HousingSearch | null }>("/my-search"), api<{ listings: Listing[] }>("/mine")])
      .then(([mine, places]) => {
        if (!current) return;
        setSearch(mine.search);
        const live = places.listings.filter((l) => l.status === "approved" && l.endDate > syracuseToday());
        setListings(live);
        setSource(mine.search?.status === "active" && mine.search.endDate > syracuseToday() ? "search:" + mine.search.id : live.length ? "listing:" + live[0].id : "");
      }).catch((cause) => { if (current) setError(cause.message); }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [user?.id]);
  useEffect(() => {
    if (!source) { setMatches([]); return; }
    let current = true;
    const refresh = () => {
      setMatching(true);
      const [sourceType, sourceId] = source.split(":");
      api<{ matches: Match[] }>("/matches?sourceType=" + sourceType + "&sourceId=" + encodeURIComponent(sourceId))
        .then((result) => { if (current) { setMatches(result.matches); setError(""); } })
        .catch((cause) => { if (current) { setError(cause.message); setMatches([]); } })
        .finally(() => { if (current) setMatching(false); });
    };
    refresh();
    const timer = setInterval(refresh, 30000);
    return () => { current = false; clearInterval(timer); };
  }, [source]);
  const forSearch = source.startsWith("search:");
  const sourceListing = listings.find((l) => "listing:" + l.id === source);
  const people = matches.flatMap((m) => m.search ? [m.search] : []);
  const selected = people.find((s) => s.id === selectedPerson);
  const mapListings = forSearch ? matches.flatMap((m) => m.listing ? [m.listing] : []) : sourceListing ? [sourceListing] : [];
  const mapAreas = forSearch ? search?.areas || [] : selected ? selected.areas : people.flatMap((s) => s.areas);
  async function contact(person: HousingSearch) {
    if (!sourceListing) return;
    try { const result = await api<{ conversation: { id: string } }>("/conversations", { listingId: sourceListing.id, requestId: person.id }); onChat(result.conversation.id); }
    catch (cause) { notify((cause as Error).message); }
  }
  async function report(person: HousingSearch) {
    const reason = window.prompt("What concerns you about this search? (At least 10 characters)");
    if (!reason) return;
    try { await api("/requests/" + person.id + "/report", { reason }); notify("Report sent to the review team."); }
    catch (cause) { notify((cause as Error).message); }
  }
  return <main className="browse-page matches-page">
    <div className="browse-heading"><div><span className="eyebrow">BASED ON YOUR HOUSING PLANS</span><h1>Top matches</h1><p>Good fits for your search and your subleases.</p></div><button className="outline" onClick={onActivity}>My activity <ArrowRight size={15} /></button></div>
    <ErrorBox message={error} />
    {!user ? <Empty title="Sign in to see your matches.">Set up a search or list your place, then find people and places that fit.<button className="primary" onClick={onLogin}>Log in</button></Empty> : loading ? <Busy /> : !source ? <Empty title="Start with your housing plans.">Turn on your search or publish a sublease in My activity.<button className="primary" onClick={onActivity}>Go to My activity</button></Empty> : <>
      <div className="match-source-toolbar"><label>Find matches for<select aria-label="Match source" value={source} onChange={(e) => { setSource(e.target.value); setSelectedPerson(null); }}>
        {search?.status === "active" && search.endDate > syracuseToday() && <option value={"search:" + search.id}>My search · Places for me</option>}
        {listings.map((l) => <option key={l.id} value={"listing:" + l.id}>My listing · {l.title}</option>)}
      </select></label><button className="outline small" onClick={() => setMapMode(!mapMode)}>{mapMode ? <LayoutGrid size={16} /> : <Map size={16} />}{mapMode ? "List" : "Map"}</button></div>
      <div className="match-source-summary"><Sparkles size={20} /><div><strong>{forSearch ? "Places for your stay" : "People looking for a place like yours"}</strong><p>{forSearch && search ? money(search.maxBudget) + " maximum · " + date(search.startDate) + " – " + date(search.endDate) + " · " + search.areas.map((a) => a.label).join(", ") : sourceListing ? sourceListing.title + " · " + money(sourceListing.price) + " / month" : ""}</p><small>Matches cover the full stay, budget, desired area, room type, and required conditions.</small></div></div>
      {!search || search.status !== "active" ? <p className="matches-setup-note">Also looking for a place? <button className="text-button" onClick={onActivity}>Turn on your search in My activity.</button></p> : null}
      <div className="browse-result-count">{matches.length} matching {forSearch ? "places" : "people"}</div>
      <div className={"browse-content " + (mapMode ? "with-map" : "")}><div className="housing-grid">{matching ? <Busy /> : matches.length ? matches.map((match) => match.listing
        ? <PlaceCard key={match.listing.id} listing={match.listing} reasons={match.reasons} saved={saved.includes(match.listing.id)} onSave={() => onSave(match.listing!.id)} onOpen={() => onListing(match.listing!)} />
        : match.search ? <PersonCard key={match.search.id} search={match.search} selected={selectedPerson === match.search.id} reasons={match.reasons} onAreas={() => { setSelectedPerson(match.search!.id); setMapMode(true); }} onProfile={() => onProfile(match.search!.ownerId)} onContact={() => contact(match.search!)} onReport={() => report(match.search!)} /> : null)
        : <Empty title="No full matches yet.">New places and active searches will appear here when they fit. You can edit your criteria in My activity or explore Browse.</Empty>}</div>
        <aside className="browse-map" style={{ display: mapMode ? undefined : "none" }}><MapView listings={mapListings} areas={mapAreas} areaOpacity={!forSearch && !selected ? 0.03 : 0.2} selected={sourceListing?.id || null} onSelect={onListing} onBoundsChange={() => {}} /><div className="browse-map-note">{forSearch ? "Your desired areas and matching places." : "Your place and the areas matching people want to live in."}</div></aside>
      </div>
    </>}
  </main>;
}
