import {
  MapPin,
  CalendarDays,
  ArrowRight,
  ShieldCheck,
  Home,
  Flag,
} from "lucide-react";
import type { HousingSearch, Listing, User } from "../shared/types";
import { date, money } from "./api";
import SocialActions from "./SocialActions";
export function PersonAvatar({ name, src }: { name: string; src?: string }) {
  return (
    <span className="person-avatar">
      {src ? (
        <img src={src} alt="" />
      ) : (
        name
          .split(" ")
          .map((s) => s[0])
          .slice(0, 2)
          .join("")
      )}
    </span>
  );
}
function timestamp(value?: string | null) {
  if (!value) return "Community listing";
  const d = new Date(value);
  return Number.isNaN(d.valueOf())
    ? "Community listing"
    : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}
export function ListingChecks({ listing }: { listing: Listing }) {
  return (
    <a href="#checks" className="post-check">
      <ShieldCheck size={14} />
      {listing.leaseStatus === "verified" &&
      listing.permissionStatus === "verified"
        ? "Lease & permission checked"
        : listing.leaseStatus === "verified"
          ? "Lease checked"
          : "Documents not checked"}
    </a>
  );
}
export default function CommunityPost({
  listing,
  search,
  user,
  onOpen,
  onProfile,
  onContact,
  onAreas,
  onReport,
  onLogin,
  fit = false,
}: {
  listing?: Listing;
  search?: HousingSearch;
  user: User | null;
  onOpen?: () => void;
  onProfile: (id: string) => void;
  onContact?: () => void;
  onAreas?: () => void;
  onReport?: () => void;
  onLogin: () => void;
  fit?: boolean;
}) {
  const ownerId = listing?.ownerId || search!.ownerId,
    name = listing?.hostName || search!.ownerName;
  return (
    <article
      className={"community-post " + (search ? "seeker-post" : "place-post")}
    >
      <header className="post-heading">
        <button className="post-person" onClick={() => onProfile(ownerId)}>
          <PersonAvatar name={name} />
          <span>
            <strong>{name}</strong>
            <small>
              <span
                className={"role-pill " + (search ? "seeking" : "offering")}
              >
                {search ? "Looking for a place" : "Offering a place"}
              </span>{" "}
              · {timestamp(listing?.createdAt || search?.createdAt)}
            </small>
          </span>
        </button>
        {onReport && (
          <button
            className="icon-button"
            aria-label="Report search"
            onClick={onReport}
          >
            <Flag size={15} />
          </button>
        )}
        {fit && <span className="post-fit">Fits your plans</span>}
      </header>
      <p className="post-intro">
        {listing?.description ||
          search?.introduction ||
          (search
            ? "Looking for a place to call home in Syracuse."
            : listing?.title)}
      </p>
      {listing ? (
        <>
          <button
            className="post-photo"
            onClick={onOpen}
            aria-label={"View " + listing.title}
          >
            {listing.images[0] ? (
              <img src={listing.images[0]} alt={listing.title} loading="lazy" />
            ) : (
              <span className="photo-placeholder">
                <Home size={44} />
                {listing.title}
              </span>
            )}
            <span>{listing.roomType}</span>
          </button>
          <div className="post-facts">
            <strong>
              {money(listing.price)} <small>/ month</small>
            </strong>
            <span>
              <CalendarDays size={15} />
              {date(listing.startDate)} – {date(listing.endDate)}
            </span>
            <span>
              <MapPin size={15} />
              {listing.neighborhood}
            </span>
          </div>
          <div className="post-subline">
            <ListingChecks listing={listing} />
            <button className="text-button" onClick={onOpen}>
              View place <ArrowRight size={14} />
            </button>
          </div>
        </>
      ) : (
        <>
          <div className="seeker-facts">
            <span>
              MONTHLY BUDGET
              <strong>
                {search!.minBudget
                  ? money(search!.minBudget) + " – "
                  : "Up to "}
                {money(search!.maxBudget)}
              </strong>
            </span>
            <span>
              MY STAY
              <strong>
                {date(search!.startDate)} – {date(search!.endDate)}
              </strong>
            </span>
            <span>
              MY SPACE
              <strong>
                {search!.roomType === "Any"
                  ? "Open to room or apartment"
                  : search!.roomType}
              </strong>
            </span>
          </div>
          <button className="desired-area" onClick={onAreas}>
            <MapPin size={19} />
            <span>
              <small>WHERE I’D LIKE TO LIVE</small>
              {search!.areas.map((a) => a.label).join(" · ")}
            </span>
            <ArrowRight size={16} />
          </button>
          <a
            className="text-button view-search-post"
            href={"#search/" + encodeURIComponent(search!.id)}
          >
            View search <ArrowRight size={14} />
          </a>
          <div className="condition-tags">
            {search!.requiredAmenities.map((a) => (
              <span key={a}>{a}</span>
            ))}
          </div>
        </>
      )}
      <SocialActions
        targetType={listing ? "listing" : "search"}
        targetId={(listing || search)!.id}
        user={user}
        onLogin={onLogin}
        onProfile={onProfile}
      />
      {ownerId !== user?.id && onContact && (
        <button className="text-button post-message" onClick={onContact}>
          {listing ? "Message host" : "Introduce your place"}
          <ArrowRight size={15} />
        </button>
      )}
    </article>
  );
}
