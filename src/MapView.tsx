import { useEffect, useRef } from "react";
import L from "leaflet";
import type { Listing } from "../shared/types";
import { money } from "./api";
export default function MapView({
  listings,
  selected,
  onSelect,
}: {
  listings: Listing[];
  selected: string | null;
  onSelect: (l: Listing) => void;
}) {
  const el = useRef<HTMLDivElement>(null),
    map = useRef<L.Map | null>(null),
    layer = useRef<L.LayerGroup | null>(null);
  const select = useRef(onSelect);
  select.current = onSelect;
  useEffect(() => {
    if (!el.current) return;
    const m = L.map(el.current, {
      zoomControl: false,
      scrollWheelZoom: true,
    }).setView([43.038, -76.126], 14);
    map.current = m;
    L.tileLayer(
      import.meta.env.VITE_MAP_TILE_URL ||
        "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
      {
        attribution:
          '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom: 19,
      },
    ).addTo(m);
    L.control.zoom({ position: "bottomright" }).addTo(m);
    layer.current = L.layerGroup().addTo(m);
    L.marker([43.039, -76.135], {
      interactive: false,
      icon: L.divIcon({
        className: "campus-marker",
        html: "<span>SU</span><b>Syracuse University</b>",
        iconSize: [135, 60],
      }),
    }).addTo(m);
    const ro = new ResizeObserver(() => m.invalidateSize());
    ro.observe(el.current);
    return () => {
      ro.disconnect();
      m.remove();
      map.current = null;
    };
  }, []);
  useEffect(() => {
    const g = layer.current;
    if (!g) return;
    g.clearLayers();
    listings.forEach((l) => {
      L.marker([l.lat, l.lng], {
        title: l.title,
        keyboard: true,
        zIndexOffset: selected === l.id ? 1000 : 0,
        icon: L.divIcon({
          className: "price-marker " + (selected === l.id ? "selected" : ""),
          html: `<span>${money(l.price)}</span>`,
          iconSize: [72, 34],
          iconAnchor: [36, 17],
        }),
      })
        .on("click", () => select.current(l))
        .addTo(g);
    });
  }, [listings, selected]);
  return (
    <div
      className="map-canvas"
      ref={el}
      aria-label="Interactive map of Syracuse sublets"
    />
  );
}
