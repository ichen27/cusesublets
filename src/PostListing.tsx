import MapPicker from "./MapPicker";
import { useState, type FormEvent } from "react";
import {
  ArrowRight,
  ArrowLeft,
  Check,
  Upload,
  ShieldCheck,
} from "lucide-react";
import type { Listing } from "../shared/types";
import type { ListingDraftData } from "../shared/drafts";
import { api, money } from "./api";
import { Modal, ErrorBox } from "./ui";
import { usePrivateDraft } from "./usePrivateDraft";
const steps = [
  "Your place",
  "Rent & availability",
  "Show them around",
  "Review & publish",
];
export default function PostListing({
  onClose,
  onCreated,
  notify,
  draftId,
}: {
  onClose: () => void;
  onCreated: () => void;
  notify: (s: string) => void;
  draftId?: string;
}) {
  const [id] = useState(() => draftId || crypto.randomUUID());
  const [step, setStep] = useState(1),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [created, setCreated] = useState<Listing | null>(null),
    [lease, setLease] = useState<File | null>(null),
    [permission, setPermission] = useState<File | null>(null),
    [media, setMedia] = useState<File[]>([]);
  const [form, setForm] = useState<ListingDraftData>({
    title: "",
    neighborhood: "Westcott",
    address: "",
    price: 0,
    beds: 1,
    baths: 1,
    roomType: "Private room",
    startDate: "",
    endDate: "",
    description: "",
    images: "",
    matterportUrl: "",
    videoUrl: "",
    walkMinutes: 15,
    lat: 43.037,
    lng: -76.127,
    amenities: [],
  });
  const draft = usePrivateDraft(id, "listing", (saved) => {
    setForm((current) => ({
      ...current,
      ...(saved.data as Partial<ListingDraftData>),
    }));
    setStep(saved.step);
  });
  const patch = <K extends keyof ListingDraftData>(
    key: K,
    value: ListingDraftData[K],
  ) => setForm((current) => ({ ...current, [key]: value }));
  async function later() {
    setBusy(true);
    setError("");
    try {
      if (!created) await draft.save(form, step);
      notify(
        created
          ? "Your place is published. Add any remaining files from You."
          : "Draft saved. You can finish your place from You.",
      );
      onClose();
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      if (!created) {
        if (step === 2 && form.endDate <= form.startDate)
          throw new Error(
            "Choose an end date after the start of your availability.",
          );
        await draft.save(form, step < 4 ? step + 1 : step);
        if (step < 4) {
          setStep(step + 1);
          return;
        }
      }
      let listing = created;
      if (!listing) {
        listing = (
          await api<{ listing: Listing }>("/listings", {
            ...form,
            clientPublishId: id,
            images: form.images
              .split("\n")
              .map((s) => s.trim())
              .filter(Boolean),
          })
        ).listing;
        setCreated(listing);
        onCreated();
        try {
          await draft.clear();
        } catch {
          notify(
            "Your place is published. A newer private draft remains in You for you to review.",
          );
        }
      }
      for (const [kind, file] of [
        ["lease", lease],
        ["permission", permission],
      ] as const) {
        if (file) {
          const fd = new FormData();
          fd.append("kind", kind);
          fd.append("file", file);
          await api(`/listings/${listing.id}/documents`, fd);
          if (kind === "lease") setLease(null);
          else setPermission(null);
        }
      }
      for (const file of media) {
        const fd = new FormData();
        fd.append("file", file);
        await api(`/listings/${listing.id}/media`, fd);
        setMedia((current) => current.filter((f) => f !== file));
      }
      notify("Your place is published. Document badges appear after review.");
      onCreated();
      onClose();
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal title="Offer your place." wide onClose={onClose}>
      <div className="post-layout guided-setup">
        <aside>
          <span className="eyebrow">OFFER A PLACE</span>
          <h2>Make room for someone new.</h2>
          <p>Tell the community about your place. Publish when you’re ready.</p>
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
            <ShieldCheck size={20} />
            Documents are optional to publish. Reviewed evidence earns the
            corresponding badge.
          </div>
        </aside>
        <form onSubmit={submit} className="form-stack">
          <span className="eyebrow">STEP {step} OF 4</span>
          <h2>{steps[step - 1]}</h2>
          <p className="muted">
            {draft.ready
              ? draft.saved
                ? "Your saved draft is ready. Selected files stay on this device until publication."
                : "Finish later saves a private draft in You."
              : "Loading your saved progress…"}
          </p>
          <ErrorBox message={error || draft.error} />
          {(error.includes("another tab") || draft.error) && !created && (
            <button
              type="button"
              className="outline"
              onClick={() => {
                if (
                  window.confirm(
                    "Replace these entries with your last saved draft?",
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
          {created && (
            <div className="notice">
              Your place is published. Retry to finish remaining uploads or
              choose Finish later to manage them from You. A second listing will
              not be created.
            </div>
          )}
          <fieldset className="setup-fields" disabled={busy || !draft.ready}>
            {step === 1 && (
              <>
                <label>
                  Give your place a title
                  <input
                    required
                    maxLength={100}
                    placeholder="Sunny room in a Westcott house"
                    value={form.title}
                    onChange={(e) => patch("title", e.target.value)}
                  />
                </label>
                <div className="form-grid">
                  <label>
                    Neighborhood
                    <select
                      value={form.neighborhood}
                      onChange={(e) => patch("neighborhood", e.target.value)}
                    >
                      {[
                        "Westcott",
                        "University Hill",
                        "Eastside",
                        "South Campus",
                        "Downtown",
                        "Outer Comstock",
                      ].map((name) => (
                        <option key={name}>{name}</option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Type of place
                    <select
                      value={form.roomType}
                      onChange={(e) => patch("roomType", e.target.value)}
                    >
                      <option>Private room</option>
                      <option>Entire place</option>
                    </select>
                  </label>
                  <label>
                    Bedrooms
                    <input
                      type="number"
                      min="1"
                      max="20"
                      required
                      value={form.beds}
                      onChange={(e) => patch("beds", Number(e.target.value))}
                    />
                  </label>
                  <label>
                    Bathrooms
                    <input
                      type="number"
                      min="0.5"
                      max="20"
                      step="0.5"
                      required
                      value={form.baths}
                      onChange={(e) => patch("baths", Number(e.target.value))}
                    />
                  </label>
                </div>
                <label>
                  Public location
                  <input
                    required
                    maxLength={160}
                    placeholder="Near Euclid Avenue & Westcott Street"
                    value={form.address}
                    onChange={(e) => patch("address", e.target.value)}
                  />
                  <small>
                    Use a street or nearby intersection. Keep your apartment
                    number private.
                  </small>
                </label>
                <div>
                  <label>Approximate location</label>
                  <MapPicker
                    onPick={(lat, lng) =>
                      setForm((current) => ({ ...current, lat, lng }))
                    }
                  />
                  <small>
                    Saved coordinates: {form.lat.toFixed(3)},{" "}
                    {form.lng.toFixed(3)}. Tap the map to move your public pin.
                  </small>
                </div>
              </>
            )}
            {step === 2 && (
              <>
                <div className="form-grid">
                  <label>
                    Monthly rent (USD)
                    <input
                      type="number"
                      min="1"
                      max="20000"
                      required
                      value={form.price || ""}
                      onChange={(e) => patch("price", Number(e.target.value))}
                    />
                  </label>
                  <label>
                    Walk to campus (minutes)
                    <input
                      type="number"
                      min="1"
                      max="120"
                      required
                      value={form.walkMinutes}
                      onChange={(e) =>
                        patch("walkMinutes", Number(e.target.value))
                      }
                    />
                  </label>
                  <label>
                    Available from
                    <input
                      type="date"
                      required
                      value={form.startDate}
                      onChange={(e) => patch("startDate", e.target.value)}
                    />
                  </label>
                  <label>
                    Available until
                    <input
                      type="date"
                      required
                      min={form.startDate}
                      value={form.endDate}
                      onChange={(e) => patch("endDate", e.target.value)}
                    />
                  </label>
                </div>
                <div>
                  <label>What is included?</label>
                  <div className="amenity-select">
                    {[
                      "Furnished",
                      "Wi-Fi",
                      "Laundry",
                      "Kitchen",
                      "Parking",
                      "Near campus",
                      "Pets allowed",
                      "Accessible",
                      "Air conditioning",
                      "Utilities included",
                    ].map((item) => (
                      <button
                        type="button"
                        key={item}
                        className={`chip ${form.amenities.includes(item) ? "selected" : ""}`}
                        aria-pressed={form.amenities.includes(item)}
                        onClick={() =>
                          patch(
                            "amenities",
                            form.amenities.includes(item)
                              ? form.amenities.filter((v) => v !== item)
                              : [...form.amenities, item],
                          )
                        }
                      >
                        {form.amenities.includes(item) && <Check size={13} />}{" "}
                        {item}
                      </button>
                    ))}
                  </div>
                </div>
              </>
            )}
            {step === 3 && (
              <>
                <label>
                  What should people know?
                  <textarea
                    required
                    minLength={20}
                    maxLength={4000}
                    rows={4}
                    placeholder="The natural light, your roommates, the coffee spot around the corner…"
                    value={form.description}
                    onChange={(e) => patch("description", e.target.value)}
                  />
                </label>
                <label className="upload-label">
                  <Upload size={21} />
                  Photos or a video
                  <input
                    type="file"
                    multiple
                    accept="image/jpeg,image/png,image/webp,video/mp4,video/webm"
                    onChange={(e) => setMedia(Array.from(e.target.files || []))}
                  />
                  <small>
                    {media.length
                      ? `${media.length} files selected`
                      : "Photos up to 5 MB each · Video up to 25 MB"}
                  </small>
                </label>
                <p className="muted">
                  File selections cannot be saved in a draft. If you finish
                  later, reselect them when you return.
                </p>
                <label>
                  Photo URLs <small>Optional · One per line</small>
                  <textarea
                    maxLength={16000}
                    value={form.images}
                    onChange={(e) => patch("images", e.target.value)}
                    placeholder="https://…"
                    rows={2}
                  />
                </label>
                <label>
                  Matterport tour <small>Optional</small>
                  <input
                    type="url"
                    maxLength={2000}
                    value={form.matterportUrl}
                    onChange={(e) => patch("matterportUrl", e.target.value)}
                    placeholder="https://my.matterport.com/show/?m=…"
                  />
                </label>
                <label>
                  Video URL <small>Optional</small>
                  <input
                    type="url"
                    maxLength={2000}
                    value={form.videoUrl}
                    onChange={(e) => patch("videoUrl", e.target.value)}
                    placeholder="https://…/walkthrough.mp4"
                  />
                </label>
              </>
            )}
            {step === 4 && (
              <>
                <div className="notice">
                  <h3>{form.title}</h3>
                  <strong>{money(form.price)} / month</strong>
                  <p>
                    {form.startDate} – {form.endDate} · {form.roomType}
                  </p>
                  <p>
                    {form.neighborhood} · {form.beds} bed · {form.baths} bath
                  </p>
                  <p>{form.description}</p>
                </div>
                <p>
                  Your place will appear in Browse immediately. You can publish
                  without documents and request verification later in You.
                </p>
                <details className="optional-documents">
                  <summary>
                    Request document review <small>Optional</small>
                  </summary>
                  <p>
                    Only you and authorized reviewers can access these files.
                    Identity documents belong in your profile.
                  </p>
                  <label className="upload-label">
                    <Upload size={20} />
                    Lease document
                    <input
                      type="file"
                      accept="application/pdf,image/jpeg,image/png"
                      onChange={(e) => setLease(e.target.files?.[0] || null)}
                    />
                    <small>
                      {lease?.name || "PDF, JPG or PNG · Up to 5 MB"}
                    </small>
                  </label>
                  <label className="upload-label">
                    <Upload size={20} />
                    Permission to sublet
                    <input
                      type="file"
                      accept="application/pdf,image/jpeg,image/png"
                      onChange={(e) =>
                        setPermission(e.target.files?.[0] || null)
                      }
                    />
                    <small>
                      {permission?.name ||
                        "Landlord authorization · Up to 5 MB"}
                    </small>
                  </label>
                </details>
                {media.map((file, i) => (
                  <div className="button-row" key={i}>
                    <span>{file.name}</span>
                    <button
                      type="button"
                      className="text-button"
                      onClick={() =>
                        setMedia((files) => files.filter((v) => v !== file))
                      }
                    >
                      Remove file
                    </button>
                  </div>
                ))}
                <label className="check-label">
                  <input type="checkbox" required />I have the right to submit
                  this listing and the information is accurate.
                </label>
              </>
            )}
          </fieldset>
          <div className="button-row setup-actions">
            {step > 1 && (
              <button
                type="button"
                className="text-button"
                disabled={busy || !!created}
                onClick={() => setStep(step - 1)}
              >
                <ArrowLeft size={15} />
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
                  : created
                    ? "Finish uploads"
                    : "Publish listing"}
              <ArrowRight size={16} />
            </button>
          </div>
        </form>
      </div>
    </Modal>
  );
}
