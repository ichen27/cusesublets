import { useState, type FormEvent } from "react";
import { ArrowRight } from "lucide-react";
import type { SeekerRequest } from "../shared/types";
import { api } from "./api";
import { ErrorBox, Modal } from "./ui";

const choices = ["Furnished", "Wi-Fi", "Parking", "Laundry", "Pet friendly"];
export default function PostRequest({ onClose, onCreated, existing }: {
  existing?: SeekerRequest;
  onClose: () => void;
  onCreated: (request: SeekerRequest) => void;
}) {
  const [form, setForm] = useState({
    title: existing?.title || "", description: existing?.description || "", neighborhood: existing?.neighborhood || "", maxBudget: existing ? String(existing.maxBudget) : "",
    roomType: existing?.roomType || "Any", startDate: existing?.startDate || "", endDate: existing?.endDate || "", amenities: existing?.amenities || [] as string[],
  });
  const [busy, setBusy] = useState(false), [error, setError] = useState("");
  const patch = (key: string, value: unknown) => setForm((current) => ({ ...current, [key]: value }));
  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true); setError("");
    try {
      const { request } = await api<{ request: SeekerRequest }>(existing ? `/requests/${encodeURIComponent(existing.id)}` : "/requests", {
        ...form, maxBudget: Number(form.maxBudget), ...(existing ? { status: "active" } : {}),
      });
      onCreated(request);
      onClose();
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return <Modal title={existing ? "Edit your request" : "Post what you’re looking for"} wide onClose={onClose}>
    <form className="request-form" onSubmit={submit}>
      <p className="muted">Tell people with a place what you need. Your request summary is public; contact happens through CuseSublets after sign-in. Your account email and phone are not shown; the details you write here are public.</p>
      <ErrorBox message={error} />
      <label>Request title<input required maxLength={100} value={form.title} onChange={(e) => patch("title", e.target.value)} placeholder="Looking for a spring room near campus" /></label>
      <div className="request-form-grid">
        <label>Move in<input required type="date" value={form.startDate} onChange={(e) => patch("startDate", e.target.value)} /></label>
        <label>Move out<input required type="date" value={form.endDate} onChange={(e) => patch("endDate", e.target.value)} /></label>
        <label>Maximum monthly budget<input required type="number" min="1" max="20000" value={form.maxBudget} onChange={(e) => patch("maxBudget", e.target.value)} placeholder="900" /></label>
        <label>Room type<select value={form.roomType} onChange={(e) => patch("roomType", e.target.value)}><option>Any</option><option>Private room</option><option>Entire place</option></select></label>
      </div>
      <label>Preferred neighborhood <small>(optional)</small><input maxLength={80} value={form.neighborhood} onChange={(e) => patch("neighborhood", e.target.value)} placeholder="Westcott, University Hill…" /></label>
      <fieldset className="request-amenities"><legend>Preferences <small>(optional)</small></legend><div>{choices.map((choice) => <label key={choice}><input type="checkbox" checked={form.amenities.includes(choice)} onChange={(e) => patch("amenities", e.target.checked ? [...form.amenities, choice] : form.amenities.filter((item) => item !== choice))} /> {choice}</label>)}</div></fieldset>
      <label>What else should a host know?<textarea required minLength={20} maxLength={2000} rows={4} value={form.description} onChange={(e) => patch("description", e.target.value)} placeholder="Share the kind of place you need and anything useful about your timing." /></label>
      <div className="request-form-actions"><button type="button" className="outline" onClick={onClose}>Cancel</button><button className="primary" disabled={busy}>{busy ? "Saving…" : existing ? "Save and publish" : "Post request"} <ArrowRight size={16} /></button></div>
    </form>
  </Modal>;
}
