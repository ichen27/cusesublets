import { useState, type FormEvent } from "react";
import type { HousingSearch } from "../shared/types";
import { api } from "./api";
import { ErrorBox, Modal } from "./ui";
import SearchAreaPicker from "./SearchAreaPicker";

const conditions = ["Furnished", "Wi-Fi", "Laundry", "Kitchen", "Parking", "Near campus", "Pets allowed", "Accessible"];
export default function SearchEditor({ search, onSaved, onClose }: {
  search: HousingSearch | null;
  onSaved: (search: HousingSearch) => void;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState({
    startDate: search?.startDate || "", endDate: search?.endDate || "",
    minBudget: search?.minBudget?.toString() || "", maxBudget: search?.maxBudget?.toString() || "",
    minBedrooms: search?.minBedrooms?.toString() || "", roomType: search?.roomType || "Any",
    requiredAmenities: search?.requiredAmenities || [], preferredAmenities: search?.preferredAmenities || [],
    areas: search?.areas || [], introduction: search?.introduction || "",
  });
  const [error, setError] = useState(""), [busy, setBusy] = useState(false);
  const [activate, setActivate] = useState(search?.status === "active" || !search);
  async function save(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError("");
    try {
      let result = await api<{ search: HousingSearch }>("/my-search", {
        ...draft, minBudget: draft.minBudget ? Number(draft.minBudget) : undefined,
        maxBudget: Number(draft.maxBudget), minBedrooms: draft.minBedrooms ? Number(draft.minBedrooms) : undefined,
      });
      const status = activate ? "active" : "paused";
      if (result.search.status !== status) result = await api<{ search: HousingSearch }>("/my-search/status", { status });
      onSaved(result.search); onClose();
    } catch (cause) { setError((cause as Error).message); }
    finally { setBusy(false); }
  }
  function toggle(key: "requiredAmenities" | "preferredAmenities", condition: string) {
    setDraft((current) => ({ ...current, [key]: current[key].includes(condition) ? current[key].filter((item) => item !== condition) : [...current[key], condition] }));
  }
  return <Modal title={search ? "Edit my search" : "Set up my search"} onClose={onClose} wide>
    <form className="request-form search-editor" onSubmit={save}>
      <p>Tell us what would work for your stay. When your search is on, your criteria, desired areas, and introduction appear in Browse and Top matches.</p>
      <ErrorBox message={error} />
      <div className="request-form-grid">
        <label>Move-in date<input type="date" required value={draft.startDate} onChange={(e) => setDraft({ ...draft, startDate: e.target.value })} /></label>
        <label>Move-out date<input type="date" required min={draft.startDate} value={draft.endDate} onChange={(e) => setDraft({ ...draft, endDate: e.target.value })} /></label>
        <label>Minimum rent / month <small>Optional</small><input type="number" min="1" max="20000" placeholder="No minimum" value={draft.minBudget} onChange={(e) => setDraft({ ...draft, minBudget: e.target.value })} /></label>
        <label>Maximum rent / month<input type="number" required min="1" max="20000" placeholder="e.g. 900" value={draft.maxBudget} onChange={(e) => setDraft({ ...draft, maxBudget: e.target.value })} /></label>
        <label>Room type<select value={draft.roomType} onChange={(e) => setDraft({ ...draft, roomType: e.target.value as HousingSearch["roomType"] })}><option>Any</option><option>Private room</option><option>Entire place</option></select></label>
        {draft.roomType === "Entire place" && <label>Minimum bedrooms <small>Optional</small><input type="number" min="1" max="20" step="1" value={draft.minBedrooms} onChange={(e) => setDraft({ ...draft, minBedrooms: e.target.value })} /></label>}
      </div>
      <fieldset className="request-amenities"><legend>Required conditions</legend><small>Every match must include these.</small><div>{conditions.map((item) => <label key={item}><input type="checkbox" checked={draft.requiredAmenities.includes(item)} onChange={() => toggle("requiredAmenities", item)} />{item}</label>)}</div></fieldset>
      <fieldset className="request-amenities"><legend>Nice to have</legend><small>These help order your matches.</small><div>{conditions.map((item) => <label key={item}><input type="checkbox" checked={draft.preferredAmenities.includes(item)} onChange={() => toggle("preferredAmenities", item)} />{item}</label>)}</div></fieldset>
      <section><h3>Where would you like to stay?</h3><SearchAreaPicker value={draft.areas} onChange={(areas) => setDraft({ ...draft, areas })} /></section>
      <label>Public introduction <small>Optional · Keep contact details out of your introduction.</small><textarea maxLength={500} rows={3} value={draft.introduction} onChange={(e) => setDraft({ ...draft, introduction: e.target.value })} /></label>
      <label className="search-visibility"><input type="checkbox" checked={activate} onChange={(e) => setActivate(e.target.checked)} />Turn on my search after saving</label>
      <small>Your account email, phone number, and identity documents stay private.</small>
      <div className="request-form-actions"><button type="button" className="outline" onClick={onClose}>Cancel</button><button className="primary" disabled={busy}>{busy ? "Saving…" : activate ? "Save and turn on" : "Save search off"}</button></div>
    </form>
  </Modal>;
}
