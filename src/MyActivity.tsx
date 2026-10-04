import { useCallback, useEffect, useState } from "react";
import { Search, Plus, MapPin, ArrowRight } from "lucide-react";
import type { HousingSearch, Listing, User } from "../shared/types";
import { api, date, money, syracuseToday } from "./api";
import { Busy, ErrorBox } from "./ui";
import SearchEditor from "./SearchEditor";
import HostWorkspace from "./HostWorkspace";

export default function MyActivity({ user, onPost, onListing, onChat, onPublished }: {
  user: User; onPost: () => void; onListing: (listing: Listing) => void;
  onChat: (id: string) => void; onPublished: (listing: Listing) => void;
}) {
  const [search, setSearch] = useState<HousingSearch | null>(null);
  const [loading, setLoading] = useState(true), [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false), [error, setError] = useState("");
  const close = useCallback(() => setEditing(false), []);
  useEffect(() => {
    let current = true;
    api<{ search: HousingSearch | null }>("/my-search")
      .then((result) => { if (current) setSearch(result.search); })
      .catch((cause) => { if (current) setError(cause.message); })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [user.id]);
  const expired = !!search && search.endDate <= syracuseToday();
  const active = search?.status === "active" && !expired;
  async function toggle() {
    if (!search || !search.areas.length || expired) { setEditing(true); return; }
    setBusy(true); setError("");
    try {
      const result = await api<{ search: HousingSearch }>("/my-search/status", { status: active ? "paused" : "active" });
      setSearch(result.search);
    } catch (cause) { setError((cause as Error).message); }
    finally { setBusy(false); }
  }
  return <main className="workspace activity-page">
    <div className="workspace-heading"><div><span className="eyebrow">YOUR HOUSING PLANS</span><h1>My activity</h1><p>Manage your subleases and your search in one place.</p></div><a className="outline" href="#account">Edit profile <ArrowRight size={15} /></a></div>
    <ErrorBox message={error} />
    <section className="panel activity-search" id="my-search">
      <div className="activity-section-heading"><div className="activity-title"><span className="activity-icon"><Search size={22} /></span><div><h2>My search</h2><p>Looking for a place to stay</p></div></div>
        {!loading && <button className={"search-toggle " + (active ? "on" : "")} role="switch" aria-checked={active} aria-label="Looking for a sublease" disabled={busy || search?.status === "removed" || user.suspended} onClick={toggle}><span />{active ? "On" : "Off"}</button>}
      </div>
      {loading ? <Busy /> : search ? <>
        {search.status === "removed" ? <p className="notice">Your search was removed by the review team. It cannot be turned on until staff restores it.</p> : <p className="activity-visibility">{active ? "Visible in Browse and eligible for Top matches." : expired ? "Your dates have passed. Update your search to turn it on again." : "Your search is off and hidden from public discovery."}</p>}
        <div className="activity-search-summary"><div><small>MONTHLY BUDGET</small><strong>{search.minBudget ? money(search.minBudget) + " – " : "Up to "}{money(search.maxBudget)}</strong></div><div><small>YOUR STAY</small><strong>{date(search.startDate)} – {date(search.endDate)}</strong></div><div><small>SPACE</small><strong>{search.roomType === "Any" ? "Flexible on room type" : search.roomType}{search.minBedrooms && search.roomType === "Entire place" ? " · " + search.minBedrooms + "+ beds" : ""}</strong></div></div>
        <p className="activity-areas"><MapPin size={16} />{search.areas.length ? search.areas.map((area) => area.label).join(" · ") : "Choose desired areas to finish setup"}</p>
        {search.introduction && <p>{search.introduction}</p>}
        <div className="button-row">{search.status !== "removed" && <button className="outline" onClick={() => setEditing(true)}>Edit my search</button>}{active && <a className="text-button" href="#matches">View top matches <ArrowRight size={15} /></a>}</div>
      </> : <div className="activity-search-empty"><p>Choose your budget, dates, and desired areas. One search follows your profile, and you can turn it off any time.</p><button className="primary" onClick={() => setEditing(true)}><Plus size={16} /> Set up my search</button></div>}
    </section>
    <HostWorkspace embedded user={user} onSelect={onListing} onPost={onPost} onOpen={onChat} onPublished={onPublished} />
    {editing && <SearchEditor search={search} onSaved={setSearch} onClose={close} />}
  </main>;
}
