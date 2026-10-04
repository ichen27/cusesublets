import { useState, type FormEvent } from "react";
import type { Listing } from "../shared/types";
import { api } from "./api";
import { Modal, ErrorBox } from "./ui";
export default function ListingEditor({ listing, onClose, onSaved }: { listing: Listing; onClose: () => void; onSaved: (listing: Listing) => void }) {
  const [form, setForm] = useState({ title: listing.title, description: listing.description, price: listing.price, startDate: listing.startDate, endDate: listing.endDate, amenities: listing.amenities.join(", ") });
  const [busy, setBusy] = useState(false), [error, setError] = useState("");
  async function submit(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError("");
    try {
      const result = await api<{ listing: Listing }>("/listings/" + listing.id, { ...form, amenities: form.amenities.split(",").map((item) => item.trim()).filter(Boolean) });
      onSaved(result.listing); onClose();
    } catch (cause) { setError((cause as Error).message); }
    finally { setBusy(false); }
  }
  return <Modal title="Edit my sublease" onClose={onClose}><form className="request-form" onSubmit={submit}>
    <ErrorBox message={error} />
    <label>Title<input required maxLength={100} value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} /></label>
    <label>Monthly rent<input required type="number" min="1" max="20000" value={form.price} onChange={(e) => setForm({ ...form, price: Number(e.target.value) })} /></label>
    <div className="request-form-grid"><label>Available from<input required type="date" value={form.startDate} onChange={(e) => setForm({ ...form, startDate: e.target.value })} /></label><label>Available until<input required type="date" min={form.startDate} value={form.endDate} onChange={(e) => setForm({ ...form, endDate: e.target.value })} /></label></div>
    <label>Description<textarea required minLength={20} maxLength={4000} rows={5} value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} /></label>
    <label>Amenities <small>Separate with commas</small><input value={form.amenities} onChange={(e) => setForm({ ...form, amenities: e.target.value })} /></label>
    <div className="request-form-actions"><button type="button" className="outline" onClick={onClose}>Cancel</button><button className="primary" disabled={busy}>{busy ? "Saving…" : "Save changes"}</button></div>
  </form></Modal>;
}
