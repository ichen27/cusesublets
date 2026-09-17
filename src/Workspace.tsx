import { useState } from "react";
import { ArrowRight, LogOut } from "lucide-react";
import type { Listing, User } from "../shared/types";
import { api } from "./api";
import { ErrorBox } from "./ui";
export default function Workspace({
  user,
  demo,
  onLogout,
  onManage,
  onRefresh,
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
}) {
  const [name, setName] = useState(user.name),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  return (
    <main className="workspace">
      <div className="workspace-heading">
        <div>
          <span className="eyebrow">YOUR CUSESUBLETS</span>
          <h1>Hey, {user.name.split(" ")[0]}.</h1>
          <p>Your profile and account details.</p>
        </div>
        <button className="outline" onClick={onLogout}>
          <LogOut size={15} /> Log out
        </button>
      </div>
      <ErrorBox message={error} />
      <div className="account-layout">
        <section className="panel profile-card">
          <span className="avatar large">{user.name[0]}</span>
          <h2>{user.name}</h2>
          <p>{user.email}</p>
          <span className={"status " + user.identity}>
            {user.identity === "verified"
              ? "Identity checked"
              : "Identity review pending"}
          </span>
          <p className="muted">
            {demo
              ? "This is a demo profile. Verification states are illustrative."
              : "Identity verification is not enabled yet. Lease and sublet permission are reviewed separately for each listing."}
          </p>
          <form
            className="form-stack"
            onSubmit={async (e) => {
              e.preventDefault();
              setBusy(true);
              setError("");
              try {
                await api("/profile", { name });
                await onRefresh();
              } catch (e) {
                setError((e as Error).message);
              } finally {
                setBusy(false);
              }
            }}
          >
            <label>
              Display name
              <input
                value={name}
                required
                maxLength={80}
                onChange={(e) => setName(e.target.value)}
              />
            </label>
            <button className="outline small" disabled={busy}>
              Save name
            </button>
          </form>
        </section>
        <section className="panel">
          <h2>Your host workspace</h2>
          <p>
            Manage the places you are subleasing, upload review documents, and
            open incoming renter conversations.
          </p>
          <button className="primary" onClick={onManage}>
            Go to My listings <ArrowRight size={16} />
          </button>
        </section>
      </div>
    </main>
  );
}
