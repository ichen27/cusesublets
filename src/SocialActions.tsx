import { useEffect, useRef, useState } from "react";
import { Bookmark, Heart, MessageCircle } from "lucide-react";
import type { User } from "../shared/types";
import type {
  SocialComment,
  SocialSummary,
  SocialTarget,
} from "../shared/social";
import { api } from "./api";
export default function SocialActions({
  targetType,
  targetId,
  user,
  onLogin,
  onProfile,
}: {
  targetType: SocialTarget;
  targetId: string;
  user: User | null;
  onLogin: () => void;
  onProfile?: (id: string) => void;
}) {
  const base = `/social/${targetType}/${encodeURIComponent(targetId)}`;
  const [summary, setSummary] = useState<SocialSummary | null>(null),
    [thread, setThread] = useState<SocialComment[]>([]),
    [expanded, setExpanded] = useState(false),
    [next, setNext] = useState<string | null>(null),
    [draft, setDraft] = useState(""),
    [reply, setReply] = useState<SocialComment | null>(null),
    [editing, setEditing] = useState<SocialComment | null>(null),
    [reporting, setReporting] = useState<string | null>(null),
    [reason, setReason] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const submission = useRef<{
      key: string;
      body: string;
      parent: string | null;
    } | null>(null),
    generation = useRef(0);
  async function load(all = expanded, version = generation.current) {
    if (version !== generation.current) return;
    const value = await api<SocialSummary>(base);
    if (version !== generation.current) return;
    setSummary(value);
    if (all) {
      const page = await api<{
        comments: SocialComment[];
        nextCursor: string | null;
      }>(base + "/comments");
      if (version !== generation.current) return;
      setThread(page.comments);
      setNext(page.nextCursor);
    }
  }
  useEffect(() => {
    generation.current++;
    setSummary(null);
    setExpanded(false);
    setThread([]);
    setDraft("");
    setReply(null);
    setEditing(null);
    setReporting(null);
    setReason("");
    setError("");
    setBusy(false);
    submission.current = null;
    const version = generation.current;
    void load(false, version).catch((e) => {
      if (version === generation.current) setError(e.message);
    });
    return () => {
      generation.current++;
    };
  }, [base, user?.id]);
  useEffect(() => {
    const refresh = () => {
      const version = generation.current;
      void load(false, version).catch(() => {});
    };
    window.addEventListener("social-saved-changed", refresh);
    return () => window.removeEventListener("social-saved-changed", refresh);
  }, [base, user?.id]);
  async function perform(action: (current: () => boolean) => Promise<void>) {
    if (!user) {
      onLogin();
      return;
    }
    setBusy(true);
    setError("");
    const version = generation.current;
    try {
      await action(() => version === generation.current);
    } catch (e) {
      if (version === generation.current)
        setError(e instanceof Error ? e.message : "Please try again.");
    } finally {
      if (version === generation.current) setBusy(false);
    }
  }
  async function toggle(kind: "like" | "save") {
    if (!summary) return;
    await perform(async (current) => {
      const key = kind === "like" ? "liked" : "saved";
      await api(base + "/" + kind, { [key]: !summary[key] });
      if (!current()) return;
      if (kind === "save")
        window.dispatchEvent(new Event("social-saved-changed"));
      await load();
    });
  }
  async function expand() {
    const version = generation.current;
    setExpanded(!expanded);
    if (!expanded) {
      setError("");
      try {
        await load(true, version);
      } catch (e) {
        if (version === generation.current) setError((e as Error).message);
      }
    }
  }
  async function submit() {
    await perform(async (current) => {
      if (editing) {
        await api(`/social/comments/${editing.id}/edit`, { body: draft });
      } else {
        const parent = reply?.id ?? null;
        if (
          !submission.current ||
          submission.current.body !== draft ||
          submission.current.parent !== parent
        )
          submission.current = {
            key: crypto.randomUUID(),
            body: draft,
            parent,
          };
        await api(base + "/comments", {
          body: draft,
          parentId: parent,
          clientId: submission.current.key,
        });
      }
      if (!current()) return;
      setDraft("");
      setReply(null);
      setEditing(null);
      submission.current = null;
      await load(true);
    });
  }
  const visibleComments = expanded ? thread : (summary?.comments ?? []);
  return (
    <section className="social-actions" aria-label="Post community actions">
      <div className="social-action-bar">
        <button
          aria-label={summary?.liked ? "Unlike post" : "Like post"}
          aria-pressed={summary?.liked ?? false}
          disabled={busy || !summary}
          onClick={() => void toggle("like")}
        >
          <Heart size={19} fill={summary?.liked ? "currentColor" : "none"} />
          <span>{summary?.likeCount ?? 0}</span>
        </button>
        <button onClick={() => void expand()} aria-expanded={expanded}>
          <MessageCircle size={19} />
          <span>{summary?.commentCount ?? 0}</span>
          <span className="sr-only"> comments</span>
        </button>
        <button
          className="social-save"
          aria-label={summary?.saved ? "Unsave post" : "Save post privately"}
          aria-pressed={summary?.saved ?? false}
          disabled={busy || !summary}
          onClick={() => void toggle("save")}
        >
          <Bookmark size={19} fill={summary?.saved ? "currentColor" : "none"} />
        </button>
      </div>
      {error && (
        <p className="social-error" role="alert">
          {error}{" "}
          <button onClick={() => void load().catch((e) => setError(e.message))}>
            Retry loading
          </button>
        </p>
      )}
      <div className="social-thread">
        {visibleComments.map((c) => (
          <div
            key={c.id}
            className={`social-comment ${c.parentId ? "social-reply" : ""}`}
          >
            <div>
              <button
                className="social-author"
                disabled={!c.authorId || !onProfile}
                onClick={() => c.authorId && onProfile?.(c.authorId)}
              >
                {c.authorName}
              </button>
              {c.parentId && <small> Reply</small>}
              {c.editedAt && !c.unavailable && <small> · edited</small>}
            </div>
            <p>{c.body}</p>
            {expanded && !c.unavailable && (
              <div className="social-comment-options">
                {!c.parentId && (
                  <button
                    onClick={() => {
                      if (!user) {
                        onLogin();
                        return;
                      }
                      setReply(c);
                      setEditing(null);
                      setDraft("");
                    }}
                  >
                    Reply
                  </button>
                )}
                {user?.id === c.authorId ? (
                  <>
                    <button
                      onClick={() => {
                        setEditing(c);
                        setReply(null);
                        setDraft(c.body);
                      }}
                    >
                      Edit
                    </button>
                    <button
                      disabled={busy}
                      onClick={() =>
                        void perform(async (current) => {
                          await api(`/social/comments/${c.id}/delete`, {});
                          if (current()) await load(true);
                        })
                      }
                    >
                      Delete
                    </button>
                  </>
                ) : (
                  <button
                    onClick={() => {
                      if (!user) {
                        onLogin();
                        return;
                      }
                      setReporting(c.id);
                      setReason("");
                    }}
                  >
                    Report
                  </button>
                )}
              </div>
            )}
            {reporting === c.id && (
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  void perform(async (current) => {
                    await api(`/social/comments/${c.id}/report`, { reason });
                    if (!current()) return;
                    setReporting(null);
                    setReason("");
                  });
                }}
              >
                <label>
                  Why are you reporting this comment?
                  <input
                    maxLength={1000}
                    required
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                  />
                </label>
                <button disabled={busy}>Submit report</button>
                <button type="button" onClick={() => setReporting(null)}>
                  Cancel
                </button>
              </form>
            )}
          </div>
        ))}
      </div>
      {expanded && next && (
        <button
          disabled={busy}
          onClick={() => {
            const version = generation.current;
            setBusy(true);
            api<{ comments: SocialComment[]; nextCursor: string | null }>(
              base + "/comments?cursor=" + encodeURIComponent(next),
            )
              .then((p) => {
                if (version !== generation.current) return;
                setThread((old) => [...old, ...p.comments]);
                setNext(p.nextCursor);
              })
              .catch((e) => {
                if (version === generation.current) setError(e.message);
              })
              .finally(() => {
                if (version === generation.current) setBusy(false);
              });
          }}
        >
          Load more comments
        </button>
      )}
      {!expanded && (summary?.commentCount ?? 0) > 0 && (
        <button className="social-open-thread" onClick={() => void expand()}>
          View conversation
        </button>
      )}
      {expanded &&
        (user ? (
          <form
            className="social-composer"
            onSubmit={(e) => {
              e.preventDefault();
              void submit();
            }}
          >
            {(reply || editing) && (
              <p>
                {editing
                  ? "Editing your comment"
                  : `Replying to ${reply?.authorName}`}{" "}
                <button
                  type="button"
                  onClick={() => {
                    setReply(null);
                    setEditing(null);
                    setDraft("");
                  }}
                >
                  Cancel
                </button>
              </p>
            )}
            <label>
              <span className="sr-only">Public comment</span>
              <textarea
                placeholder="Join the conversation…"
                value={draft}
                maxLength={1500}
                required
                onChange={(e) => setDraft(e.target.value)}
              />
            </label>
            <small>
              Comments are public. Share phone numbers and documents privately.
            </small>
            <button disabled={busy || !draft.trim()}>
              {busy ? "Saving…" : editing ? "Save edit" : "Post comment"}
            </button>
          </form>
        ) : (
          <button onClick={onLogin}>Sign in to join the conversation</button>
        ))}
    </section>
  );
}
