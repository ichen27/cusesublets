import BrandMark from "./BrandMark";
import { PasswordLogin } from "./PasswordAuth";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
  UserRound,
  Users,
} from "lucide-react";
import type { Listing, User, HousingSearch } from "../shared/types";
import { api, money, date } from "./api";
import {
  filterListings,
  listingsInBounds,
  type MapBounds,
  type Filters,
} from "./search";
import MapView from "./MapView";
import { Badge, Modal, ErrorBox, Empty, Busy } from "./ui";
import ListingDetail from "./ListingDetail";
import PostListing from "./PostListing";
import Workspace from "./Workspace";
import Admin from "./Admin";
import PublicProfile from "./PublicProfile";
import { ChecksGuide, IdentityBadge } from "./Checks";
import ChatWorkspace, { type ChatIntent } from "./ChatWorkspace";
import MyActivity from "./MyActivity";
import Browse from "./Browse";
import Matches from "./Matches";
import { PlaceCard } from "./HousingCards";
import Welcome from "./Welcome";
import SearchEditor from "./SearchEditor";
import DraftList from "./DraftList";
import SavedPosts from "./SavedPosts";
import CommunityPost, { PersonAvatar } from "./CommunityPost";
import ContactNotice, { needsContactNotice } from "./ContactNotice";
type View =
  | "browse"
  | "matches"
  | "explore"
  | "saved"
  | "inbox"
  | "account"
  | "admin"
  | "host"
  | "profile"
  | "checks";
