import { useEffect, useState } from "react";
import { api } from "./api";
import type { RoomElement, RoomScan } from "../shared/room-scan";
function outline(e: RoomElement) {
  const [width, , depth] = e.dimensions,
    t = e.transform;
  return [
    [-width / 2, -Math.max(depth, 0.04) / 2],
    [width / 2, -Math.max(depth, 0.04) / 2],
    [width / 2, Math.max(depth, 0.04) / 2],
    [-width / 2, Math.max(depth, 0.04) / 2],
  ].map(([x, z]) => [
    t[0] * x + t[8] * z + t[12],
    t[2] * x + t[10] * z + t[14],
  ]);
}
export default function RoomScans({
  listingId,
  owner,
}: {
  listingId: string;
  owner: boolean;
}) {
  const [scans, setScans] = useState<RoomScan[]>([]),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  useEffect(() => {
    let active = true;
    setScans([]);
    setError("");
    void api<{ scans: RoomScan[] }>(`/listings/${listingId}/scans`)
      .then((r) => {
        if (active) setScans(r.scans);
      })
      .catch((e) => {
        if (active) setError(e.message);
      });
    return () => {
      active = false;
    };
  }, [listingId, owner]);
  if (!scans.length && !owner && !error) return null;
  async function visibility(scan: RoomScan) {
    setBusy(true);
    try {
      await api(`/listings/${listingId}/scans/${scan.id}/visibility`, {
        published: !scan.published,
      });
      setScans((current) =>
        current.map((s) =>
          s.id === scan.id ? { ...s, published: !s.published } : s,
        ),
      );
      setError("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="room-scans">
      <h3>Room layouts</h3>
      <p>
        Approximate captured geometry, not a measured survey or a photographic
        tour. Room scans do not grant verification.
      </p>
      {error && <p role="alert">{error}</p>}
      {owner && !scans.length && (
        <p>
          Use the CuseSublets iPhone app to capture a room. Scans stay private
          until you publish them.
        </p>
      )}
      {scans.map((scan) => {
        const shapes = scan.layout.elements
          .filter((e) => e.kind !== "opening")
          .map((e) => ({ kind: e.kind, points: outline(e) }));
        const points = shapes.flatMap((s) => s.points),
          xs = points.map((p) => p[0]),
          zs = points.map((p) => p[1]);
        const x = Math.min(...xs) - 0.5,
          z = Math.min(...zs) - 0.5,
          w = Math.max(...xs) - x + 0.5,
          h = Math.max(...zs) - z + 0.5;
        return (
          <figure key={scan.id}>
            <figcaption>
              <strong>{scan.name}</strong>
              {owner && (
                <span> · {scan.published ? "Published" : "Private"}</span>
              )}
            </figcaption>
            <svg
              viewBox={`${x} ${z} ${w} ${h}`}
              role="img"
              aria-label={`Approximate overhead layout of ${scan.name}`}
              style={{
                width: "100%",
                height: 260,
                background: "#f8f3e9",
                borderRadius: 12,
              }}
            >
              {shapes.map((s, i) => (
                <polygon
                  key={i}
                  points={s.points.map((p) => p.join(",")).join(" ")}
                  fill={
                    s.kind === "object"
                      ? "#b7b1a9"
                      : s.kind === "wall"
                        ? "#d55b25"
                        : "#4c8b91"
                  }
                  stroke="#494641"
                  strokeWidth={0.015}
                />
              ))}
            </svg>
            {owner && (
              <button
                className="outline small"
                disabled={busy}
                onClick={() => void visibility(scan)}
              >
                {scan.published ? "Hide from listing" : "Publish to listing"}
              </button>
            )}
          </figure>
        );
      })}
    </section>
  );
}
