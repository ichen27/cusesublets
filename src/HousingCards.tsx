import { ArrowRight, CalendarDays, Heart, MapPin, MessageCircle, UserRound } from "lucide-react";
import type { HousingSearch, Listing } from "../shared/types";
import { date, money } from "./api";
export function PlaceCard({ listing, saved, onSave, onOpen, reasons }: {
  listing: Listing; saved: boolean; onSave: () => void; onOpen: () => void; reasons?: string[];
}) {
  return <article className="housing-card place-card">
    <div className="housing-photo"><button className="housing-photo-link" onClick={onOpen} aria-label={"View " + listing.title}><img src={listing.images[0] || "/photo-pending.svg"} alt={listing.title} loading="lazy" /></button><span className="housing-type">Available sublet</span><button className={"post-save-button " + (saved ? "saved" : "")} aria-label={(saved ? "Unsave " : "Save ") + listing.title} onClick={onSave}><Heart size={17} fill={saved ? "currentColor" : "none"} /></button></div>
    <div className="housing-card-body"><div className="housing-price">{money(listing.price)}<small> / month</small></div><button className="housing-title" onClick={onOpen}><h3>{listing.title}</h3></button><p className="housing-location"><MapPin size={14} />{listing.neighborhood}</p><div className="housing-facts"><span>{listing.roomType} · {listing.beds} bed{listing.beds === 1 ? "" : "s"}</span><span><CalendarDays size={14} />{date(listing.startDate)} – {date(listing.endDate)}</span></div>{reasons && <Reasons reasons={reasons} />}<button className="housing-card-link" onClick={onOpen}>View place <ArrowRight size={15} /></button></div>
  </article>;
}
export function PersonCard({ search, selected, onAreas, onProfile, onContact, onReport, own, reasons }: {
  search: HousingSearch; selected?: boolean; onAreas: () => void; onProfile: () => void;
  onContact: () => void; onReport: () => void; own?: boolean; reasons?: string[];
}) {
  return <article className={"housing-card person-card " + (selected ? "selected" : "")}>
    <div className="person-card-top"><span className="post-type seeker-type"><UserRound size={13} /> Looking for a place</span><span className="search-live-dot" title="Search is on" /></div>
    <button className="person-heading" onClick={onProfile}><span className="person-portrait">{search.ownerName.slice(0, 1)}</span><span><h3>{search.ownerName}</h3><small>Looking for a sublease</small></span></button>
    <div className="housing-price">{search.minBudget ? money(search.minBudget) + " – " : "Up to "}{money(search.maxBudget)}<small> / month</small></div>
    <p className="person-introduction">{search.introduction || "Exploring places for their next stay in Syracuse."}</p>
    <div className="housing-facts"><span><CalendarDays size={14} />{date(search.startDate)} – {date(search.endDate)}</span><span>{search.roomType === "Any" ? "Flexible on room type" : search.roomType}{search.minBedrooms && search.roomType === "Entire place" ? " · " + search.minBedrooms + "+ beds" : ""}</span></div>
    <button className="person-areas" onClick={onAreas}><MapPin size={15} /><span>{search.areas.map((area) => area.label).join(" · ")}</span><ArrowRight size={14} /></button>
    {search.requiredAmenities.length > 0 && <div className="post-tags">{search.requiredAmenities.slice(0, 4).map((item) => <span key={item}>{item}</span>)}</div>}
    {reasons && <Reasons reasons={reasons} />}
    <div className="person-card-actions"><button className="text-button" onClick={onProfile}>View profile</button>{!own && <button className="outline small" onClick={onContact}><MessageCircle size={14} /> Contact</button>}</div>
    {!own && <button className="person-report" onClick={onReport}>Report search</button>}
  </article>;
}
function Reasons({ reasons }: { reasons: string[] }) {
  return <div className="housing-reasons"><strong>Why it fits</strong>{reasons.map((reason) => <span key={reason}>✓ {reason}</span>)}</div>;
}