function routeId(value: string) {
  try {
    return decodeURIComponent(value);
  } catch {
    return "";
  }
}
export default function App() {
  const [view, setView] = useState<View>(
      location.hash.startsWith("#profile/")
        ? "profile"
        : location.hash === "#checks"
          ? "checks"
          : location.hash.startsWith("#chat")
            ? "inbox"
            : location.hash === "#my-listings"
              ? "host"
              : location.hash === "#account"
                ? "account"
                : location.hash === "#explore"
                  ? "explore"
                  : location.hash === "#matches"
                    ? "matches"
                    : "browse",
    ),
    [listings, setListings] = useState<Listing[]>([]),
    [user, setUser] = useState<User | null>(null),
    [demo, setDemo] = useState(false),
    [preview, setPreview] = useState(false),
    [staging, setStaging] = useState(false),
    [mapBounds, setMapBounds] = useState<MapBounds | null>(null),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [selected, setSelected] = useState<Listing | null>(null),
    [login, setLogin] = useState(false),
    [post, setPost] = useState(false),
    [filters, setFilters] = useState<Filters>({}),
    [filterOpen, setFilterOpen] = useState(false),
    [sort, setSort] = useState("recommended"),
    [mobileMap, setMobileMap] = useState(false),
    [menu, setMenu] = useState(false),
    [toast, setToast] = useState(""),
    [busy, setBusy] = useState(false);
  const [welcome, setWelcome] = useState(false),
    [pendingRole, setPendingRole] = useState<"find" | "offer" | null>(null);
  const [editingSearch, setEditingSearch] = useState<{
      search: HousingSearch | null;
    } | null>(null),
    [draftId, setDraftId] = useState<string | undefined>();
  const [contactNotice, setContactNotice] = useState<{
    listing: Listing;
    intent: ChatIntent;
  } | null>(null);
  const browseScroll = useRef(0);
  const [pendingContact, setPendingContact] = useState<{
      listing: Listing;
      intent: ChatIntent;
    } | null>(null),
    [pendingSave, setPendingSave] = useState<string | null>(null),
    [pendingView, setPendingView] = useState<View | null>(null);
  const detailReturnHash = useRef("#browse");
  function showListing(listing: Listing) {
    detailReturnHash.current = location.hash || "#browse";
    setSelected(listing);
    history.replaceState(
      null,
      "",
      "#listing/" + encodeURIComponent(listing.id),
    );
  }
  const [contactBusy, setContactBusy] = useState(false),
    [contactError, setContactError] = useState("");
  const [selectedSearch, setSelectedSearch] = useState<HousingSearch | null>(
    null,
  );
  useEffect(() => {
    setPost(false);
    setEditingSearch(null);
    setContactNotice(null);
    setContactError("");
  }, [user?.id]);
  async function beginSearch() {
    if (!user) {
      setPendingRole("find");
      setLogin(true);
      return;
    }
    try {
      const result = await api<{ search: HousingSearch | null }>("/my-search");
      setEditingSearch(result);
    } catch (e) {
      setToast((e as Error).message);
    }
  }
  function beginPost(id?: string) {
    if (!user) {
      setPendingRole("offer");
      setLogin(true);
      return;
    }
    setDraftId(id);
    setPost(true);
  }
  function finishWelcome() {
    localStorage.setItem("cusesublets-community-welcome", "seen");
    setWelcome(false);
  }
  function chooseRole(role: "find" | "offer") {
    finishWelcome();
    if (role === "find") void beginSearch();
    else beginPost();
  }
  useEffect(() => {
    if (loading) return;
    if (
      !user &&
      !location.hash &&
      !localStorage.getItem("cusesublets-community-welcome")
    )
      setWelcome(true);
  }, [loading, user?.id]);
  useEffect(() => {
    if (!user || !pendingRole) return;
    const role = pendingRole;
    setPendingRole(null);
    if (role === "find") void beginSearch();
    else beginPost();
  }, [user?.id, pendingRole]);
  const [profileId, setProfileId] = useState(
    location.hash.startsWith("#profile/")
      ? routeId(location.hash.slice(9))
      : "",
  );
  function openProfile(id: string) {
    if (view === "browse" || view === "explore")
      browseScroll.current = window.scrollY;
    setSelected(null);
    setProfileId(id);
    setView("profile");
    history.replaceState(null, "", `#profile/${encodeURIComponent(id)}`);
    window.scrollTo({ top: 0 });
  }
  const [chatId, setChatId] = useState(
    location.hash.startsWith("#chat/") ? routeId(location.hash.slice(6)) : "",
  );
  const [chatIntent, setChatIntent] = useState<ChatIntent>("message");
  const openChat = (id: string) => {
    if (view === "browse" || view === "explore")
      browseScroll.current = window.scrollY;
    setSelected(null);
    setChatId(id);
    setChatIntent("message");
    setView("inbox");
    history.replaceState(null, "", `#chat/${encodeURIComponent(id)}`);
    window.scrollTo({ top: 0 });
  };
  async function listingChat(listing: Listing, intent: ChatIntent) {
    if (!user) {
      setPendingContact({ listing, intent });
      setLogin(true);
      return;
    }
    if (needsContactNotice({ listing })) {
      setSelected(null);
      setContactError("");
      setContactNotice({ listing, intent });
      return;
    }
    await createListingChat(listing, intent);
  }
  async function createListingChat(listing: Listing, intent: ChatIntent) {
    setContactBusy(true);
    setContactError("");
    try {
      const result = await api<{ conversation: { id: string } }>(
        "/conversations",
        { listingId: listing.id },
      );
      openChat(result.conversation.id);
      setChatIntent(intent);
      setContactNotice(null);
    } catch (e) {
      setContactError((e as Error).message);
      setToast((e as Error).message);
    } finally {
      setContactBusy(false);
    }
  }
  const [saved, setSaved] = useState<string[]>([]);
  const refresh = useCallback(async () => {
    try {
      const [l, s] = await Promise.all([
        api<{ listings: Listing[] }>("/listings"),
        api<{
          user: User | null;
          demo: boolean;
          preview?: boolean;
          staging?: boolean;
        }>("/session"),
      ]);
      setListings(l.listings);
      setUser(s.user);
      setDemo(s.demo);
      setPreview(!!s.preview);
      setStaging(!!s.staging);
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
    if (view !== "browse" && view !== "matches") return;
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") refresh();
    }, 30000);
    const onFocus = () => refresh();
    window.addEventListener("focus", onFocus);
    return () => {
      clearInterval(timer);
      window.removeEventListener("focus", onFocus);
    };
  }, [view, refresh]);
  useEffect(() => {
    let active = true;
    let request = 0;
    const openLinkedListing = () => {
      const current = ++request;
      const hash = location.hash;
      setSelectedSearch(null);
      if (hash.startsWith("#search/")) {
        const key = routeId(hash.slice(8));
        api<{ searches: HousingSearch[] }>("/searches")
          .then((result) => {
            if (!active || current !== request) return;
            const target = result.searches.find((x) => x.id === key);
            if (target) {
              setSelectedSearch(target);
              setView("browse");
            } else setToast("This search is currently unavailable.");
          })
          .catch((e) => {
            if (active && current === request) setToast(e.message);
          });
        return;
      }

      if (hash.startsWith("#listing/")) {
        api<{ listing: Listing }>(
          `/listings/${encodeURIComponent(routeId(hash.slice(9)))}`,
        )
          .then(({ listing }) => {
            if (active && current === request) setSelected(listing);
          })
          .catch((e) => {
            if (active && current === request) setToast(e.message);
          });
        return;
      }
      setSelected(null);
      if (hash.startsWith("#profile/")) {
        setProfileId(routeId(hash.slice(9)));
        setView("profile");
        return;
      }
      if (hash.startsWith("#chat")) {
        setChatId(hash.startsWith("#chat/") ? routeId(hash.slice(6)) : "");
        setChatIntent("message");
        setView("inbox");
        return;
      }
      const views: Record<string, View> = {
        "#account": "account",
        "#my-listings": "host",
        "#host": "host",
        "#activity": "host",
        "#you": "host",
        "#checks": "checks",
        "#saved": "saved",
        "#admin": "admin",
        "#explore": "explore",
        "#browse": "browse",
        "#recent": "browse",
        "#matches": "matches",
        "#": "browse",
        "": "browse",
      };
      if (views[hash]) setView(views[hash]);
    };
    openLinkedListing();
    window.addEventListener("hashchange", openLinkedListing);
    return () => {
      active = false;
      window.removeEventListener("hashchange", openLinkedListing);
    };
  }, []);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 5500);
    return () => clearTimeout(t);
  }, [toast]);
  useEffect(() => {
    let current = true;
    async function loadSaves() {
      if (!user) {
        setSaved([]);
        return;
      }
      try {
        const ids: string[] = [];
        let cursor: string | null = null;
        do {
          const result: {
            items: { targetType: string; targetId: string }[];
            nextCursor: string | null;
          } = await api(
            "/social/saved" +
              (cursor ? "?cursor=" + encodeURIComponent(cursor) : ""),
          );
          ids.push(
            ...result.items
              .filter((x) => x.targetType === "listing")
              .map((x) => x.targetId),
          );
          cursor = result.nextCursor;
        } while (cursor);
        if (current) setSaved(ids);
      } catch (e) {
        if (current) setToast((e as Error).message);
      }
    }
    void loadSaves();
    const reload = () => void loadSaves();
    window.addEventListener("social-saved-changed", reload);
    return () => {
      current = false;
      window.removeEventListener("social-saved-changed", reload);
    };
  }, [user?.id]);
  const notify = (s: string) => setToast(s);
  const save = async (id: string) => {
    if (!user) {
      setPendingSave(id);
      setLogin(true);
      return;
    }
    try {
      await api("/social/listing/" + encodeURIComponent(id) + "/save", {
        saved: !saved.includes(id),
      });
      window.dispatchEvent(new Event("social-saved-changed"));
    } catch (e) {
      notify((e as Error).message);
    }
  };
  const navigate = (v: View) => {
    if (view === "browse" || view === "explore")
      browseScroll.current = window.scrollY;
    setWelcome(false);
    setMenu(false);
    if (["inbox", "account", "admin", "host", "saved"].includes(v) && !user) {
      setPendingView(v);
      setLogin(true);
      return;
    }
    setView(v);
    history.replaceState(
      null,
      "",
      v === "inbox"
        ? chatId
          ? `#chat/${encodeURIComponent(chatId)}`
          : "#chat"
        : v === "host"
          ? "#you"
          : `#${v}`,
    );
    requestAnimationFrame(() =>
      window.scrollTo({ top: v === "browse" ? browseScroll.current : 0 }),
    );
  };
  useEffect(() => {
    if (!user) return;
    if (pendingContact) {
      const target = pendingContact;
      setPendingContact(null);
      void listingChat(target.listing, target.intent);
    }
    if (pendingSave) {
      const target = pendingSave;
      setPendingSave(null);
      void api("/social/listing/" + encodeURIComponent(target) + "/save", {
        saved: true,
      })
        .then(() => window.dispatchEvent(new Event("social-saved-changed")))
        .catch((e) => setToast(e.message));
    }
    if (pendingView) {
      const target = pendingView;
      setPendingView(null);
      navigate(target);
    }
  }, [user?.id]);
  const candidates = useMemo(() => {
    const items =
      view === "saved"
        ? listings.filter((l) => saved.includes(l.id))
        : filterListings(listings, filters);
    return sort === "price"
      ? items.sort((a, b) => a.price - b.price)
      : sort === "walk"
        ? items.sort((a, b) => a.walkMinutes - b.walkMinutes)
        : items;
  }, [listings, saved, view, filters, sort]);
  const items = useMemo(
    () =>
      view === "saved" ? candidates : listingsInBounds(candidates, mapBounds),
    [candidates, mapBounds, view],
  );
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
      else setView("browse");
      history.replaceState(null, "", role === "admin" ? "#admin" : "#browse");
    } catch (e) {
      notify((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  const closeDetail = useCallback(() => {
      setSelected(null);
      if (location.hash.startsWith("#listing/"))
        history.replaceState(null, "", detailReturnHash.current);
    }, []),
    closeLogin = useCallback(() => setLogin(false), []),
    closePost = useCallback(() => setPost(false), []),
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
            navigate("browse");
          }}
        >
          <span className="brand-mark">
            <BrandMark />
          </span>
          Cuse<span>Sublets</span>
        </a>
        <nav
          className={menu ? "main-nav open" : "main-nav"}
          aria-label="Main navigation"
        >
          <button
            className={view === "browse" || view === "explore" ? "active" : ""}
            onClick={() => navigate("browse")}
          >
            Browse
          </button>
          <button
            className={view === "matches" ? "active" : ""}
            onClick={() => navigate("matches")}
          >
            Matches
          </button>
          <button
            className={view === "inbox" ? "active" : ""}
            onClick={() => navigate("inbox")}
          >
            Inbox
          </button>
          <button
            className={
              ["host", "account", "saved", "admin"].includes(view)
                ? "active"
                : ""
            }
            onClick={() => navigate("host")}
          >
            You
          </button>
        </nav>
        <div className="header-actions">
          <button className="outline small" onClick={() => beginPost()}>
            <Plus size={15} /> Post a place
          </button>
          {user ? (
            <button
              className="avatar"
              title="Your account"
              aria-label="Your account"
              onClick={() => navigate("host")}
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
      {welcome ? (
        <Welcome onChoose={chooseRole} onSkip={finishWelcome} />
      ) : null}
      <div hidden={welcome || (view !== "browse" && view !== "explore")}>
        <Browse
          listings={listings}
          user={user}
          initialMode={view === "explore" ? "places" : "all"}
          saved={saved}
          onSave={save}
          onListing={showListing}
          onProfile={openProfile}
          onChat={openChat}
          onLogin={() => setLogin(true)}
          onActivity={() => navigate("host")}
          onPost={() => beginPost()}
          onMessage={(l) => listingChat(l, "message")}
          notify={notify}
        />
      </div>
      {!welcome &&
        ["host", "account", "saved", "admin", "checks"].includes(view) && (
          <nav className="you-subnav" aria-label="Your account sections">
            <a href="#you" className={view === "host" ? "active" : ""}>
              My activity
            </a>
            <a href="#saved" className={view === "saved" ? "active" : ""}>
              Saved
            </a>
            <a href="#account" className={view === "account" ? "active" : ""}>
              Profile & verification
            </a>
            <a href="#checks" className={view === "checks" ? "active" : ""}>
              About checks
            </a>
            {user?.role === "admin" && <a href="#admin">Review dashboard</a>}
          </nav>
        )}
      {welcome || view === "browse" || view === "explore" ? null : view ===
        "matches" ? (
        <Matches
          user={user}
          saved={saved}
          onSave={save}
          onListing={showListing}
          onProfile={openProfile}
          onChat={openChat}
          onLogin={() => setLogin(true)}
          onActivity={() => navigate("host")}
          notify={notify}
        />
      ) : view === "saved" ? (
        <SavedPosts
          key={user?.id || "guest"}
          user={user}
          listings={listings}
          onListing={showListing}
          onProfile={openProfile}
          onLogin={() => setLogin(true)}
        />
      ) : view === "checks" ? (
        <ChecksGuide />
      ) : view === "profile" ? (
        <PublicProfile
          key={profileId}
          id={profileId}
          user={user}
          onSelect={showListing}
          onEdit={() => navigate("account")}
          onChecks={() => navigate("checks")}
        />
      ) : view === "admin" ? (
        <Admin user={user} notify={notify} onRefresh={refresh} />
      ) : user && view === "inbox" ? (
        <ChatWorkspace
          key={user.id}
          user={user}
          demo={demo}
          activeId={chatId}
          intent={chatIntent}
          onProfile={openProfile}
          onOpen={openChat}
          onSelect={showListing}
        />
      ) : user && view === "host" ? (
        <div className="you-page" key={user.id}>
          <aside className="you-profile panel">
            <PersonAvatar name={user.name} src={user.avatar} />
            <h2>{user.name}</h2>
            <p>Your corner of the community.</p>
            <a className="outline full" href="#account">
              Edit profile <ArrowRight size={15} />
            </a>
            <button className="text-button" onClick={() => setWelcome(true)}>
              Explore the welcome flow
            </button>
          </aside>
          <div className="you-content">
            <DraftList
              onSearch={() => void beginSearch()}
              onListing={(id) => beginPost(id)}
            />
            <MyActivity
              key={user.id}
              user={user}
              onListing={showListing}
              onPost={() => beginPost()}
              onChat={openChat}
              onPublished={(listing) =>
                setListings((current) => [
                  ...current.filter((item) => item.id !== listing.id),
                  ...(listing.status === "approved" ? [listing] : []),
                ])
              }
            />
          </div>
        </div>
      ) : user ? (
        <Workspace
          view={view}
          onProfile={openProfile}
          onManage={() => navigate("host")}
          onRefresh={refresh}
          user={user}
          demo={demo}
          notify={notify}
          onSelect={showListing}
          onPost={() => beginPost()}
          onLogout={async () => {
            await api("/logout", {});
            setUser(null);
            setView("browse");
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
      {!welcome && (
        <nav className="mobile-bottom-nav" aria-label="Mobile navigation">
          <button
            className={view === "browse" || view === "explore" ? "active" : ""}
            onClick={() => navigate("browse")}
          >
            <Home size={21} />
            Browse
          </button>
          <button
            className={view === "matches" ? "active" : ""}
            onClick={() => navigate("matches")}
          >
            <Users size={21} />
            Matches
          </button>
          <button
            className={view === "inbox" ? "active" : ""}
            onClick={() => navigate("inbox")}
          >
            <MessageCircle size={21} />
            Inbox
          </button>
          <button
            className={
              ["host", "account", "saved"].includes(view) ? "active" : ""
            }
            onClick={() => navigate("host")}
          >
            <UserRound size={21} />
            You
          </button>
        </nav>
      )}
      <footer>
        <a
          className="brand footer-brand"
          href="#"
          onClick={() => navigate("browse")}
        >
          <span className="brand-mark">
            <BrandMark size={30} />
          </span>
          Cuse<span>Sublets</span>
        </a>
        <span>A place for your next chapter.</span>
        <button onClick={() => navigate("checks")}>
          CuseSublets Checks <ArrowUpRight size={12} />
        </button>
        <small>
          Independent community platform. Not affiliated with Syracuse
          University.
        </small>
      </footer>
      {(demo || preview || staging) && (
        <div className="demo-ribbon">
          <span>
            <span className="orange-dot" />{" "}
            {staging
              ? "PRIVATE BETA · Sample homes · Payments not enabled"
              : preview
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
      {selectedSearch && (
        <Modal
          title={selectedSearch.ownerName + "’s search"}
          wide
          onClose={() => {
            setSelectedSearch(null);
            history.replaceState(null, "", "#browse");
          }}
        >
          <CommunityPost
            search={selectedSearch}
            user={user}
            onProfile={openProfile}
            onAreas={() => openProfile(selectedSearch.ownerId)}
            onLogin={() => setLogin(true)}
          />
        </Modal>
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
          onProfile={openProfile}
          onChecks={() => {
            setSelected(null);
            navigate("checks");
          }}
          onChat={listingChat}
          onManage={() => {
            setSelected(null);
            navigate("host");
          }}
          notify={notify}
        />
      )}
      {editingSearch && (
        <SearchEditor
          search={editingSearch.search}
          onSaved={() => {
            setToast(
              "Your search is saved. Your current status is shown below.",
            );
            window.dispatchEvent(new Event("housing-changed"));
            navigate("host");
          }}
          onClose={() => setEditingSearch(null)}
        />
      )}
      {contactNotice && (
        <ContactNotice
          busy={contactBusy}
          error={contactError}
          listing={contactNotice.listing}
          onClose={() => setContactNotice(null)}
          onContinue={async () => {
            const current = contactNotice;
            await createListingChat(current.listing, current.intent);
          }}
          onChecks={() => {
            setContactNotice(null);
            navigate("checks");
          }}
        />
      )}
      {post && (
        <PostListing
          draftId={draftId}
          onClose={closePost}
          notify={notify}
          onCreated={() => {
            refresh();
            window.dispatchEvent(new Event("housing-changed"));
            navigate("host");
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
              <BrandMark size={52} />
            </div>
            <h3>Find, list, and manage your sublet.</h3>
            <p>
              Save listings, contact hosts, send offers, and keep your sublease
              conversations and documents together.
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
              <PasswordLogin
                onSignedIn={(user) => {
                  setUser(user);
                  setLogin(false);
                  const destination = user.role === "admin" ? "admin" : view;
                  setView(destination);
                  setMenu(false);
                  history.replaceState(null, "", "#" + destination);
                  window.scrollTo({ top: 0 });
                  notify("Welcome, " + user.name.split(" ")[0] + ".");
                }}
              />
            )}
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
