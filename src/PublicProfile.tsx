import { useEffect, useState } from "react";
import { ArrowUpRight, UserRound, Star, MapPin } from "lucide-react";
import type {
  PublicProfile as Profile,
  ProfileReview,
  ReviewableBooking,
  Listing,
  User,
} from "../shared/types";
import { api, money, date } from "./api";
import { Busy, Empty, ErrorBox } from "./ui";
import Checks, { IdentityBadge } from "./Checks";
type Data = {
  profile: Profile;
  listings: Listing[];
  reviews: ProfileReview[];
  reviewableBookings: ReviewableBooking[];
};
export default function PublicProfile({
  id,
  user,
  onSelect,
  onEdit,
  onChecks,
}: {
  id: string;
  user: User | null;
  onSelect: (l: Listing) => void;
  onEdit: () => void;
  onChecks: () => void;
}) {
  const [data, setData] = useState<Data | null>(null),
    [error, setError] = useState(""),
    [bookingId, setBookingId] = useState(""),
    [rating, setRating] = useState(5),
    [body, setBody] = useState(""),
    [busy, setBusy] = useState(false);
  useEffect(() => {
    let active = true;
    setData(null);
    setError("");
    api<Data>(`/users/${encodeURIComponent(id)}`)
      .then((d) => {
        if (active) {
          setData(d);
          setBookingId(d.reviewableBookings[0]?.id || "");
        }
      })
      .catch((e) => {
        if (active) setError(e.message);
      });
    return () => {
      active = false;
    };
  }, [id]);
  if (!data)
    return (
      <main className="workspace">
        <ErrorBox message={error} />
        {!error && <Busy />}
      </main>
    );
  const p = data.profile,
    average = data.reviews.length
      ? (
          data.reviews.reduce((sum, r) => sum + r.rating, 0) /
          data.reviews.length
        ).toFixed(1)
      : null;
  return (
    <main className="workspace public-profile">
      <ErrorBox message={error} />
      <section className="public-profile-hero">
        <div className="profile-portrait large">
          {p.avatar ? (
            <img src={p.avatar} alt={p.name} />
          ) : (
            <UserRound size={52} />
          )}
        </div>
        <div>
          <span className="eyebrow">YOUR SYRACUSE COMMUNITY</span>
          <h1>Meet {p.name}.</h1>
          <div className="profile-badges">
            <IdentityBadge status={p.identity} />
            {average && (
              <span>
                <Star size={15} /> {average} · {data.reviews.length} review
                {data.reviews.length === 1 ? "" : "s"}
              </span>
            )}
          </div>
        </div>
        {user?.id === id && (
          <button className="outline small" onClick={onEdit}>
            Edit my profile <ArrowUpRight size={14} />
          </button>
        )}
      </section>
      <div className="public-profile-layout">
        <section>
          <div className="panel">
            <h2>A little about {p.name.split(" ")[0]}</h2>
            <p className="profile-bio">
              {p.bio || "This member hasn’t added an introduction yet."}
            </p>
            <div className="social-links">
              {Object.entries(p.socials || {})
                .filter(([, url]) => url)
                .map(([label, url]) => (
                  <a
                    key={label}
                    href={url}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    {label === "linkedin"
                      ? "LinkedIn"
                      : label[0].toUpperCase() + label.slice(1)}
                    <ArrowUpRight size={14} />
                  </a>
                ))}
            </div>
            {p.photos.length > 0 && (
              <div className="public-gallery">
                {p.photos.map((url) => (
                  <img key={url} src={url} alt={`${p.name}'s profile photo`} />
                ))}
              </div>
            )}
          </div>
          <section className="profile-listings">
            <div className="section-heading">
              <h2>{p.name.split(" ")[0]}’s listings</h2>
              <span>{data.listings.length} places</span>
            </div>
            {data.listings.length ? (
              data.listings.map((l) => (
                <button
                  className="profile-listing"
                  key={l.id}
                  onClick={() => onSelect(l)}
                >
                  <img src={l.images[0] || "/photo-pending.svg"} alt="" />
                  <span>
                    <b>{l.title}</b>
                    <small>
                      <MapPin size={12} />
                      {l.neighborhood} · {l.roomType}
                    </small>
                    <small>
                      {date(l.startDate)} – {date(l.endDate)}
                    </small>
                  </span>
                  <strong>
                    {money(l.price)}
                    <small>/ month</small>
                  </strong>
                  <ArrowUpRight size={16} />
                </button>
              ))
            ) : (
              <Empty title="No available listings right now.">
                Check back for the next place.
              </Empty>
            )}
          </section>
          <section className="panel">
            <div className="section-heading">
              <h2>Reviews from completed leases</h2>
              {average && <b>★ {average}</b>}
            </div>
            <p className="muted">
              Reviews can only be left by the other participant after an
              eligible lease has finished.
            </p>
            {data.reviews.length ? (
              data.reviews.map((r) => (
                <article className="profile-review" key={r.id}>
                  <div>
                    <b>{r.authorName}</b>
                    <span aria-label={`${r.rating} out of 5 stars`}>
                      {"★".repeat(r.rating)}
                      {"☆".repeat(5 - r.rating)}
                    </span>
                  </div>
                  <small>
                    {r.listingTitle} ·{" "}
                    {new Date(r.createdAt).toLocaleDateString()}
                  </small>
                  <p>{r.body}</p>
                </article>
              ))
            ) : (
              <div className="review-empty">
                <Star size={26} />
                <h3>A fresh start.</h3>
                <p>No completed-lease reviews yet.</p>
              </div>
            )}
            {data.reviewableBookings.length > 0 && (
              <form
                className="form-stack review-form"
                onSubmit={async (e) => {
                  e.preventDefault();
                  setBusy(true);
                  setError("");
                  try {
                    await api(`/users/${encodeURIComponent(id)}/reviews`, {
                      bookingId,
                      rating,
                      body,
                    });
                    const next = await api<Data>(
                      `/users/${encodeURIComponent(id)}`,
                    );
                    setData(next);
                    setBookingId(next.reviewableBookings[0]?.id || "");
                    setBody("");
                  } catch (e) {
                    setError((e as Error).message);
                  } finally {
                    setBusy(false);
                  }
                }}
              >
                <h3>Share your experience</h3>
                <label>
                  Completed lease
                  <select
                    value={bookingId}
                    onChange={(e) => setBookingId(e.target.value)}
                    required
                  >
                    {data.reviewableBookings.map((b) => (
                      <option key={b.id} value={b.id}>
                        {b.listingTitle} · ended {date(b.endDate)}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  Rating
                  <select
                    value={rating}
                    onChange={(e) => setRating(Number(e.target.value))}
                  >
                    {[5, 4, 3, 2, 1].map((n) => (
                      <option key={n} value={n}>
                        {n} star{n === 1 ? "" : "s"}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  Your review
                  <textarea
                    value={body}
                    onChange={(e) => setBody(e.target.value)}
                    minLength={10}
                    maxLength={2000}
                    required
                  />
                </label>
                <button className="primary" disabled={busy}>
                  Publish review
                </button>
              </form>
            )}
          </section>
        </section>
        <aside>
          <Checks identity={p.identity} onLearn={onChecks} />
          <div className="profile-trust-note">
            <h3>Get to know each other.</h3>
            <p>
              Start with a conversation about the place. Ask about dates,
              housemates and permission to sublet, and keep important details in
              chat.
            </p>
            <p>
              Public profiles never show private ID documents, email addresses
              or phone numbers.
            </p>
          </div>
        </aside>
      </div>
    </main>
  );
}
