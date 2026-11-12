import "./room-tours.css";
import { lazy, Suspense, useEffect, useState } from "react";
import { api } from "./api";
import type { RoomTour } from "../shared/room-tour";
const SplatViewer = lazy(() => import("./SplatViewer"));
const SpotViewer = lazy(() => import("./SpotViewer"));
export function TourPlayer({
  tour,
  native = false,
}: {
  tour: RoomTour;
  native?: boolean;
}) {
  if (tour.kind === "spots")
    return (
      <section className="room-tour">
        <h3>{tour.name}</h3>
        <p>
          360° photos from the spots where the tour was captured · photos may
          show seams, and the 3D overview is rough. It is not a measured survey
          or a property check.
        </p>
        <Suspense fallback={<p role="status">Loading viewer…</p>}>
          <SpotViewer tour={tour} />
        </Suspense>
        {tour.mesh && !native && (
          <p>
            <a
              href={`/api/listings/${encodeURIComponent(tour.listingId)}/tours/${encodeURIComponent(tour.id)}/mesh`}
              download="room-mesh.ply"
            >
              Export room mesh (PLY)
            </a>
          </p>
        )}
      </section>
    );
  return (
    <section className="room-tour">
      <h3>{tour.name}</h3>
      <p>
        Photographic reconstruction · may contain gaps, blur and distorted
        surfaces. It is not a measured survey or a property check.
      </p>
      <Suspense fallback={<p role="status">Loading viewer…</p>}>
        <SplatViewer tour={tour} />
      </Suspense>
      {native ? (
        <p>
          Use Export Gaussian PLY{tour.mesh ? " or Export room mesh" : ""} on
          the previous screen to save or share this model.
        </p>
      ) : (
        <p>
          <a
            href={`/api/listings/${encodeURIComponent(tour.listingId)}/tours/${encodeURIComponent(tour.id)}/model`}
            download="room.ply"
          >
            Export Gaussian PLY
          </a>
          {tour.mesh && (
            <>
              {" · "}
              <a
                href={`/api/listings/${encodeURIComponent(tour.listingId)}/tours/${encodeURIComponent(tour.id)}/mesh`}
                download="room-mesh.ply"
              >
                Export room mesh (PLY)
              </a>
            </>
          )}
        </p>
      )}
      <p>
        <small>
          The Gaussian PLY is for compatible viewers and Blender importers; it
          is not an editable wall mesh.
          {tour.mesh &&
            " The room mesh is a coloured triangle mesh in metres, Y up, that opens in Blender, MeshLab and most 3D tools. It is reconstructed from photographs, so expect holes and soft edges."}
        </small>
      </p>
    </section>
  );
}
export default function RoomTours({
  listingId,
  owner,
}: {
  listingId: string;
  owner: boolean;
}) {
  const [tours, setTours] = useState<RoomTour[]>([]),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [playing, setPlaying] = useState<string>();
  useEffect(() => {
    let active = true;
    setTours([]);
    setPlaying(undefined);
    setError("");
    api<{ tours: RoomTour[] }>(`/listings/${listingId}/tours`)
      .then((r) => {
        if (active) setTours(r.tours);
      })
      .catch((e) => {
        if (active) setError(e.message);
      });
    return () => {
      active = false;
    };
  }, [listingId, owner]);
  async function visibility(tour: RoomTour) {
    setBusy(true);
    try {
      await api(`/listings/${listingId}/tours/${tour.id}/visibility`, {
        published: !tour.published,
      });
      setTours((items) =>
        items.map((t) =>
          t.id === tour.id ? { ...t, published: !t.published } : t,
        ),
      );
      setError("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  if (!tours.length && !error) return null;
  return (
    <section className="room-scans">
      <h3>Photographic tours</h3>
      {tours.map((t) => (
        <article key={t.id}>
          <h4>
            {t.name} · {t.published ? "Published" : "Private"}
          </h4>
          {t.status === "ready" ? (
            <>
              <button
                onClick={() => setPlaying(playing === t.id ? undefined : t.id)}
              >
                {playing === t.id ? "Close tour" : "Explore tour"}
              </button>
              {playing === t.id && <TourPlayer tour={t} />}{" "}
              {owner && (
                <button disabled={busy} onClick={() => void visibility(t)}>
                  {t.published ? "Hide from listing" : "Publish to listing"}
                </button>
              )}
            </>
          ) : (
            <p>
              {t.status === "failed"
                ? t.error
                : `${t.status} — check progress in the iPhone app.`}
            </p>
          )}
        </article>
      ))}
      {error && <p role="alert">{error}</p>}
    </section>
  );
}
// A same-origin page for WKWebView. Authentication stays in an ephemeral cookie store.
export function NativeTourPage() {
  const query = new URLSearchParams(location.search),
    listing = query.get("listing"),
    id = query.get("tour");
  const [tour, setTour] = useState<RoomTour>(),
    [error, setError] = useState("");
  useEffect(() => {
    let active = true;
    if (!listing || !id) {
      setError("Choose a tour");
      return;
    }
    api<{ tour: RoomTour }>(
      `/listings/${encodeURIComponent(listing)}/tours/${encodeURIComponent(id)}`,
    )
      .then((r) => {
        if (active) {
          if (r.tour.status !== "ready") setError("This tour is not ready");
          else setTour(r.tour);
        }
      })
      .catch((e) => {
        if (active) setError(e.message);
      });
    return () => {
      active = false;
    };
  }, [listing, id]);
  return (
    <main style={{ padding: 16, maxWidth: 1000, margin: "auto" }}>
      {error ? (
        <p role="alert">{error}</p>
      ) : tour ? (
        <TourPlayer tour={tour} native />
      ) : (
        <p role="status">Loading private tour…</p>
      )}
    </main>
  );
}
