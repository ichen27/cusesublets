import { useCallback, useEffect, useState } from "react";
import {
  ArrowUpRight,
  LogOut,
  UserRound,
  ShieldCheck,
  Camera,
  FileText,
  Trash2,
} from "lucide-react";
import type {
  Listing,
  User,
  AccountProfile,
  IdentityDocument,
} from "../shared/types";
import { api } from "./api";
import { Busy, ErrorBox } from "./ui";
import Checks, { IdentityBadge } from "./Checks";
import UploadCard from "./UploadCard";
export default function Workspace({
  user,
  onLogout,
  onManage,
  onRefresh,
  onProfile,
}: {
  view: string;
  user: User;
  demo: boolean;
  notify: (s: string) => void;
  onSelect: (l: Listing) => void;
  onPost: () => void;
  onLogout: () => void;
  onManage: () => void;
  onRefresh: () => Promise<void>;
  onProfile: (id: string) => void;
}) {
  const [profile, setProfile] = useState<AccountProfile | null>(null),
    [name, setName] = useState(user.name),
    [docs, setDocs] = useState<IdentityDocument[]>([]),
    [note, setNote] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [saved, setSaved] = useState(false),
    [tab, setTab] = useState("profile");
  const load = useCallback(async () => {
    const result = await api<{
      user: User;
      profile: AccountProfile;
      identityDocuments: IdentityDocument[];
      identityNote?: string;
    }>("/profile");
    setProfile(result.profile);
    setName(result.user.name);
    setDocs(result.identityDocuments);
    setNote(result.identityNote || "");
  }, []);
  useEffect(() => {
    load().catch((e) => setError(e.message));
  }, [load]);
  async function upload(file: File, kind: string) {
    const body = new FormData();
    body.append("file", file);
    body.append("kind", kind);
    await api(
      kind === "identity" ? "/profile/identity" : "/profile/media",
      body,
    );
    await load();
    await onRefresh();
  }
  async function remove(url: string) {
    setBusy(true);
    try {
      await api("/profile/media/remove", { url });
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="workspace profile-workspace">
      <div className="workspace-heading">
        <div>
          <span className="eyebrow">YOUR ACCOUNT</span>
          <h1>A little more you.</h1>
          <p>
            Build a profile people can get to know. Keep your private details
            private.
          </p>
        </div>
        <button className="outline small" onClick={onLogout}>
          <LogOut size={15} /> Log out
        </button>
      </div>
      <ErrorBox message={error} />
      {!profile ? (
        <Busy />
      ) : (
        <div className="profile-editor-layout">
          <aside className="profile-sidebar panel">
            <div className="profile-portrait">
              {profile.avatar ? (
                <img src={profile.avatar} alt={user.name} />
              ) : (
                <UserRound size={42} />
              )}
            </div>
            <h2>{user.name}</h2>
            <IdentityBadge status={user.identity} />
            <button
              className="outline full small"
              onClick={() => onProfile(user.id)}
            >
              View public profile <ArrowUpRight size={14} />
            </button>
            <div className="profile-section-nav">
              {[
                ["profile", UserRound, "Personal details"],
                ["photos", Camera, "Photos & personality"],
                ["verification", ShieldCheck, "Identity verification"],
              ].map(([key, Icon, label]) => {
                const I = Icon as typeof Camera;
                return (
                  <button
                    key={String(key)}
                    className={tab === key ? "active" : ""}
                    onClick={() => setTab(String(key))}
                  >
                    <I size={17} />
                    {String(label)}
                  </button>
                );
              })}
            </div>
            <button className="text-button" onClick={onManage}>
              Manage my listings <ArrowUpRight size={14} />
            </button>
          </aside>
          <section className="profile-editor-main">
            {tab === "profile" ? (
              <form
                className="panel form-stack"
                onSubmit={async (e) => {
                  e.preventDefault();
                  setBusy(true);
                  setError("");
                  setSaved(false);
                  try {
                    await api("/profile", {
                      name,
                      phone: profile.phone,
                      bio: profile.bio,
                      socials: profile.socials,
                    });
                    await onRefresh();
                    await load();
                    setSaved(true);
                  } catch (e) {
                    setError((e as Error).message);
                  } finally {
                    setBusy(false);
                  }
                }}
              >
                <span className="eyebrow">PERSONAL DETAILS</span>
                <h2>Introduce yourself.</h2>
                <div className="form-grid">
                  <label>
                    Full name
                    <input
                      value={name}
                      required
                      minLength={2}
                      maxLength={80}
                      onChange={(e) => {
                        setName(e.target.value);
                        setSaved(false);
                      }}
                    />
                  </label>
                  <label>
                    Email{" "}
                    <span className="field-hint">Private · From Google</span>
                    <input type="email" value={user.email} readOnly />
                  </label>
                  <label>
                    Phone number{" "}
                    <span className="field-hint">Private · Optional</span>
                    <input
                      type="tel"
                      autoComplete="tel"
                      value={profile.phone || ""}
                      maxLength={30}
                      placeholder="(315) 555-0123"
                      onChange={(e) =>
                        setProfile({ ...profile, phone: e.target.value })
                      }
                    />
                  </label>
                </div>
                <label>
                  About you{" "}
                  <span className="field-hint">Public · Optional</span>
                  <textarea
                    value={profile.bio || ""}
                    maxLength={2000}
                    rows={5}
                    placeholder="What brings you to Syracuse? Share a little about yourself and your place."
                    onChange={(e) =>
                      setProfile({ ...profile, bio: e.target.value })
                    }
                  />
                </label>
                <h3>Find common ground.</h3>
                <p className="muted">
                  Social links are optional and visible on your public profile.
                </p>
                <div className="form-grid">
                  {["instagram", "facebook", "linkedin", "website"].map(
                    (key) => (
                      <label key={key}>
                        {key === "linkedin"
                          ? "LinkedIn"
                          : key[0].toUpperCase() + key.slice(1)}
                        <input
                          type="url"
                          placeholder="https://…"
                          value={
                            profile.socials?.[
                              key as keyof typeof profile.socials
                            ] || ""
                          }
                          onChange={(e) =>
                            setProfile({
                              ...profile,
                              socials: {
                                ...profile.socials,
                                [key]: e.target.value,
                              },
                            })
                          }
                        />
                      </label>
                    ),
                  )}
                </div>
                {user.identity === "verified" && (
                  <p className="muted">
                    Changing your name requires a new identity review.
                  </p>
                )}
                <div className="button-row">
                  <span role="status">{saved ? "Profile saved" : ""}</span>
                  <button className="primary" disabled={busy}>
                    {busy ? "Saving…" : "Save profile"}
                  </button>
                </div>
              </form>
            ) : tab === "photos" ? (
              <div className="panel">
                <span className="eyebrow">PHOTOS & PERSONALITY</span>
                <h2>Put a face to the name.</h2>
                <p className="muted">
                  Use photos you’re comfortable sharing publicly. Never upload
                  an ID here.
                </p>
                <UploadCard
                  title="Profile picture"
                  description="A clear photo helps people recognize you."
                  accept="image/jpeg,image/png"
                  button="Save profile picture"
                  privateFile={false}
                  onUpload={(f) => upload(f, "avatar")}
                />
                {profile.avatar && (
                  <button
                    className="text-button"
                    disabled={busy}
                    onClick={() => remove(profile.avatar!)}
                  >
                    Remove profile picture
                  </button>
                )}
                <div className="profile-photo-grid">
                  {profile.photos.map((url) => (
                    <div key={url}>
                      <img src={url} alt="Profile gallery" />
                      <button
                        className="icon-button"
                        aria-label="Remove gallery photo"
                        disabled={busy}
                        onClick={() => remove(url)}
                      >
                        <Trash2 size={15} />
                      </button>
                    </div>
                  ))}
                </div>
                <UploadCard
                  title="Profile photos"
                  description="Share a bit of your life in Syracuse."
                  accept="image/jpeg,image/png"
                  button="Add photo"
                  privateFile={false}
                  onUpload={(f) => upload(f, "photo")}
                />
              </div>
            ) : (
              <div className="panel">
                <span className="eyebrow">IDENTITY VERIFICATION</span>
                <h2>A real person behind the profile.</h2>
                <p>
                  Submit a clear photo or PDF of your government-issued ID. An
                  authorized reviewer checks your name and document before the
                  identity badge is added.
                </p>
                <Checks identity={user.identity} />
                {note && <div className="notice">Review team: {note}</div>}
                <div className="identity-status">
                  <b>
                    {user.identity === "verified"
                      ? "Your identity has been verified"
                      : docs.length
                        ? "Your identity documents"
                        : "No ID submitted yet"}
                  </b>
                  <p>
                    {user.identity === "verified"
                      ? "Uploading another ID restarts the review and removes the badge until approved."
                      : "Uploading an ID doesn’t verify you automatically. We review submissions manually."}
                  </p>
                  {docs.map((d) => (
                    <a
                      key={d.id}
                      href={`/api/identity-documents/${d.id}`}
                      target="_blank"
                      rel="noreferrer"
                    >
                      <FileText size={15} />
                      {d.name}
                      <small>
                        {new Date(d.createdAt).toLocaleDateString()}
                      </small>
                    </a>
                  ))}
                </div>
                <UploadCard
                  title="Government-issued ID"
                  description="Private submission for manual identity review."
                  onUpload={(f) => upload(f, "identity")}
                />
                <p className="muted">
                  Your ID is never shown on your public profile or shared with
                  other members. Email and phone number are not identity
                  verification.
                </p>
              </div>
            )}
          </section>
        </div>
      )}
    </main>
  );
}
