import { useState, type FormEvent } from "react";
import { ArrowLeft, ArrowRight, Check, Search } from "lucide-react";
import type { HousingSearch } from "../shared/types";
import type { SearchDraftData } from "../shared/drafts";
import { api, money } from "./api";
import { ErrorBox, Modal } from "./ui";
import SearchAreaPicker from "./SearchAreaPicker";
import { usePrivateDraft } from "./usePrivateDraft";
const conditions = [
  "Furnished",
  "Wi-Fi",
  "Laundry",
  "Kitchen",
  "Parking",
  "Near campus",
  "Pets allowed",
  "Accessible",
];
const steps = [
  "Dates & budget",
  "Your space",
  "Your neighborhoods",
  "Introduce yourself",
];
export default function SearchEditor({
  search,
  onSaved,
  onClose,
}: {
  search: HousingSearch | null;
  onSaved: (search: HousingSearch) => void;
  onClose: () => void;
}) {
  const [form, setForm] = useState<SearchDraftData>({
    startDate: search?.startDate || "",
    endDate: search?.endDate || "",
    minBudget: search?.minBudget?.toString() || "",
    maxBudget: search?.maxBudget?.toString() || "",
    minBedrooms: search?.minBedrooms?.toString() || "",
    roomType: search?.roomType || "Any",
    requiredAmenities: search?.requiredAmenities || [],
    preferredAmenities: search?.preferredAmenities || [],
    areas: search?.areas || [],
    introduction: search?.introduction || "",
    activate: search?.status === "active" || !search,
  });
  const [step, setStep] = useState(1),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [published, setPublished] = useState(false);
  const draft = usePrivateDraft("search", "search", (saved) => {
    setForm((current) => ({
      ...current,
      ...(saved.data as Partial<SearchDraftData>),
    }));
    setStep(saved.step);
  });
  const patch = <K extends keyof SearchDraftData>(
    key: K,
    value: SearchDraftData[K],
  ) => setForm((current) => ({ ...current, [key]: value }));
  function toggle(
    key: "requiredAmenities" | "preferredAmenities",
    condition: string,
  ) {
    patch(
      key,
      form[key].includes(condition)
        ? form[key].filter((v) => v !== condition)
        : [...form[key], condition],
    );
  }
  async function later() {
    setBusy(true);
    setError("");
    try {
      await draft.save(form, step);
      onClose();
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function next(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      if (
        step === 1 &&
        (form.endDate <= form.startDate ||
          Number(form.minBudget) > Number(form.maxBudget))
      )
        throw new Error(
          "Choose a move-out date after move-in and a maximum budget above your minimum.",
        );
      if (step === 3 && !form.areas.length)
        throw new Error(
          "Select at least one area where you would like to live.",
        );
      await draft.save(form, step < 4 ? step + 1 : step);
      if (step < 4) {
        setStep(step + 1);
        return;
      }
      const result = await api<{ search: HousingSearch }>("/my-search", {
        ...form,
        status: form.activate ? "active" : "paused",
        minBudget: form.minBudget ? Number(form.minBudget) : undefined,
        maxBudget: Number(form.maxBudget),
        minBedrooms:
          form.roomType === "Entire place" && form.minBedrooms
            ? Number(form.minBedrooms)
            : undefined,
      });
      setPublished(true);
      onSaved(result.search);
      try {
        await draft.clear();
        onClose();
      } catch {
        setError(
          "Your search was saved. A newer draft is still private in You; review it before making more changes.",
        );
      }
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal
      title={search ? "Edit my search" : "Find your next place."}
      onClose={onClose}
      wide
    >
      <div className="post-layout guided-setup">
        <aside>
          <span className="eyebrow">FIND A PLACE</span>
          <h2>A place that fits your life.</h2>
          <p>
            Your dates, your budget, your neighborhoods. You can finish this
            later.
          </p>
          {steps.map((label, i) => (
            <div
              className={`post-step ${step === i + 1 ? "active" : ""}`}
              key={label}
            >
              <span>{step > i + 1 ? <Check size={14} /> : i + 1}</span>
              {label}
            </div>
          ))}
          <div className="mini-note">
            <Search size={20} />
            One profile, one search. Turn it on or off whenever your plans
            change.
          </div>
        </aside>
        <form className="form-stack search-editor" onSubmit={next}>
          <span className="eyebrow">STEP {step} OF 4</span>
          <h2>{steps[step - 1]}</h2>
          <p className="muted">
            {draft.ready
              ? draft.saved
                ? "Private draft loaded. Continuing saves your progress."
                : "Your progress stays private until you finish."
              : "Loading your saved progress…"}
          </p>
          <ErrorBox message={error || draft.error} />
          {(error.includes("another tab") || draft.error) && (
            <button
              className="outline"
              type="button"
              onClick={() => {
                if (
                  window.confirm(
                    "Replace the entries shown here with your last saved draft?",
                  )
                ) {
                  setError("");
                  void draft.load();
                }
              }}
            >
              Load saved version
            </button>
          )}
          <fieldset
            disabled={busy || !draft.ready || published}
            className="setup-fields"
          >
            {step === 1 && (
              <div className="form-grid">
                <label>
                  Move-in date
                  <input
                    type="date"
                    required
                    value={form.startDate}
                    onChange={(e) => patch("startDate", e.target.value)}
                  />
                </label>
                <label>
                  Move-out date
                  <input
                    type="date"
                    required
                    min={form.startDate}
                    value={form.endDate}
                    onChange={(e) => patch("endDate", e.target.value)}
                  />
                </label>
                <label>
                  Minimum rent / month <small>Optional</small>
                  <input
                    type="number"
                    min="1"
                    max="20000"
                    placeholder="No minimum"
                    value={form.minBudget}
                    onChange={(e) => patch("minBudget", e.target.value)}
                  />
                </label>
                <label>
                  Maximum rent / month
                  <input
                    type="number"
                    min="1"
                    max="20000"
                    required
                    placeholder="e.g. 900"
                    value={form.maxBudget}
                    onChange={(e) => patch("maxBudget", e.target.value)}
                  />
                </label>
              </div>
            )}
            {step === 2 && (
              <>
                <label>
                  What kind of space?
                  <select
                    value={form.roomType}
                    onChange={(e) =>
                      patch(
                        "roomType",
                        e.target.value as SearchDraftData["roomType"],
                      )
                    }
                  >
                    <option>Any</option>
                    <option>Private room</option>
                    <option>Entire place</option>
                  </select>
                </label>
                {form.roomType === "Entire place" && (
                  <label>
                    Minimum bedrooms <small>Optional</small>
                    <input
                      type="number"
                      min="1"
                      max="20"
                      step="1"
                      value={form.minBedrooms}
                      onChange={(e) => patch("minBedrooms", e.target.value)}
                    />
                  </label>
                )}
                {(["requiredAmenities", "preferredAmenities"] as const).map(
                  (key) => (
                    <fieldset className="request-amenities" key={key}>
                      <legend>
                        {key === "requiredAmenities"
                          ? "Must have"
                          : "Nice to have"}
                      </legend>
                      <small>
                        {key === "requiredAmenities"
                          ? "Every match must include these."
                          : "These help order your matches."}
                      </small>
                      <div>
                        {conditions.map((item) => (
                          <label key={item}>
                            <input
                              type="checkbox"
                              checked={form[key].includes(item)}
                              onChange={() => toggle(key, item)}
                            />
                            {item}
                          </label>
                        ))}
                      </div>
                    </fieldset>
                  ),
                )}
              </>
            )}
            {step === 3 && (
              <>
                <p>
                  Choose up to five areas. Hosts whose places are inside these
                  areas can find your search when it is on.
                </p>
                <SearchAreaPicker
                  value={form.areas}
                  onChange={(areas) => patch("areas", areas)}
                />
              </>
            )}
            {step === 4 && (
              <>
                <div className="notice">
                  <strong>
                    {form.minBudget
                      ? `${money(Number(form.minBudget))} – `
                      : "Up to "}
                    {money(Number(form.maxBudget))}/month
                  </strong>
                  <p>
                    {form.startDate} – {form.endDate} · {form.roomType}
                  </p>
                  <p>{form.areas.map((area) => area.label).join(" · ")}</p>
                  {form.requiredAmenities.length > 0 && (
                    <p>Must have: {form.requiredAmenities.join(", ")}</p>
                  )}
                </div>
                <label>
                  A little about your search <small>Public · Optional</small>
                  <textarea
                    maxLength={500}
                    rows={4}
                    placeholder="Tell the community what you’re looking for…"
                    value={form.introduction}
                    onChange={(e) => patch("introduction", e.target.value)}
                  />
                </label>
                <label className="search-visibility">
                  <input
                    type="checkbox"
                    checked={form.activate}
                    onChange={(e) => patch("activate", e.target.checked)}
                  />
                  Turn on my search when I finish
                </label>
                <p className="muted">
                  Your criteria, areas, and introduction appear in Browse and
                  Matches while your search is on. Your email, phone, and
                  documents stay private.
                </p>
              </>
            )}
          </fieldset>
          <div className="button-row setup-actions">
            {published ? (
              <button type="button" className="primary" onClick={onClose}>
                Done
              </button>
            ) : (
              <>
                {step > 1 && (
                  <button
                    type="button"
                    className="text-button"
                    disabled={busy}
                    onClick={() => setStep(step - 1)}
                  >
                    <ArrowLeft size={16} />
                    Back
                  </button>
                )}
                <button
                  type="button"
                  className="outline"
                  disabled={busy || !draft.ready}
                  onClick={() => void later()}
                >
                  Finish later
                </button>
                <button className="primary" disabled={busy || !draft.ready}>
                  {busy
                    ? "Saving…"
                    : step < 4
                      ? "Continue"
                      : form.activate
                        ? "Turn on my search"
                        : "Save search off"}
                  <ArrowRight size={16} />
                </button>
              </>
            )}
          </div>
        </form>
      </div>
    </Modal>
  );
}
