import { useCallback, useEffect, useRef, useState } from "react";
import type { DraftKind, PrivateDraft } from "../shared/drafts";
import { api } from "./api";
export function usePrivateDraft(
  id: string,
  kind: DraftKind,
  restore: (draft: PrivateDraft) => void,
) {
  const restoreRef = useRef(restore);
  restoreRef.current = restore;
  const revision = useRef(0),
    [ready, setReady] = useState(false),
    [saved, setSaved] = useState(false),
    [error, setError] = useState("");
  const load = useCallback(async () => {
    setReady(false);
    setError("");
    try {
      const result = await api<{
        draft: PrivateDraft | null;
        revision: number;
      }>(`/drafts/${id}`);
      revision.current = result.revision;
      if (result.draft) {
        restoreRef.current(result.draft);
        setSaved(true);
      }
      setReady(true);
    } catch (cause) {
      setError((cause as Error).message);
    }
  }, [id]);
  useEffect(() => {
    void load();
  }, [load]);
  async function save(data: PrivateDraft["data"], step: number) {
    if (!ready)
      throw new Error("Wait for your saved draft to load before continuing.");
    const result = await api<{ draft: PrivateDraft; revision: number }>(
      `/drafts/${id}`,
      { kind, step, data, revision: revision.current },
    );
    revision.current = result.revision;
    setSaved(true);
    window.dispatchEvent(new Event("drafts-changed"));
    return result.draft;
  }
  async function clear() {
    if (!revision.current) return;
    const result = await api<{ revision: number }>(`/drafts/${id}/delete`, {
      revision: revision.current,
    });
    revision.current = result.revision;
    setSaved(false);
    window.dispatchEvent(new Event("drafts-changed"));
  }
  return { ready, saved, error, save, clear, load };
}
