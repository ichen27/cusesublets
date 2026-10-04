import { useEffect, useRef, useState } from "react";
import L from "leaflet";
import { SERVICE_BOUNDS, validateAreas, type GeoPoint, type SearchArea } from "../shared/geo";

export default function SearchAreaPicker({ value, onChange }: {
  value: SearchArea[];
  onChange: (areas: SearchArea[]) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const layer = useRef<L.LayerGroup | null>(null);
  const [draft, setDraft] = useState<GeoPoint[]>([]);
  const [label, setLabel] = useState("");
  const [error, setError] = useState("");
  const draftRef = useRef(draft);
  draftRef.current = draft;
  useEffect(() => {
    if (!el.current) return;
    const m = L.map(el.current, { scrollWheelZoom: false }).setView([43.038, -76.126], 13);
    map.current = m;
    L.tileLayer(import.meta.env.VITE_MAP_TILE_URL || "https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 18,
    }).addTo(m);
    layer.current = L.layerGroup().addTo(m);
    m.on("click", (event: L.LeafletMouseEvent) => {
      const { lat, lng } = event.latlng;
      if (lat < SERVICE_BOUNDS.south || lat > SERVICE_BOUNDS.north ||
          lng < SERVICE_BOUNDS.west || lng > SERVICE_BOUNDS.east) {
        setError("Choose points inside the Syracuse service area.");
        return;
      }
      if (draftRef.current.length >= 25) { setError("Use at most 25 points."); return; }
      setDraft((points) => [...points, { lat: +lat.toFixed(5), lng: +lng.toFixed(5) }]);
      setError("");
    });
    const resize = new ResizeObserver(() => m.invalidateSize());
    resize.observe(el.current);
    return () => { resize.disconnect(); m.remove(); map.current = null; layer.current = null; };
  }, []);
  useEffect(() => {
    const group = layer.current;
    if (!group) return;
    group.clearLayers();
    value.forEach((area) => {
      const tooltip = document.createElement("span"); tooltip.textContent = area.label;
      L.polygon(area.points.map((p) => [p.lat, p.lng] as [number, number]), {
      color: "#bb5d32", fillColor: "#f5a977", fillOpacity: 0.28, weight: 2,
    }).bindTooltip(tooltip).addTo(group);
    });
    if (draft.length) {
      L.polyline(draft.map((p) => [p.lat, p.lng] as [number, number]), { color: "#304f47", dashArray: "5 5" }).addTo(group);
      draft.forEach((p) => L.circleMarker([p.lat, p.lng], { radius: 5, color: "#304f47", fillOpacity: 1 }).addTo(group));
    }
  }, [value, draft]);
  function add(points: GeoPoint[]) {
    try {
      const next = validateAreas([...value, { id: crypto.randomUUID(), label: label.trim() || `Area ${value.length + 1}`, points }]);
      onChange(next); setDraft([]); setLabel(""); setError("");
    } catch (cause) { setError((cause as Error).message); }
  }
  function visibleArea() {
    const b = map.current?.getBounds();
    if (!b) return;
    const south = Math.max(SERVICE_BOUNDS.south, b.getSouth());
    const north = Math.min(SERVICE_BOUNDS.north, b.getNorth());
    const west = Math.max(SERVICE_BOUNDS.west, b.getWest());
    const east = Math.min(SERVICE_BOUNDS.east, b.getEast());
    if (south >= north || west >= east) { setError("Move the map over Syracuse first."); return; }
    add([{ lat: south, lng: west }, { lat: south, lng: east }, { lat: north, lng: east }, { lat: north, lng: west }]);
  }
  return <div className="search-area-picker">
    <p>Tap points around an area, or add the visible map. These regions show where you want to live, not where you live now.</p>
    <div ref={el} className="search-area-map" role="application" aria-label="Draw desired Syracuse areas on the map" />
    <div className="search-area-controls">
      <label>Area name <input value={label} maxLength={80} placeholder="e.g. Near campus" onChange={(e) => setLabel(e.target.value)} /></label>
      <button type="button" className="outline small" onClick={() => add(draft)} disabled={draft.length < 3 || value.length >= 5}>Finish area ({draft.length} points)</button>
      <button type="button" className="outline small" onClick={visibleArea} disabled={value.length >= 5}>Add visible area</button>
      <button type="button" className="text-button" disabled={!draft.length} onClick={() => setDraft((points) => points.slice(0, -1))}>Undo point</button>
    </div>
    {error && <p className="field-error" role="alert">{error}</p>}
    <div className="selected-areas">
      <strong>Desired areas ({value.length}/5)</strong>
      {value.length ? value.map((area) => <div className="selected-area" key={area.id}>
        <input aria-label={`Name for ${area.label}`} value={area.label} maxLength={80} onChange={(e) => onChange(value.map((item) => item.id === area.id ? { ...item, label: e.target.value } : item))} />
        <button type="button" className="text-button" onClick={() => map.current?.fitBounds(L.latLngBounds(area.points.map((p) => [p.lat, p.lng] as [number, number])), { padding: [20, 20] })}>Inspect</button>
        <button type="button" className="text-button" onClick={() => { onChange(value.filter((item) => item.id !== area.id)); setLabel(area.label); setDraft([]); }}>Redraw</button>
        <button type="button" className="text-button" onClick={() => onChange(value.filter((item) => item.id !== area.id))}>Remove</button>
      </div>) : <small>No areas selected yet. Add at least one.</small>}
    </div>
  </div>;
}
