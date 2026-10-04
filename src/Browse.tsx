import { useEffect, useMemo, useState } from "react";
import {
  Map,
  Search,
  SlidersHorizontal,
  ArrowRight,
  X,
  Users,
  Plus,
  KeyRound,
} from "lucide-react";
import type { HousingSearch, Listing, User } from "../shared/types";
import { api, money, syracuseToday } from "./api";
import { matchListingToSearch } from "../shared/matching";
import {
  filterListings,
  filterHousingSearches,
  listingsInBounds,
  searchesInBounds,
  type Filters,
  type MapBounds,
} from "./search";
import MapView from "./MapView";
import CommunityPost from "./CommunityPost";
import ContactNotice, { needsContactNotice } from "./ContactNotice";
import { Busy, Empty, ErrorBox, Modal } from "./ui";

export default function Browse({
  listings,
  user,
  initialMode = "all",
  onListing,
  onProfile,
  onChat,
  onLogin,
  onActivity,
  onPost,
  onMessage,
  notify,
}: {
  listings: Listing[];
  user: User | null;
  initialMode?: "all" | "places";
  saved: string[];
  onSave: (id: string) => void;
  onListing: (listing: Listing) => void;
  onProfile: (id: string) => void;
  onChat: (id: string) => void;
  onLogin: () => void;
  onActivity: () => void;
  onPost: () => void;
  onMessage: (listing: Listing) => void;
  notify: (message: string) => void;
}) {
  const [mode, setMode] = useState<"all" | "places" | "people">(initialMode);
  const [searches, setSearches] = useState<HousingSearch[]>([]),
    [mySearch, setMySearch] = useState<HousingSearch | null>(null),
    [mine, setMine] = useState<Listing[]>([]);
  const [filters, setFilters] = useState<Filters>({});
  const [mapMode, setMapMode] = useState(false),
    [filterOpen, setFilterOpen] = useState(false);
  const [bounds, setBounds] = useState<MapBounds | null>(null);
  const [selectedPerson, setSelectedPerson] = useState<string | null>(null);
  const [loading, setLoading] = useState(true),
    [error, setError] = useState("");
  const [sort, setSort] = useState(user ? "for-you" : "recent"),
    [limit, setLimit] = useState(8);
  const [contact, setContact] = useState<{
    search: HousingSearch;
    listings: Listing[];
  } | null>(null);
  const [warning, setWarning] = useState<{
    search: HousingSearch;
    listing: Listing;
  } | null>(null);
  const [contactBusy, setContactBusy] = useState(false),
    [contactError, setContactError] = useState("");
  useEffect(() => {
    setContact(null);
    setWarning(null);
  }, [user?.id]);
  useEffect(() => {
    setSort(user ? "for-you" : "recent");
  }, [user?.id]);
  useEffect(() => {
    setMode(initialMode);
  }, [initialMode]);
  useEffect(() => {
    let current = true,
      pending = false;
    const refresh = () => {
      if (pending) return;
      pending = true;
      Promise.all([
        api<{ searches: HousingSearch[] }>("/searches"),
        user
          ? api<{ search: HousingSearch | null }>("/my-search")
          : Promise.resolve({ search: null }),
        user
          ? api<{ listings: Listing[] }>("/mine")
          : Promise.resolve({ listings: [] }),
      ])
        .then(([data, own, places]) => {
          if (current) {
            setSearches(data.searches);
            setMySearch(own.search);
            setMine(
              places.listings.filter(
                (l) => l.status === "approved" && l.endDate > syracuseToday(),
              ),
            );
            setError("");
          }
        })
        .catch((cause) => {
          if (current) setError(cause.message);
        })
        .finally(() => {
          pending = false;
          if (current) setLoading(false);
        });
    };
    refresh();
    const timer = setInterval(refresh, 30000);
    window.addEventListener("focus", refresh);
    window.addEventListener("housing-changed", refresh);
    return () => {
      current = false;
      clearInterval(timer);
      window.removeEventListener("focus", refresh);
      window.removeEventListener("housing-changed", refresh);
    };
  }, [user?.id]);
  useEffect(() => {
    setLimit(8);
  }, [mode, filters, bounds, sort]);
  const activeSearch =
    mySearch?.status === "active" && mySearch.endDate > syracuseToday()
      ? mySearch
      : null;
  const places = useMemo(
    () =>
      filterListings(
        listings.filter((l) => l.endDate > syracuseToday()),
        filters,
      ),
    [listings, filters],
  );
  const people = useMemo(
    () => filterHousingSearches(searches, filters),
    [searches, filters],
  );
  const visiblePlaces = listingsInBounds(places, bounds),
    visiblePeople = searchesInBounds(people, bounds);
  const fits = (l: Listing) =>
    activeSearch ? matchListingToSearch(l, activeSearch) : null;
  const personFit = (s: HousingSearch) =>
    mine.some((l) => !!matchListingToSearch(l, s));
  const entries = [
    ...(mode !== "people"
      ? visiblePlaces.map((item) => ({
          kind: "place" as const,
          item,
          createdAt: item.createdAt || "",
          fit: !!fits(item),
        }))
      : []),
    ...(mode !== "places"
      ? visiblePeople.map((item) => ({
          kind: "person" as const,
          item,
          createdAt: item.createdAt,
          fit: personFit(item),
        }))
      : []),
  ].sort(
    (a, b) =>
      (sort === "for-you" ? Number(b.fit) - Number(a.fit) : 0) ||
      b.createdAt.localeCompare(a.createdAt) ||
      a.item.id.localeCompare(b.item.id),
  );
  const fittingPlaces = listings.filter((l) => !!fits(l)),
    fittingPeople = searches.filter(personFit);
  const fitCount = fittingPlaces.length + fittingPeople.length;
  const selected = people.find((s) => s.id === selectedPerson);
  const areas = selected
    ? selected.areas
    : mode === "people"
      ? people.flatMap((s) => s.areas)
      : activeSearch?.areas || [];
  async function connect(search: HousingSearch, listing: Listing) {
    setContactBusy(true);
    setContactError("");
    try {
      const result = await api<{ conversation: { id: string } }>(
        "/conversations",
        { listingId: listing.id, requestId: search.id },
      );
      setContact(null);
      setWarning(null);
      onChat(result.conversation.id);
    } catch (cause) {
      setContactError((cause as Error).message);
      notify((cause as Error).message);
    } finally {
      setContactBusy(false);
    }
  }
  function choose(search: HousingSearch, listing: Listing) {
    setContactError("");
    setContact(null);
    if (needsContactNotice({ person: search })) setWarning({ search, listing });
    else void connect(search, listing);
  }
  function contactPerson(search: HousingSearch) {
    if (!user) {
      onLogin();
      return;
    }
    const fitting = mine.filter((l) => !!matchListingToSearch(l, search));
    if (!fitting.length) {
      notify("Publish a place that fits this search to start a conversation.");
      return;
    }
    if (fitting.length === 1) choose(search, fitting[0]);
    else setContact({ search, listings: fitting });
  }
  async function report(search: HousingSearch) {
    if (!user) {
      onLogin();
      return;
    }
    const reason = window.prompt(
      "What concerns you about this search? (At least 10 characters)",
    );
    if (!reason) return;
    try {
      await api("/requests/" + search.id + "/report", { reason });
      notify("Report sent to the review team.");
    } catch (cause) {
      notify((cause as Error).message);
    }
  }
  const filterContents = (
    <>
      <div className="filter-heading">
        <h2>Find your fit</h2>
        <button
          className="text-button"
          onClick={() => {
            setFilters({});
            setBounds(null);
          }}
        >
          Reset
        </button>
      </div>
      <div className="discovery-tabs">
        {(["all", "places", "people"] as const).map((value) => (
          <button
            key={value}
            className={mode === value ? "selected" : ""}
            onClick={() => {
              setMode(value);
              setSelectedPerson(null);
            }}
          >
            {value[0].toUpperCase() + value.slice(1)}
          </button>
        ))}
      </div>
      <label>
        Monthly budget
        <select
          value={filters.maxPrice || ""}
          onChange={(e) =>
            setFilters({
              ...filters,
              maxPrice: Number(e.target.value) || undefined,
            })
          }
        >
          <option value="">Any budget</option>
          {[700, 900, 1200, 1600, 2200].map((v) => (
            <option key={v} value={v}>
              Up to {money(v)}
            </option>
          ))}
        </select>
      </label>
      <label>
        Room type
        <select
          value={filters.roomType || ""}
          onChange={(e) => setFilters({ ...filters, roomType: e.target.value })}
        >
          <option value="">Any space</option>
          <option>Private room</option>
          <option>Entire place</option>
        </select>
      </label>
      <div className="filter-dates">
        <label>
          Move in
          <input
            type="date"
            value={filters.startDate || ""}
            onChange={(e) =>
              setFilters({ ...filters, startDate: e.target.value })
            }
          />
        </label>
        <label>
          Move out
          <input
            type="date"
            value={filters.endDate || ""}
            onChange={(e) =>
              setFilters({ ...filters, endDate: e.target.value })
            }
          />
        </label>
      </div>
      <label className="filter-checkbox">
        <input
          type="checkbox"
          checked={!!filters.furnished}
          onChange={(e) =>
            setFilters({ ...filters, furnished: e.target.checked })
          }
        />
        Furnished
      </label>
      {mode !== "people" && (
        <label className="filter-checkbox">
          <input
            type="checkbox"
            checked={!!filters.verified}
            onChange={(e) =>
              setFilters({ ...filters, verified: e.target.checked })
            }
          />
          Lease & permission checked
        </label>
      )}
      <button
        className="outline full"
        onClick={() => {
          setMapMode(!mapMode);
          setFilterOpen(false);
        }}
      >
        <Map size={17} />
        {mapMode ? "Close the map" : "Explore the map"}
      </button>
      <p className="quiet filter-help">
        Find places nearby and people who want to live in the areas you’re
        exploring.
      </p>
    </>
  );
  return (
    <main className="community-page">
      <div className="community-title">
        <div>
          <span className="eyebrow">YOUR SYRACUSE COMMUNITY</span>
          <h1>Around campus.</h1>
          <p>Real people. Open doors. Your next chapter.</p>
        </div>
        <button
          className={"status-pill " + (activeSearch ? "on" : "")}
          onClick={onActivity}
        >
          <span />
          {activeSearch ? "Looking for a place · On" : "Your housing plans"}
          <ArrowRight size={15} />
        </button>
      </div>
      <div className="community-layout">
        <aside className="community-filters panel">{filterContents}</aside>
        <section className="community-feed">
          <div className="feed-search">
            <Search size={19} />
            <input
              aria-label="Search places and people"
              placeholder="A neighborhood, a place, a person…"
              value={filters.query || ""}
              onChange={(e) =>
                setFilters({ ...filters, query: e.target.value })
              }
            />
          </div>
          <div className="feed-toolbar">
            <div className="feed-order">
              <button
                className={sort === "for-you" ? "active" : ""}
                onClick={() => setSort("for-you")}
              >
                For you
              </button>
              <button
                className={sort === "recent" ? "active" : ""}
                onClick={() => setSort("recent")}
              >
                Latest
              </button>
            </div>
            <div>
              <button
                className="text-button mobile-filters"
                onClick={() => setFilterOpen(true)}
              >
                <SlidersHorizontal size={16} />
                Filters
              </button>
              <button
                className="text-button"
                onClick={() => setMapMode(!mapMode)}
              >
                <Map size={17} />
                {mapMode ? "Hide map" : "Map"}
              </button>
            </div>
          </div>
          {sort === "for-you" && (activeSearch || mine.length) ? (
            <a className="fit-banner" href="#matches">
              <Users size={21} />
              <strong>
                {fitCount} {fitCount === 1 ? "match fits" : "matches fit"} your
                plans
              </strong>
              <span>
                View matches <ArrowRight size={16} />
              </span>
            </a>
          ) : sort === "for-you" ? (
            <div className="feed-setup">
              Showing recent community activity.{" "}
              <button className="text-button" onClick={onActivity}>
                Set up your plans for matches <ArrowRight size={14} />
              </button>
            </div>
          ) : null}
          {mapMode && (
            <section className="community-map panel">
              <MapView
                listings={mode === "people" ? [] : places}
                selected={null}
                onSelect={onListing}
                onBoundsChange={setBounds}
                areas={areas}
                areaOpacity={mode === "people" && !selected ? 0.04 : 0.2}
              />
              <div className="map-caption">
                {selected
                  ? selected.ownerName + "’s desired areas"
                  : "Move the map to filter places and desired areas."}
                {selected && (
                  <button
                    className="text-button"
                    onClick={() => setSelectedPerson(null)}
                  >
                    Clear selection
                  </button>
                )}
              </div>
            </section>
          )}
          <div className="feed-count">
            {entries.length} {entries.length === 1 ? "post" : "posts"}
            {bounds ? " in this map area" : " around Syracuse"}
            {bounds && (
              <button className="text-button" onClick={() => setBounds(null)}>
                Show all areas
              </button>
            )}
          </div>
          <ErrorBox message={error} />
          {loading ? (
            <Busy />
          ) : entries.length ? (
            entries.slice(0, limit).map((entry, index) => (
              <div key={entry.kind + entry.item.id}>
                {sort === "for-you" &&
                  (activeSearch || mine.length > 0) &&
                  (index === 0 || entries[index - 1].fit !== entry.fit) && (
                    <div className="feed-group-label">
                      {entry.fit
                        ? "FITS YOUR HOUSING PLANS"
                        : "AROUND THE COMMUNITY"}
                    </div>
                  )}
                {entry.kind === "place" ? (
                  <CommunityPost
                    listing={entry.item}
                    user={user}
                    onOpen={() => onListing(entry.item)}
                    onProfile={onProfile}
                    onContact={() => onMessage(entry.item)}
                    onLogin={onLogin}
                    fit={sort === "for-you" && entry.fit}
                  />
                ) : (
                  <CommunityPost
                    search={entry.item}
                    user={user}
                    onProfile={onProfile}
                    onContact={() => contactPerson(entry.item)}
                    onAreas={() => {
                      setSelectedPerson(entry.item.id);
                      setMapMode(true);
                    }}
                    onReport={() => report(entry.item)}
                    onLogin={onLogin}
                    fit={sort === "for-you" && entry.fit}
                  />
                )}
              </div>
            ))
          ) : (
            <Empty title="No posts in this view.">
              Try another area or adjust your filters.
            </Empty>
          )}
          {entries.length > limit && (
            <button
              className="outline full"
              onClick={() => setLimit((n) => n + 8)}
            >
              More from the community
            </button>
          )}
        </section>
        <aside className="community-right">
          <section className="panel housing-status">
            <div className="section-line">
              <h2>Your next chapter</h2>
              <Search size={20} />
            </div>
            <p>
              {activeSearch
                ? "Your search is out there. Let’s find your kind of place."
                : "A little about your plans helps the right people find you."}
            </p>
            {activeSearch ? (
              <>
                <div className="status-pill on">
                  <span />
                  Looking for a place · On
                </div>
                <strong className="status-budget">
                  Up to {money(activeSearch.maxBudget)} <small>/ month</small>
                </strong>
                <p className="quiet">
                  {activeSearch.areas.map((a) => a.label).join(" · ")}
                </p>
              </>
            ) : (
              <span className="role-pill seeking">Search is off</span>
            )}
            <button className="outline full" onClick={onActivity}>
              {activeSearch ? "Manage my search" : "Set up my search"}
              <ArrowRight size={15} />
            </button>
          </section>
          <section className="panel match-preview">
            <div className="section-line">
              <h2>A few good fits</h2>
              <Users size={20} />
            </div>
            {fittingPlaces.slice(0, 3).map((l) => (
              <button
                className="mini-place"
                key={l.id}
                onClick={() => onListing(l)}
              >
                {l.images[0] && <img src={l.images[0]} alt="" />}
                <span>
                  <strong>{money(l.price)} / month</strong>
                  <small>
                    {l.neighborhood} · {l.roomType}
                  </small>
                </span>
                <ArrowRight size={15} />
              </button>
            ))}
            {!fittingPlaces.length && (
              <p className="quiet">
                {fittingPeople.length
                  ? `${fittingPeople.length} people are looking for a place like yours.`
                  : activeSearch
                    ? "No full fits yet. New places will appear as your community grows."
                    : "Your matches begin with your dates, budget, and favorite areas."}
              </p>
            )}
            <a className="text-button" href="#matches">
              Explore your matches <ArrowRight size={15} />
            </a>
          </section>
          <section className="offer-note">
            <KeyRound size={25} />
            <h3>Have a place to share?</h3>
            <p>There’s someone looking for a space just like yours.</p>
            <button className="text-button" onClick={onPost}>
              <Plus size={16} />
              Post your place
            </button>
          </section>
        </aside>
      </div>
      {filterOpen && (
        <Modal title="Find your fit" onClose={() => setFilterOpen(false)}>
          <div className="community-filter-dialog">
            {filterContents}
            <button
              className="primary full"
              onClick={() => setFilterOpen(false)}
            >
              Show posts
            </button>
          </div>
        </Modal>
      )}
      {contact && (
        <Modal
          title={"Say hello to " + contact.search.ownerName}
          onClose={() => setContact(null)}
        >
          <div className="contact-choices">
            <p>Choose the place you’d like to offer.</p>
            {contact.listings.map((l) => (
              <button key={l.id} onClick={() => choose(contact.search, l)}>
                {l.title}
                <span>{money(l.price)}/month</span>
              </button>
            ))}
          </div>
        </Modal>
      )}
      {warning && (
        <ContactNotice
          busy={contactBusy}
          error={contactError}
          person={warning.search}
          onClose={() => setWarning(null)}
          onContinue={() => connect(warning.search, warning.listing)}
        />
      )}
    </main>
  );
}
