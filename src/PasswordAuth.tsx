import { useEffect, useState } from "react";
import { api } from "./api";
import type { User } from "../shared/types";
export function PasswordLogin({
  onSignedIn,
}: {
  onSignedIn: (user: User) => void;
}) {
  const [signup, setSignup] = useState(false),
    [name, setName] = useState(""),
    [email, setEmail] = useState(""),
    [password, setPassword] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  return (
    <form
      className="form-stack"
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true);
        setError("");
        try {
          const result = await api<{ user: User }>(
            "/auth/" + (signup ? "signup" : "login"),
            { name, email, password },
          );
          setPassword("");
          onSignedIn(result.user);
        } catch (e) {
          setError((e as Error).message);
        } finally {
          setBusy(false);
        }
      }}
    >
      {signup && (
        <label>
          Full name
          <input
            autoComplete="name"
            required
            maxLength={80}
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
        </label>
      )}
      <label>
        Email
        <input
          type="email"
          autoComplete="email"
          required
          maxLength={254}
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </label>
      <label>
        Password
        <input
          type="password"
          autoComplete={signup ? "new-password" : "current-password"}
          required
          minLength={15}
          maxLength={128}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
      </label>
      {signup && (
        <small>
          Use 15–128 characters. Email recovery is not available yet; keep your
          password somewhere safe.
        </small>
      )}
      {error && (
        <p role="alert" className="error-box">
          {error}
        </p>
      )}
      <button className="primary full" disabled={busy}>
        {busy
          ? "Please wait…"
          : signup
            ? "Create account"
            : "Log in with email"}
      </button>
      <button
        type="button"
        className="text-button"
        disabled={busy}
        onClick={() => {
          setSignup(!signup);
          setError("");
          setPassword("");
        }}
      >
        {signup
          ? "Already have an account? Log in"
          : "New here? Create an account"}
      </button>
      <button
        type="button"
        className="secondary full"
        onClick={() => location.assign("/api/login")}
      >
        Continue with Google
      </button>
    </form>
  );
}
export function PasswordSettings() {
  const [enabled, setEnabled] = useState(false),
    [current, setCurrent] = useState(""),
    [next, setNext] = useState(""),
    [confirm, setConfirm] = useState(""),
    [busy, setBusy] = useState(false),
    [message, setMessage] = useState(""),
    [error, setError] = useState("");
  useEffect(() => {
    api<{ hasPassword: boolean }>("/auth/status")
      .then((r) => setEnabled(r.hasPassword))
      .catch(() => {});
  }, []);
  if (!enabled) return null;
  return (
    <form
      className="panel form-stack"
      onSubmit={async (e) => {
        e.preventDefault();
        setError("");
        setMessage("");
        if (next !== confirm) {
          setError("New passwords do not match.");
          return;
        }
        setBusy(true);
        try {
          await api("/auth/password", {
            currentPassword: current,
            newPassword: next,
          });
          setCurrent("");
          setNext("");
          setConfirm("");
          setMessage(
            "Password changed. Your other email/password sessions have been signed out.",
          );
        } catch (e) {
          setError((e as Error).message);
        } finally {
          setBusy(false);
        }
      }}
    >
      <h2>Change password</h2>
      <label>
        Current password
        <input
          type="password"
          autoComplete="current-password"
          required
          minLength={15}
          maxLength={128}
          value={current}
          onChange={(e) => setCurrent(e.target.value)}
        />
      </label>
      <label>
        New password
        <input
          type="password"
          autoComplete="new-password"
          required
          minLength={15}
          maxLength={128}
          value={next}
          onChange={(e) => setNext(e.target.value)}
        />
      </label>
      <label>
        Confirm new password
        <input
          type="password"
          autoComplete="new-password"
          required
          minLength={15}
          maxLength={128}
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
        />
      </label>
      <small>
        Use 15–128 characters. Automated password recovery is not available yet.
      </small>
      {error && (
        <p role="alert" className="error-box">
          {error}
        </p>
      )}
      {message && <p role="status">{message}</p>}
      <button className="primary" disabled={busy}>
        {busy ? "Saving…" : "Change password"}
      </button>
    </form>
  );
}
