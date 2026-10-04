import LegacyBookmarks from "./LegacyBookmarks";
import { useEffect, useState } from "react";
import type { HousingSearch, Listing, User } from "../shared/types";
import { api } from "./api";
import CommunityPost from "./CommunityPost";
import { Busy, Empty, ErrorBox } from "./ui";
type Saved = {
  targetType: "listing" | "search";
  targetId: string;
  available: boolean;
  savedAt: string;
};
export default function SavedPosts({
  user,
  listings,
  onListing,
  onProfile,
  onLogin,
}: {
  user: User | null;
  listings: Listing[];
  onListing: (l: Listing) => void;
  onProfile: (id: string) => void;
  onLogin: () => void;
}) {
  const [items, setItems] = useState<Saved[]>([]),
    [searches, setSearches] = useState<HousingSearch[]>([]),
    [cursor, setCursor] = useState<string | null>(null),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(true);
  async function load(more = false) {
    if (!user) {
      setLoading(false);
      return;
    }
    try {
      const [s, p] = await Promise.all([
        api<{ items: Saved[]; nextCursor: string | null }>(
          "/social/saved" +
            (more && cursor ? "?cursor=" + encodeURIComponent(cursor) : ""),
        ),
        api<{ searches: HousingSearch[] }>("/searches"),
      ]);
      setItems((old) => (more ? [...old, ...s.items] : s.items));
      setCursor(s.nextCursor);
      setSearches(p.searches);
      setError("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => {
    void load();
    const update = () => void load();
    window.addEventListener("social-saved-changed", update);
    return () => window.removeEventListener("social-saved-changed", update);
  }, [user?.id]);
  return (
    <main className="saved-community">
      <span className="eyebrow">PRIVATE TO YOU</span>
      <h1>Worth coming back to.</h1>
      <p>Your saved places and people, all together.</p>
      <ErrorBox message={error} />
      {user && <LegacyBookmarks listings={listings} />}
      {!user ? (
        <Empty title="Sign in to see your saved posts.">
          <button className="primary" onClick={onLogin}>
            Log in
          </button>
        </Empty>
      ) : loading ? (
        <Busy />
      ) : !items.length ? (
        <Empty title="Your shortlist starts here.">
          Tap the bookmark on any community post.
          <a className="primary" href="#browse">
            Browse the community
          </a>
        </Empty>
      ) : (
        items.map((s) => {
          const l =
            s.targetType === "listing"
              ? listings.find((l) => l.id === s.targetId)
              : undefined;
          const person =
            s.targetType === "search"
              ? searches.find((p) => p.id === s.targetId)
              : undefined;
          return s.available && (l || person) ? (
            <CommunityPost
              key={s.targetType + s.targetId}
              listing={l}
              search={person}
              user={user}
              onOpen={() => l && onListing(l)}
              onAreas={() => person && onProfile(person.ownerId)}
              onProfile={onProfile}
              onLogin={onLogin}
            />
          ) : (
            <article
              key={s.targetType + s.targetId}
              className="panel unavailable-saved"
            >
              <h3>
                This {s.targetType === "listing" ? "place" : "search"} is
                currently unavailable.
              </h3>
              <p>It may be paused, expired, or removed.</p>
              <button
                className="text-button"
                onClick={async () => {
                  try {
                    await api(
                      `/social/${s.targetType}/${encodeURIComponent(s.targetId)}/save`,
                      { saved: false },
                    );
                    window.dispatchEvent(new Event("social-saved-changed"));
                  } catch (e) {
                    setError((e as Error).message);
                  }
                }}
              >
                Remove bookmark
              </button>
            </article>
          );
        })
      )}
      {cursor && (
        <button className="outline" onClick={() => void load(true)}>
          Load more saved posts
        </button>
      )}
    </main>
  );
}
