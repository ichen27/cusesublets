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
import { api } from "./api";
import { Modal, ErrorBox } from "./ui";
export default function PostListing({
  onClose,
  onCreated,
  notify,
}: {
  onClose: () => void;
  onCreated: () => void;
  notify: (s: string) => void;
}) {
  const [step, setStep] = useState(1),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [created, setCreated] = useState<Listing | null>(null),
    [lease, setLease] = useState<File | null>(null),
    [permission, setPermission] = useState<File | null>(null),
    [media, setMedia] = useState<File[]>([]);
  const [form, setForm] = useState({
    title: "",
    neighborhood: "Westcott",
    address: "",
    price: 750,
    beds: 1,
    baths: 1,
    roomType: "Private room",
    startDate: "2027-01-01",
    endDate: "2027-05-31",
    description: "",
    images: "",
    matterportUrl: "",
    videoUrl: "",
    walkMinutes: 15,
    lat: 43.037,
    lng: -76.127,
    amenities: ["Furnished", "Wi-Fi"],
  });
  const patch = (key: string, value: unknown) =>
    setForm((f) => ({ ...f, [key]: value }));
  async function submit(e: FormEvent) {
    e.preventDefault();
    if (step < 3) {
      setStep(step + 1);
      return;
    }
    setBusy(true);
    setError("");
    try {
      let l = created;
      if (!l) {
        const result = await api<{ listing: Listing }>("/listings", {
          ...form,
          images: form.images
            .split("\n")
            .map((s) => s.trim())
            .filter(Boolean),
        });
        l = result.listing;
        setCreated(l);
      }
      for (const [kind, file] of [
        ["lease", lease],
        ["permission", permission],
      ] as const) {
        if (file) {
          const fd = new FormData();
          fd.append("kind", kind);
          fd.append("file", file);
          await api(`/listings/${l.id}/documents`, fd);
          if (kind === "lease") setLease(null);
          else setPermission(null);
        }
      }
      for (const file of media) {
        const fd = new FormData();
        fd.append("file", file);
        await api(`/listings/${l.id}/media`, fd);
        setMedia((prev) => prev.filter((f) => f !== file));
      }
      notify(
        "Your listing is published. Badges appear after manual verification.",
      );
      onCreated();
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal title="Give your place its next chapter." wide onClose={onClose}>
      <div className="post-layout">
        <aside>
          <span className="eyebrow">LIST YOUR PLACE</span>
          <h2>
            A good handoff
            <br />
            starts here.
          </h2>
          <p>
            Tell the story of your space. We’ll help you keep the details clear.
          </p>
          {[
            "The essentials",
            "Make it feel like home",
            "Documents & review",
          ].map((label, i) => (
            <div
              className={"post-step " + (step === i + 1 ? "active" : "")}
              key={label}
            >
              <span>{step > i + 1 ? <Check size={14} /> : i + 1}</span>
              {label}
            </div>
          ))}
          <div className="mini-note">
            <ShieldCheck size={19} /> Uploading documents starts a review. It
            doesn’t automatically verify your listing.
          </div>
        </aside>
        <form onSubmit={submit} className="form-stack">
          <span className="eyebrow">STEP {step} OF 3</span>
          <h2>
            {
              [
                "The essentials",
                "Show them around",
                "A clear start for everyone",
              ][step - 1]
            }
          </h2>
          {step === 1 ? (
            <>
              <label>
                Listing title
                <input
                  required
                  maxLength={100}
                  placeholder="Sunny room in a Westcott house"
                  value={form.title}
                  onChange={(e) => patch("title", e.target.value)}
                />
              </label>
              <div>
                <label>Set the approximate location</label>
                <p className="muted" style={{ marginBottom: 10 }}>
                  Tap near your place. We round the pin to protect the exact
                  address.
                </p>
                <MapPicker
                  onPick={(lat, lng) => setForm((f) => ({ ...f, lat, lng }))}
                />
                <small className="muted">
                  Your public pin shows an approximate area, not an apartment
                  number.
                </small>
              </div>
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
                    ].map((n) => (
                      <option key={n}>{n}</option>
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
              </div>
              <label>
                Public location (street or nearest intersection)
                <input
                  required
                  placeholder="Near Euclid Avenue & Westcott Street"
                  value={form.address}
                  onChange={(e) => patch("address", e.target.value)}
                />
                <small>
                  Keep your apartment number private. Reviewers see the full
                  address in your lease.
                </small>
              </label>
              <div className="form-grid">
                <label>
                  Monthly rent (USD)
                  <input
                    type="number"
                    min="1"
                    max="20000"
                    required
                    value={form.price}
                    onChange={(e) => patch("price", Number(e.target.value))}
                  />
                </label>
                <label>
                  Walk to campus (minutes)
                  <input
                    type="number"
                    min="0"
                    max="120"
                    value={form.walkMinutes}
                    onChange={(e) =>
                      patch("walkMinutes", Number(e.target.value))
                    }
                  />
                </label>
                <label>
                  Bedrooms
                  <input
                    type="number"
                    min="1"
                    max="20"
                    value={form.beds}
                    onChange={(e) => patch("beds", Number(e.target.value))}
                  />
                </label>
                <label>
                  Bathrooms
                  <input
                    type="number"
                    min="1"
                    max="20"
                    value={form.baths}
                    onChange={(e) => patch("baths", Number(e.target.value))}
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
            </>
          ) : step === 2 ? (
            <>
              <label>
                What makes your place special?
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
              <div>
                <label>Amenities</label>
                <div className="amenity-select">
                  {[
                    "Furnished",
                    "Wi-Fi",
                    "Laundry",
                    "Parking",
                    "Pet friendly",
                    "Air conditioning",
                    "Utilities included",
                  ].map((a) => (
                    <button
                      type="button"
                      key={a}
                      className={
                        form.amenities.includes(a) ? "chip selected" : "chip"
                      }
                      onClick={() =>
                        patch(
                          "amenities",
                          form.amenities.includes(a)
                            ? form.amenities.filter((v) => v !== a)
                            : [...form.amenities, a],
                        )
                      }
                    >
                      {form.amenities.includes(a) && <Check size={13} />} {a}
                    </button>
                  ))}
                </div>
              </div>
              <label className="upload-label">
                <Upload size={21} /> Upload photos or a video
                <input
                  type="file"
                  multiple
                  accept="image/jpeg,image/png,image/webp,video/mp4,video/webm"
                  onChange={(e) => setMedia(Array.from(e.target.files || []))}
                />
                <small>
                  {media.length
                    ? `${media.length} file(s) selected`
                    : "Photos up to 5 MB each · Video up to 25 MB"}
                </small>
              </label>
              <label>
                Photo URLs (optional, one per line)
                <textarea
                  value={form.images}
                  onChange={(e) => patch("images", e.target.value)}
                  placeholder="https://…"
                  rows={2}
                />
              </label>
              <label>
                Matterport tour link (optional)
                <input
                  type="url"
                  placeholder="https://my.matterport.com/show/?m=…"
                  value={form.matterportUrl}
                  onChange={(e) => patch("matterportUrl", e.target.value)}
                />
                <small>
                  Capture in Matterport, then paste the shared tour link here.
                </small>
              </label>
              <label>
                Video URL (optional)
                <input
                  type="url"
                  placeholder="https://…/walkthrough.mp4"
                  value={form.videoUrl}
                  onChange={(e) => patch("videoUrl", e.target.value)}
                />
              </label>
            </>
          ) : (
            <>
              <div className="notice">
                Your listing will be <b>published immediately</b>. Documents are
                optional. Our team reviews your lease and permission separately
                before adding verification badges. Upload ID only through your
                profile.
              </div>
              <label className="upload-label">
                <Upload /> Lease document
                <input
                  type="file"
                  accept="application/pdf,image/jpeg,image/png"
                  onChange={(e) => setLease(e.target.files?.[0] || null)}
                />
                <small>{lease?.name || "PDF, JPG or PNG · Up to 5 MB"}</small>
              </label>
              <label className="upload-label">
                <Upload /> Permission to sublet
                <input
                  type="file"
                  accept="application/pdf,image/jpeg,image/png"
                  onChange={(e) => setPermission(e.target.files?.[0] || null)}
                />
                <small>
                  {permission?.name ||
                    "Landlord authorization · PDF, JPG or PNG · Up to 5 MB"}
                </small>
              </label>
              <p className="muted">
                Only you and authorized reviewers can access these documents.
                You can publish now and add evidence from My listings later.
              </p>
              <label className="check-label">
                <input type="checkbox" required /> I have the right to submit
                this listing and the information is accurate.
              </label>
              {created && (
                <>
                  <div className="notice">
                    Your listing is published. Retry to finish remaining uploads
                    or remove a file below. A second listing won’t be created.
                  </div>
                  {media.map((f, i) => (
                    <div className="button-row" key={i}>
                      <span className="muted">{f.name}</span>
                      <button
                        type="button"
                        className="text-button"
                        onClick={() =>
                          setMedia((files) => files.filter((v) => v !== f))
                        }
                      >
                        Remove file
                      </button>
                    </div>
                  ))}
                </>
              )}
            </>
          )}
          <ErrorBox message={error} />
          <div className="button-row">
            {step > 1 ? (
              <button
                type="button"
                className="text-button"
                disabled={busy || !!created}
                onClick={() => setStep(step - 1)}
              >
                <ArrowLeft size={15} /> Back
              </button>
            ) : (
              <span />
            )}
            <button className="primary" disabled={busy}>
              {busy
                ? "Submitting…"
                : step === 3
                  ? "Publish listing"
                  : "Continue"}
              <ArrowRight size={16} />
            </button>
          </div>
        </form>
      </div>
    </Modal>
  );
}
