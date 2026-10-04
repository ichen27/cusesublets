import { useEffect, useMemo, useState } from "react";
import { LayoutGrid, Map, Search, SlidersHorizontal, ArrowRight, X } from "lucide-react";
import type { HousingSearch, Listing, User } from "../shared/types";
import { api, money, syracuseToday } from "./api";
import { matchListingToSearch } from "../shared/matching";
import { filterListings, filterHousingSearches, listingsInBounds, searchesInBounds, type Filters, type MapBounds } from "./search";
import MapView from "./MapView";
import { PlaceCard, PersonCard } from "./HousingCards";
import { Busy, Empty, ErrorBox, Modal } from "./ui";

export default function Browse({ listings, user, initialMode = "all", saved, onSave, onListing, onProfile, onChat, onLogin, onActivity, notify }: {
  listings: Listing[]; user: User | null; initialMode?: "all" | "places"; saved: string[];
  onSave: (id: string) => void; onListing: (listing: Listing) => void; onProfile: (id: string) => void;
  onChat: (id: string) => void; onLogin: () => void; onActivity: () => void; notify: (message: string) => void;
}) {
  const [mode, setMode] = useState<"all" | "places" | "people">(initialMode);
  const [searches, setSearches] = useState<HousingSearch[]>([]);
  const [mySearch, setMySearch] = useState<HousingSearch | null>(null);
  const [filters, setFilters] = useState<Filters>({});
  const [mapMode, setMapMode] = useState(false), [filterOpen, setFilterOpen] = useState(false);
  const [bounds, setBounds] = useState<MapBounds | null>(null);
  const [selectedPerson, setSelectedPerson] = useState<string | null>(null);
  const [loading, setLoading] = useState(true), [error, setError] = useState("");
  const [sort, setSort] = useState("recent");
  const [contact, setContact] = useState<{ search: HousingSearch; listings: Listing[] } | null>(null);
  useEffect(() => { setMode(initialMode); }, [initialMode]);
  useEffect(() => {
    let current = true;
    const refresh = () => Promise.all([
      api<{ searches: HousingSearch[] }>("/searches"),
      user ? api<{ search: HousingSearch | null }>("/my-search") : Promise.resolve({ search: null }),
    ]).then(([data, mine]) => { if (current) { setSearches(data.searches); setMySearch(mine.search); setError(""); } })
      .catch((cause) => { if (current) setError(cause.message); })
      .finally(() => { if (current) setLoading(false); });
    refresh();
    const timer = setInterval(refresh, 30000);
    return () => { current = false; clearInterval(timer); };
  }, [user?.id]);
  const places = useMemo(() => filterListings(listings.filter((l) => l.endDate > syracuseToday()), filters), [listings, filters]);
  const people = useMemo(() => filterHousingSearches(searches, filters), [searches, filters]);
  const visiblePlaces = listingsInBounds(places, bounds);
  const visiblePeople = searchesInBounds(people, bounds);
  const entries = [
    ...(mode !== "people" ? visiblePlaces.map((item) => ({ kind: "place" as const, item, createdAt: item.createdAt || "" })) : []),
    ...(mode !== "places" ? visiblePeople.map((item) => ({ kind: "person" as const, item, createdAt: item.createdAt })) : []),
  ].sort((a, b) => sort === "price"
    ? (a.kind === "place" ? a.item.price : a.item.maxBudget) - (b.kind === "place" ? b.item.price : b.item.maxBudget) || a.item.id.localeCompare(b.item.id)
    : b.createdAt.localeCompare(a.createdAt) || a.item.id.localeCompare(b.item.id));
  const selected = people.find((s) => s.id === selectedPerson);
  const areas = selected ? selected.areas : mode === "people" ? people.flatMap((s) => s.areas) : mySearch?.areas || [];
  async function connect(search: HousingSearch, listing: Listing) {
    try {
      const result = await api<{ conversation: { id: string } }>("/conversations", { listingId: listing.id, requestId: search.id });
      setContact(null); onChat(result.conversation.id);
    } catch (cause) { notify((cause as Error).message); }
  }
  async function contactPerson(search: HousingSearch) {
    if (!user) { onLogin(); return; }
    try {
      const result = await api<{ listings: Listing[] }>("/mine");
      const fitting = result.listings.filter((l) => matchListingToSearch(l, search));
      if (!fitting.length) { notify("You need a published place that fits this search to start a conversation."); return; }
      if (fitting.length === 1) await connect(search, fitting[0]);
      else setContact({ search, listings: fitting });
    } catch (cause) { notify((cause as Error).message); }
  }
  async function report(search: HousingSearch) {
    if (!user) { onLogin(); return; }
    const reason = window.prompt("What concerns you about this search? (At least 10 characters)");
    if (!reason) return;
    try { await api("/requests/" + search.id + "/report", { reason }); notify("Report sent to the review team."); }
    catch (cause) { notify((cause as Error).message); }
  }
  return <main className="browse-page">
    <div className="browse-heading"><div><span className="eyebrow">FIND YOUR NEXT CHAPTER IN SYRACUSE</span><h1>Browse</h1><p>Places to stay. People to connect with.</p></div><button className="outline browse-search-shortcut" onClick={onActivity}>{mySearch?.status === "active" ? "Manage my search" : "Turn on your search"}<ArrowRight size={15} /></button></div>
    <div className="browse-search-bar"><Search size={19} /><input aria-label="Search places and people" placeholder="Search a neighborhood, area, or keyword" value={filters.query || ""} onChange={(e) => setFilters({ ...filters, query: e.target.value })} /><button className="outline small filter-toggle" onClick={() => setFilterOpen(!filterOpen)}><SlidersHorizontal size={16} />Filters</button></div>
    <div className="browse-layout">
      <aside className={"browse-filters " + (filterOpen ? "open" : "")}><div className="filter-heading"><h2>Filters</h2><button className="text-button" onClick={() => { setFilters({}); setBounds(null); }}>Reset</button><button className="icon-button filter-close" aria-label="Close filters" onClick={() => setFilterOpen(false)}><X size={18} /></button></div>
        <label>Monthly budget<select value={filters.maxPrice || ""} onChange={(e) => setFilters({ ...filters, maxPrice: Number(e.target.value) || undefined })}><option value="">Any budget</option>{[700, 900, 1200, 1600, 2200].map((value) => <option key={value} value={value}>Up to {money(value)}</option>)}</select></label>
        <label>Room type<select value={filters.roomType || ""} onChange={(e) => setFilters({ ...filters, roomType: e.target.value })}><option value="">Any space</option><option>Private room</option><option>Entire place</option></select></label>
        <label>Move in<input type="date" value={filters.startDate || ""} onChange={(e) => setFilters({ ...filters, startDate: e.target.value })} /></label>
        <label>Move out<input type="date" value={filters.endDate || ""} onChange={(e) => setFilters({ ...filters, endDate: e.target.value })} /></label>
        <label className="filter-checkbox"><input type="checkbox" checked={!!filters.furnished} onChange={(e) => setFilters({ ...filters, furnished: e.target.checked })} />Furnished</label>
        {mode !== "people" && <label className="filter-checkbox"><input type="checkbox" checked={!!filters.verified} onChange={(e) => setFilters({ ...filters, verified: e.target.checked })} />Lease & permission reviewed</label>}
        <div className="filter-note"><Map size={20} /><strong>Search by area</strong><p>Open the map to find places nearby and people who want to live in that area.</p></div>
      </aside>
      <section className="browse-results">
        <div className="browse-toolbar"><div className="discovery-tabs" aria-label="Browse type">{(["all", "places", "people"] as const).map((value) => <button className={mode === value ? "selected" : ""} key={value} onClick={() => { setMode(value); setSelectedPerson(null); }}>{value === "all" ? "All" : value === "places" ? "Places" : "People"}</button>)}</div><div className="browse-view-controls"><select aria-label="Sort results" value={sort} onChange={(e) => setSort(e.target.value)}><option value="recent">Most recent</option><option value="price">Price: low to high</option></select><button className={"outline small " + (mapMode ? "selected" : "")} onClick={() => setMapMode(!mapMode)}>{mapMode ? <LayoutGrid size={16} /> : <Map size={16} />}{mapMode ? "List" : "Map"}</button></div></div>
        <div className="browse-result-count">{entries.length} {entries.length === 1 ? "result" : "results"}{bounds ? " in this map area" : " around Syracuse"}{bounds && <button className="text-button" onClick={() => setBounds(null)}>Show all areas</button>}</div>
        <ErrorBox message={error} />
        <div className={"browse-content " + (mapMode ? "with-map" : "")}>
          <div className="housing-grid">{loading ? <Busy /> : entries.length ? entries.map((entry) => entry.kind === "place"
            ? <PlaceCard key={"place-" + entry.item.id} listing={entry.item} saved={saved.includes(entry.item.id)} onSave={() => onSave(entry.item.id)} onOpen={() => onListing(entry.item)} />
            : <PersonCard key={"person-" + entry.item.id} search={entry.item} own={user?.id === entry.item.ownerId} selected={selectedPerson === entry.item.id} onAreas={() => { setSelectedPerson(entry.item.id); setMapMode(true); }} onProfile={() => onProfile(entry.item.ownerId)} onContact={() => contactPerson(entry.item)} onReport={() => report(entry.item)} />)
            : <Empty title="No results in this view.">Try another area or adjust your filters.</Empty>}</div>
          <aside className="browse-map" style={{ display: mapMode ? undefined : "none" }}><MapView listings={mode === "people" ? [] : places} selected={null} onSelect={onListing} onBoundsChange={setBounds} areas={areas} areaOpacity={mode === "people" && !selected ? 0 : 0.2} /><div className="browse-map-note">{mode === "people" ? "Outlined regions show desired areas. Select a person to highlight theirs." : "Pins show approximate locations. Shading shows desired areas."}{selected && <button className="text-button" onClick={() => setSelectedPerson(null)}>Clear selection</button>}</div></aside>
        </div>
      </section>
    </div>
    {contact && <Modal title={"Contact " + contact.search.ownerName} onClose={() => setContact(null)}><div className="contact-choices"><p>Choose the place you’d like to offer.</p>{contact.listings.map((l) => <button key={l.id} onClick={() => connect(contact.search, l)}>{l.title}<span>{money(l.price)}/month</span></button>)}</div></Modal>}
  </main>;
}
