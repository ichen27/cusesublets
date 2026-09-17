import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowRight,
  ArrowUpRight,
  Home,
  MapPin,
  Search,
  SlidersHorizontal,
  Heart,
  ShieldCheck,
  CalendarDays,
  ChevronDown,
  Footprints,
  BedDouble,
  Map,
  LayoutGrid,
  Check,
  MessageCircle,
  Plus,
  Menu,
  X,
  LogOut,
} from "lucide-react";
import type { Listing, User } from "../shared/types";
import { api, money, date } from "./api";
import { filterListings, type Filters } from "./search";
import MapView from "./MapView";
import { Badge, Modal, ErrorBox, Empty, Busy } from "./ui";
import ListingDetail from "./ListingDetail";
import PostListing from "./PostListing";
import Workspace from "./Workspace";
import Admin from "./Admin";
type View = "explore" | "saved" | "inbox" | "account" | "admin";
export default function App() {
  const [view, setView] = useState<View>(
      location.hash === "#account" ? "account" : "explore",
    ),
    [listings, setListings] = useState<Listing[]>([]),
    [user, setUser] = useState<User | null>(null),
    [demo, setDemo] = useState(false),
    [preview, setPreview] = useState(false),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [selected, setSelected] = useState<Listing | null>(null),
    [login, setLogin] = useState(false),
    [post, setPost] = useState(false),
    [trust, setTrust] = useState(false),
    [filters, setFilters] = useState<Filters>({}),
    [filterOpen, setFilterOpen] = useState(false),
    [sort, setSort] = useState("recommended"),
    [mobileMap, setMobileMap] = useState(false),
    [menu, setMenu] = useState(false),
    [toast, setToast] = useState(""),
    [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState<string[]>(() => {
    try {
      const stored = JSON.parse(
        localStorage.getItem("cusesublets-saved") || "[]",
      );
      return Array.isArray(stored)
        ? stored.filter((v: unknown) => typeof v === "string")
        : [];
    } catch {
      return [];
    }
  });
  const refresh = useCallback(async () => {
    try {
      const [l, s] = await Promise.all([
        api<{ listings: Listing[] }>("/listings"),
        api<{ user: User | null; demo: boolean; preview?: boolean }>(
          "/session",
        ),
      ]);
      setListings(l.listings);
      setUser(s.user);
      setDemo(s.demo);
      setPreview(!!s.preview);
      setError("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    refresh();
  }, [refresh]);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 5500);
    return () => clearTimeout(t);
  }, [toast]);
  useEffect(() => {
    localStorage.setItem("cusesublets-saved", JSON.stringify(saved));
  }, [saved]);
  const notify = (s: string) => setToast(s);
  const save = (id: string) =>
    setSaved((s) => (s.includes(id) ? s.filter((v) => v !== id) : [...s, id]));
  const navigate = (v: View) => {
    setMenu(false);
    if (["inbox", "account", "admin"].includes(v) && !user) {
      setLogin(true);
      return;
    }
    setView(v);
    window.scrollTo({ top: 0 });
  };
  const items = useMemo(() => {
    const items = filterListings(
      view === "saved"
        ? listings.filter((l) => saved.includes(l.id))
        : listings,
      filters,
    );
    return sort === "price"
      ? items.sort((a, b) => a.price - b.price)
      : sort === "walk"
        ? items.sort((a, b) => a.walkMinutes - b.walkMinutes)
        : items;
  }, [listings, saved, view, filters, sort]);
  async function signIn(role: string) {
    setBusy(true);
    try {
      const s = await api<{ user: User; demo: boolean }>("/dev/session", {
        role,
      });
      setUser(s.user);
      setLogin(false);
      notify(
        `Welcome, ${s.user.name.split(" ")[0]}. You're in the local demo.`,
      );
      if (role === "admin") setView("admin");
      else setView("explore");
    } catch (e) {
      notify((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  const closeDetail = useCallback(() => setSelected(null), []),
    closeLogin = useCallback(() => setLogin(false), []),
    closePost = useCallback(() => setPost(false), []),
    closeTrust = useCallback(() => setTrust(false), []),
    closeFilters = useCallback(() => setFilterOpen(false), []);
  const askLogin = () => {
    setSelected(null);
    setLogin(true);
  };
  return (
    <>
      <header className="site-header">
        <a
          className="brand"
          href="#"
          onClick={(e) => {
            e.preventDefault();
            navigate("explore");
          }}
        >
          <span className="brand-mark">
            <Home size={22} strokeWidth={2.2} />
          </span>
          Cuse<span>Sublets</span>
          <i />
        </a>
        <nav
          className={menu ? "main-nav open" : "main-nav"}
          aria-label="Main navigation"
        >
          <button
            className={view === "explore" ? "active" : ""}
            onClick={() => navigate("explore")}
          >
            Find a sublet
          </button>
          <button
            className={view === "saved" ? "active" : ""}
            onClick={() => navigate("saved")}
          >
            Saved <span className="nav-count">{saved.length || ""}</span>
          </button>
          <button onClick={() => setTrust(true)}>
            How it works <ArrowUpRight size={13} />
          </button>
          {user && (
            <button
              className={view === "inbox" ? "active" : ""}
              onClick={() => navigate("inbox")}
            >
              Inbox
            </button>
          )}
          {user?.role === "admin" && (
            <button
              className={view === "admin" ? "active" : ""}
              onClick={() => navigate("admin")}
            >
              Admin
            </button>
          )}
        </nav>
        <div className="header-actions">
          <button
            className="outline small"
            onClick={() => (user ? setPost(true) : setLogin(true))}
          >
            <Plus size={15} /> List your place
          </button>
          {user ? (
            <button
              className="avatar"
              title="Your account"
              aria-label="Your account"
              onClick={() => navigate("account")}
            >
              {user.name
                .split(" ")
                .map((s) => s[0])
                .slice(0, 2)
                .join("")}
            </button>
          ) : (
            <button
              className="text-button sign-in"
              onClick={() => setLogin(true)}
            >
              Log in <ArrowUpRight size={14} />
            </button>
          )}
          <button
            className="icon-button mobile-menu"
            onClick={() => setMenu(!menu)}
            aria-label="Toggle navigation"
          >
            {menu ? <X /> : <Menu />}
          </button>
        </div>
      </header>
      {view === "explore" || view === "saved" ? (
        <>
          <section className="hero">
            <div className="hero-copy">
              <span className="eyebrow">
                <span className="orange-dot" /> SYRACUSE, NY · MADE FOR YOUR
                NEXT CHAPTER
              </span>
              <h1>
                {view === "saved" ? (
                  <>
                    Good places.
                    <br />
                    <em>Worth keeping.</em>
                  </>
                ) : (
                  <>
                    New semester.
                    <br />
                    <em>New place. Same Cuse.</em>
                  </>
                )}
              </h1>
              <p>
                {view === "saved"
                  ? "Your shortlist for whatever comes next."
                  : "A summer away. A semester abroad. A place to land.\nFind your people—and your next place—in Syracuse."}
              </p>
              <div className="hero-proof">
                <span className="proof-icon">
                  <ShieldCheck size={17} />
                </span>
                <span>Real connections. Clear details. Less guesswork.</span>
              </div>
            </div>
            <div className="hero-art">
              <img
                src="https://images.unsplash.com/photo-1600607687939-ce8a6c25118c?w=1000&auto=format&fit=crop&q=85"
                alt="Sunny living room with natural wood furnishings"
              />
              <span className="hero-image-label">
                A LITTLE SPACE FOR YOUR NEXT BIG THING.
              </span>
              <div className="hero-sticker">
                <span className="sticker-sun">✳</span>
                <span>
                  Make yourself
                  <br />
                  <b>at home.</b>
                </span>
              </div>
            </div>
          </section>
          <main className="discovery">
            <div className="search-bar">
              <label className="search-field">
                <MapPin size={19} />
                <span>
                  <small>WHERE</small>
                  <input
                    aria-label="Search neighborhood"
                    placeholder="Search a neighborhood"
                    value={filters.query || ""}
                    onChange={(e) =>
                      setFilters({ ...filters, query: e.target.value })
                    }
                  />
                </span>
              </label>
              <label className="search-field date-field">
                <CalendarDays size={18} />
                <span>
                  <small>MOVE IN</small>
                  <input
                    aria-label="Move-in date"
                    type="date"
                    value={filters.startDate || ""}
                    onChange={(e) =>
                      setFilters({ ...filters, startDate: e.target.value })
                    }
                  />
                </span>
              </label>
              <label className="search-field budget-field">
                <span>
                  <small>YOUR BUDGET</small>
                  <select
                    aria-label="Monthly budget"
                    value={filters.maxPrice || ""}
                    onChange={(e) =>
                      setFilters({
                        ...filters,
                        maxPrice: Number(e.target.value) || undefined,
                      })
                    }
                  >
                    <option value="">Any monthly budget</option>
                    <option value="700">Up to $700 / month</option>
                    <option value="900">Up to $900 / month</option>
                    <option value="1200">Up to $1,200 / month</option>
                    <option value="1600">Up to $1,600 / month</option>
                  </select>
                </span>
              </label>
              <button
                className="primary search-button"
                onClick={() =>
                  document
                    .getElementById("results")
                    ?.scrollIntoView({ behavior: "smooth", block: "start" })
                }
              >
                <Search size={18} />
                <span>Find my place</span>
              </button>
            </div>
            <div className="filter-row">
              <div className="chips">
                <button
                  className={!filters.roomType ? "chip selected" : "chip"}
                  onClick={() =>
                    setFilters({ ...filters, roomType: undefined })
                  }
                >
                  <Home size={14} /> All places
                </button>
                <button
                  className={
                    filters.roomType === "Private room"
                      ? "chip selected"
                      : "chip"
                  }
                  onClick={() =>
                    setFilters({
                      ...filters,
                      roomType:
                        filters.roomType === "Private room"
                          ? ""
                          : "Private room",
                    })
                  }
                >
                  Private room
                </button>
                <button
                  className={
                    filters.roomType === "Entire place"
                      ? "chip selected"
                      : "chip"
                  }
                  onClick={() =>
                    setFilters({
                      ...filters,
                      roomType:
                        filters.roomType === "Entire place"
                          ? ""
                          : "Entire place",
                    })
                  }
                >
                  Entire place
                </button>
                <span className="chip-divider" />
                <button
                  className={filters.furnished ? "chip selected" : "chip"}
                  onClick={() =>
                    setFilters({ ...filters, furnished: !filters.furnished })
                  }
                >
                  Furnished
                </button>
                <button
                  className={filters.verified ? "chip selected" : "chip"}
                  onClick={() =>
                    setFilters({ ...filters, verified: !filters.verified })
                  }
                >
                  <ShieldCheck size={14} /> Lease reviewed
                </button>
                <button
                  className={filters.tour ? "chip selected" : "chip"}
                  onClick={() =>
                    setFilters({ ...filters, tour: !filters.tour })
                  }
                >
                  3D tour
                </button>
              </div>
              <button
                className="chip more-filters"
                onClick={() => setFilterOpen(true)}
              >
                <SlidersHorizontal size={15} /> Filters
              </button>
            </div>
            <div className="results-heading" id="results">
              <div>
                <h2>
                  {view === "saved"
                    ? "Your saved places"
                    : "Find a place that fits you."}
                </h2>
                <p>
                  {items.length}{" "}
                  {view === "saved"
                    ? "saved places"
                    : items.length === 1
                      ? "place around Syracuse"
                      : "places around Syracuse"}{" "}
                  <span>·</span>{" "}
                  {demo
                    ? "Sample listings for the preview"
                    : "Your next chapter starts here"}
                </p>
              </div>
              <label className="sort">
                Sort by{" "}
                <select
                  aria-label="Sort listings"
                  value={sort}
                  onChange={(e) => setSort(e.target.value)}
                >
                  <option value="recommended">Recommended</option>
                  <option value="price">Price: low to high</option>
                  <option value="walk">Closest to campus</option>
                </select>
                <ChevronDown size={13} />
              </label>
            </div>
            <button
              className="mobile-map-switch primary"
              onClick={() => setMobileMap(!mobileMap)}
            >
              {mobileMap ? <LayoutGrid size={16} /> : <Map size={16} />}{" "}
              {mobileMap ? "Show listings" : "Explore map"}
            </button>
            <ErrorBox message={error} />
            {loading ? (
              <Busy />
            ) : (
              <div
                className={"results-layout " + (mobileMap ? "show-map" : "")}
              >
                <div className="listing-grid">
                  {items.length ? (
                    items.map((l) => (
                      <article className="listing-card" key={l.id}>
                        <div
                          className="card-photo"
                          onClick={() => setSelected(l)}
                        >
                          <img
                            src={l.images[0] || "/photo-pending.svg"}
                            alt={l.title}
                            loading="lazy"
                          />
                          <div className="card-labels">
                            {l.leaseStatus === "verified" && (
                              <Badge>Lease reviewed</Badge>
                            )}
                            {l.matterportUrl && (
                              <span className="tour-label">3D TOUR</span>
                            )}
                          </div>
                          <button
                            className={
                              "save-button " +
                              (saved.includes(l.id) ? "saved" : "")
                            }
                            aria-label={
                              saved.includes(l.id)
                                ? `Unsave ${l.title}`
                                : `Save ${l.title}`
                            }
                            onClick={(e) => {
                              e.stopPropagation();
                              save(l.id);
                            }}
                          >
                            <Heart
                              size={18}
                              fill={
                                saved.includes(l.id) ? "currentColor" : "none"
                              }
                            />
                          </button>
                          <div className="photo-bottom">
                            <span>{l.roomType}</span>
                            <span className="photo-dots">
                              <i />
                              <i />
                              <i />
                            </span>
                          </div>
                        </div>
                        <button
                          className="card-body"
                          onClick={() => setSelected(l)}
                        >
                          <div className="card-price">
                            <span>
                              {money(l.price)}
                              <small> / month</small>
                            </span>
                            <span className="walk">
                              <Footprints size={12} />
                              {l.walkMinutes} min to SU
                            </span>
                          </div>
                          <h3>{l.title}</h3>
                          <p>
                            <MapPin size={12} />
                            {l.neighborhood}, Syracuse
                          </p>
                          <div className="card-meta">
                            <span>
                              <BedDouble size={13} />
                              {l.beds} bed · {l.baths} bath
                            </span>
                            <span>
                              <CalendarDays size={13} />
                              {date(l.startDate)} – {date(l.endDate)}
                            </span>
                          </div>
                        </button>
                      </article>
                    ))
                  ) : (
                    <Empty title="No places match just yet.">
                      Try a wider budget or different dates.{" "}
                      <button
                        className="text-button"
                        onClick={() => setFilters({})}
                      >
                        Clear filters
                      </button>
                    </Empty>
                  )}
                </div>
                <aside className="map-panel">
                  <MapView
                    listings={items}
                    selected={selected?.id || null}
                    onSelect={setSelected}
                  />
                  <div className="map-caption">
                    <span className="orange-dot" /> AROUND SYRACUSE UNIVERSITY
                  </div>
                  <div className="map-note">
                    <ShieldCheck size={15} />
                    <span>
                      Find the neighborhood. Feel the fit.
                      <small>Map pins show approximate locations.</small>
                    </span>
                  </div>
                </aside>
              </div>
            )}
            <div className="community-banner">
              <span className="community-icon">
                <Home size={29} />
              </span>
              <div>
                <h3>Leaving Cuse for a little while?</h3>
                <p>Your place could be someone’s perfect next chapter.</p>
              </div>
              <button
                className="outline"
                onClick={() => (user ? setPost(true) : setLogin(true))}
              >
                List your place <ArrowRight size={17} />
              </button>
            </div>
          </main>
        </>
      ) : view === "admin" ? (
        <Admin user={user} notify={notify} onRefresh={refresh} />
      ) : user ? (
        <Workspace
          view={view}
          user={user}
          demo={demo}
          notify={notify}
          onSelect={setSelected}
          onPost={() => setPost(true)}
          onLogout={async () => {
            await api("/logout", {});
            setUser(null);
            setView("explore");
            if (!demo) location.assign("/cdn-cgi/access/logout");
          }}
        />
      ) : (
        <main className="workspace">
          {loading ? (
            <Busy />
          ) : (
            <Empty title="Sign in to see your account.">
              <button className="primary" onClick={() => setLogin(true)}>
                Log in
              </button>
            </Empty>
          )}
        </main>
      )}
      <footer>
        <a
          className="brand footer-brand"
          href="#"
          onClick={() => navigate("explore")}
        >
          <Home size={18} /> CuseSublets
          <i />
        </a>
        <span>Made for the places between your plans.</span>
        <button onClick={() => setTrust(true)}>
          Trust & how it works <ArrowUpRight size={12} />
        </button>
        <small>
          Independent community platform. Not affiliated with Syracuse
          University.
        </small>
      </footer>
      {(demo || preview) && (
        <div className="demo-ribbon">
          <span>
            <span className="orange-dot" />{" "}
            {preview
              ? "PRIVATE PREVIEW · Sample homes · Browsing only"
              : "LOCAL PREVIEW · Sample homes, simulated transactions"}
          </span>
          {demo && (
            <button onClick={() => setLogin(true)}>
              Switch demo role <ArrowUpRight size={12} />
            </button>
          )}
        </div>
      )}
      {toast && (
        <div className="toast" role="status">
          <Check size={17} />
          {toast}
          <button
            aria-label="Dismiss notification"
            onClick={() => setToast("")}
          >
            <X size={15} />
          </button>
        </div>
      )}
      {selected && (
        <ListingDetail
          listing={selected}
          user={user}
          demo={demo}
          saved={saved.includes(selected.id)}
          onSave={() => save(selected.id)}
          onClose={closeDetail}
          onLogin={askLogin}
          notify={notify}
        />
      )}
      {post && (
        <PostListing
          onClose={closePost}
          notify={notify}
          onCreated={() => {
            refresh();
            setView("account");
          }}
        />
      )}
      {login && (
        <Modal
          title={demo ? "Try CuseSublets" : "Welcome to CuseSublets"}
          onClose={closeLogin}
        >
          <div className="login-content">
            <div className="login-logo">
              <Home size={30} />
            </div>
            <h3>Your next chapter starts here.</h3>
            <p>
              Save the good ones, meet your next host, and keep everything in
              one place.
            </p>
            {demo ? (
              <>
                <div className="notice">
                  Local demo · No real identity checks or payments. Choose a
                  role to explore the full workflow.
                </div>
                {[
                  [
                    "renter",
                    "Explore as a renter",
                    "Save, message, and make an offer",
                  ],
                  [
                    "host",
                    "Explore as a host",
                    "Post a place and manage offers",
                  ],
                  [
                    "admin",
                    "Open the admin workspace",
                    "Review listings, evidence, and disputes",
                  ],
                ].map(([role, title, sub]) => (
                  <button
                    className="role-button"
                    key={role}
                    disabled={busy}
                    onClick={() => signIn(role)}
                  >
                    <span>
                      <b>{title}</b>
                      <small>{sub}</small>
                    </span>
                    <ArrowRight size={18} />
                  </button>
                ))}
              </>
            ) : preview ? (
              <p>
                This private preview lets you explore sample homes. Marketplace
                accounts, messages, posting, and payments are not enabled yet.
                Your Google sign-in protects access to this preview.
              </p>
            ) : (
              <button
                className="primary full"
                onClick={() => location.assign("/api/login")}
              >
                Continue with Google <ArrowRight size={17} />
              </button>
            )}
          </div>
        </Modal>
      )}
      {trust && (
        <Modal title="A little clarity goes a long way." onClose={closeTrust}>
          <div className="trust-content">
            <p className="lead">
              Housing is personal. You should know who you’re talking to and
              exactly what has been checked.
            </p>
            {[
              [
                "01",
                "Find your fit",
                "Browse freely. Compare dates, rent, amenities, and the neighborhood.",
              ],
              [
                "02",
                "Get to know your host",
                "Message on the platform and look for separate identity, lease, and sublet-permission checks. A badge is a specific check, not a guarantee.",
              ],
              [
                "03",
                "Agree on the details",
                "Make an offer or request the asking price. Confirm permission to sublet and complete the agreement before paying.",
              ],
              [
                "04",
                "Move in with a clear plan",
                "The proposed payout policy waits until confirmed move-in plus 48 hours without an open dispute. Stripe delayed payouts are not escrow.",
              ],
            ].map(([n, t, d]) => (
              <div className="trust-step" key={n}>
                <span>{n}</span>
                <div>
                  <h3>{t}</h3>
                  <p>{d}</p>
                </div>
              </div>
            ))}
            <div className="notice">
              This preview uses sample homes and simulated transactions. Live
              identity checks, payment processing, and legally reviewed signing
              require provider setup before launch.
            </div>
          </div>
        </Modal>
      )}
      {filterOpen && (
        <Modal title="A place that checks your boxes" onClose={closeFilters}>
          <div className="form-stack">
            <label>
              Move-out date
              <input
                type="date"
                value={filters.endDate || ""}
                onChange={(e) =>
                  setFilters({ ...filters, endDate: e.target.value })
                }
              />
            </label>
            <label>
              Maximum monthly rent
              <input
                type="number"
                min="1"
                value={filters.maxPrice || ""}
                onChange={(e) =>
                  setFilters({
                    ...filters,
                    maxPrice: Number(e.target.value) || undefined,
                  })
                }
                placeholder="Any budget"
              />
            </label>
            <label className="check-label">
              <input
                type="checkbox"
                checked={!!filters.furnished}
                onChange={(e) =>
                  setFilters({ ...filters, furnished: e.target.checked })
                }
              />{" "}
              Furnished places
            </label>
            <label className="check-label">
              <input
                type="checkbox"
                checked={!!filters.verified}
                onChange={(e) =>
                  setFilters({ ...filters, verified: e.target.checked })
                }
              />{" "}
              Lease and sublet permission reviewed
            </label>
            <div className="button-row">
              <button className="text-button" onClick={() => setFilters({})}>
                Reset all
              </button>
              <button className="primary" onClick={closeFilters}>
                Show {items.length} places <ArrowRight size={16} />
              </button>
            </div>
          </div>
        </Modal>
      )}
    </>
  );
}
