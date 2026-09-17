import { useEffect, useRef } from "react";
import L from "leaflet";
export default function MapPicker({
  onPick,
}: {
  onPick: (lat: number, lng: number) => void;
}) {
  const el = useRef<HTMLDivElement>(null),
    callback = useRef(onPick);
  callback.current = onPick;
  useEffect(() => {
    if (!el.current) return;
    const m = L.map(el.current, { scrollWheelZoom: false }).setView(
      [43.035, -76.127],
      13,
    );
    L.tileLayer(
      import.meta.env.VITE_MAP_TILE_URL ||
        "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
      {
        attribution:
          '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom: 18,
      },
    ).addTo(m);
    let marker: L.Marker | undefined;
    m.on("click", (e: L.LeafletMouseEvent) => {
      const { lat, lng } = e.latlng;
      if (lat < 42.9 || lat > 43.15 || lng < -76.3 || lng > -75.95) return;
      if (marker) marker.setLatLng(e.latlng);
      else
        marker = L.marker(e.latlng, {
          icon: L.divIcon({
            className: "price-marker selected",
            html: "<span>Your place</span>",
            iconSize: [92, 34],
          }),
        }).addTo(m);
      callback.current(
        Math.round(lat * 1000) / 1000,
        Math.round(lng * 1000) / 1000,
      );
    });
    const r = new ResizeObserver(() => m.invalidateSize());
    r.observe(el.current);
    return () => {
      r.disconnect();
      m.remove();
    };
  }, []);
  return (
    <div
      ref={el}
      style={{ height: 220, borderRadius: 8, overflow: "hidden" }}
      role="application"
      aria-label="Choose approximate listing location by clicking the Syracuse map"
    />
  );
}
