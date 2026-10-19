import { createHash } from "node:crypto";
import { TextDecoder } from "node:util";
import { posix } from "node:path";
import {
  emptyReport,
  exactKeys,
  escape,
  modelContext,
  compactContext,
  FULL_REVIEW_LIMITS,
  parsePatch,
  renderComment,
  review,
  safePath,
  sha,
  text,
  validateFindings,
} from "./core.mjs";
import {
  currentMatches,
  publishComment,
  validateReport,
  validateTarget,
} from "./github.mjs";

export const BATCH_LIMITS = Object.freeze({
  files: 300,
  batches: 24,
  unitBytes: 110000,
  changedBytes: 200000,
  contextBytes: 280000,
  blobBytes: 1000000,
  sourceBytes: 12000000,
  runMs: 60 * 60 * 1000,
  artifactBytes: 1000000,
});
class UnsupportedSourceError extends Error {}
const bytes = (value) => Buffer.byteLength(JSON.stringify(value));
const digest = (value) =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex");
const sensitive = (path) =>
  /(^|\/)(?:\.env(\.|$)|\.dev\.vars(\.|$))|\.(pem|key|p8|p12|pfx|mobileprovision)$/i.test(
    path,
  );
const asset = (path) =>
  /\.(png|jpe?g|gif|webp|ico)$/i.test(path) ||
  /^docs\/mobile\/fixtures\/[^/]+\.(ply|roomcapture)$/.test(path);
const targetOf = (plan) => ({
  base: plan.base,
  head: plan.head,
  pr: plan.pr,
  repository: plan.repository,
});

// Verify complete patches against immutable blobs, then split oversized files at
// original diff coordinates. No contributor code, external diff tool or model runs here.
export function fileUnits(file, { full = false } = {}) {
  const changed = parsePatch(file.patch);
  if (
    changed.left.size !== file.deletions ||
    changed.right.size !== file.additions
  )
    throw new Error("Incomplete patch");
  const before = file.base.split("\n"),
    after = file.head.split("\n");
  const hunks = file.patch.split(/(?=^@@ )/m).filter(Boolean);
  const pieces = [];
  for (const hunk of hunks) {
    const rows = hunk.split("\n");
    const header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(
      rows.shift(),
    );
    if (!header) throw new Error("Invalid patch header");
    let oldLine = Number(header[1]),
      newLine = Number(header[3]);
    let group = [],
      oldStart = oldLine,
      newStart = newLine,
      oldCount = 0,
      newCount = 0;
    const flush = () => {
      if (!group.length) return;
      pieces.push({
        oldStart,
        newStart,
        oldCount,
        newCount,
        patch:
          `@@ -${oldStart},${oldCount} +${newStart},${newCount} @@\n` +
          group.join("\n"),
      });
      group = [];
      oldStart = oldLine;
      newStart = newLine;
      oldCount = newCount = 0;
    };
    for (const row of rows) {
      if (row === "" || row.startsWith("\\ No newline")) continue;
      if (row[0] !== "+") {
        if (before[oldLine - 1] !== row.slice(1))
          throw new Error("Base patch evidence mismatch");
        oldLine++;
        oldCount++;
      }
      if (row[0] !== "-") {
        if (after[newLine - 1] !== row.slice(1))
          throw new Error("Head patch evidence mismatch");
        newLine++;
        newCount++;
      }
      group.push(row);
      if (group.length >= 160) flush();
    }
    flush();
  }
  const basic = {
    path: file.path,
    status: file.status,
    patch: file.patch,
    base: file.base,
    head: file.head,
    baseStart: 1,
    headStart: 1,
  };
  const size = (f) => bytes(modelContext({ files: [f], surrounding: [] }));
  if (full || size(basic) <= BATCH_LIMITS.unitBytes) return [basic];
  const window = (group) => {
    const first = group[0],
      last = group.at(-1);
    const baseStart = Math.max(1, first.oldStart - 40),
      headStart = Math.max(1, first.newStart - 40);
    return {
      ...basic,
      baseStart,
      headStart,
      base: before
        .slice(baseStart - 1, last.oldStart + last.oldCount + 40)
        .join("\n"),
      head: after
        .slice(headStart - 1, last.newStart + last.newCount + 40)
        .join("\n"),
      patch: group.map((x) => x.patch).join("\n"),
    };
  };
  const units = [];
  let group = [];
  for (const piece of pieces) {
    if (
      group.length &&
      size(window([...group, piece])) > BATCH_LIMITS.unitBytes
    ) {
      units.push(window(group));
      group = [];
    }
    group.push(piece);
    if (size(window(group)) > BATCH_LIMITS.unitBytes)
      throw new Error("Single diff segment exceeds unit budget");
  }
  if (group.length) units.push(window(group));
  return units;
}

export async function collectFullPlan(api, target, standards) {
  return collectPlan(api, target, standards, { full: true });
}
export async function collectPlan(
  api,
  target,
  standards,
  { full = false } = {},
) {
  validateTarget(target);
  const plan = {
    pr: target.pr,
    base: target.base,
    head: target.head,
    repository: target.repository,
    changedFiles: 0,
    issues: [],
    excluded: [],
    batches: [],
  };
  const fail = (reason) => {
    plan.issues.push(reason);
    return plan;
  };
  const pr = await api("/pulls/" + target.pr);
  if (!currentMatches(pr, target))
    return fail("PR closed or base/head changed.");
  if (
    !Number.isSafeInteger(pr.changed_files) ||
    pr.changed_files < 1 ||
    pr.changed_files > BATCH_LIMITS.files
  )
    return fail("Changed file count exceeds the 300-file run bound.");
  plan.changedFiles = pr.changed_files;
  if (Buffer.byteLength(pr.body || "") > 10000)
    return fail("PR description exceeds bound.");
  const comparison = await api(`/compare/${target.base}...${target.head}`);
  if (comparison.merge_base_commit?.sha !== target.base)
    return fail("Update branch against current base before review.");
  const files = [];
  for (let page = 1; page <= 3; page++) {
    const next = await api(
      `/pulls/${target.pr}/files?per_page=100&page=${page}`,
    );
    if (!Array.isArray(next)) return fail("Invalid changed-file enumeration.");
    files.push(...next);
    if (next.length < 100) break;
  }
  if (
    files.length !== pr.changed_files ||
    new Set(files.map((f) => f.filename)).size !== files.length
  )
    return fail("Incomplete or duplicate changed-file enumeration.");
  files.sort((a, b) => a.filename.localeCompare(b.filename, "en"));
  const trees = {};
  for (const ref of [target.base, target.head]) {
    const tree = await api(`/git/trees/${ref}?recursive=1`);
    if (tree.truncated || !Array.isArray(tree.tree) || tree.tree.length > 10000)
      return fail("Repository tree is incomplete.");
    trees[ref] = new Map(
      tree.tree.filter((f) => f.type === "blob").map((f) => [f.path, f]),
    );
  }
  const cache = new Map();
  let loaded = 0;
  const source = async (path, ref) => {
    safePath(path);
    if (sensitive(path))
      throw new UnsupportedSourceError("Sensitive path excluded");
    const entry = trees[ref].get(path);
    if (
      !entry ||
      !["100644", "100755"].includes(entry.mode) ||
      entry.size > BATCH_LIMITS.blobBytes
    )
      throw new UnsupportedSourceError("Unsupported source type or size");
    if (cache.has(entry.sha)) return cache.get(entry.sha);
    const blob = await api("/git/blobs/" + sha(entry.sha));
    if (blob.encoding !== "base64" || blob.size > BATCH_LIMITS.blobBytes)
      throw new Error("Unsupported blob");
    const raw = Buffer.from(blob.content, "base64");
    loaded += raw.length;
    if (raw.length !== blob.size || loaded > BATCH_LIMITS.sourceBytes)
      throw new Error("Invalid source or total source budget exceeded");
    if (raw.includes(0)) throw new UnsupportedSourceError("Binary source");
    let content;
    try {
      content = new TextDecoder("utf-8", { fatal: true }).decode(raw);
    } catch {
      throw new UnsupportedSourceError("Non-UTF-8 source");
    }
    cache.set(entry.sha, content);
    return content;
  };
  const units = [];
  for (const file of files) {
    safePath(file.filename);
    if (
      !sensitive(file.filename) &&
      asset(file.filename) &&
      !file.patch &&
      file.additions === 0 &&
      file.deletions === 0 &&
      ["added", "modified", "removed"].includes(file.status)
    ) {
      plan.excluded.push(file.filename);
      continue;
    }
    try {
      if (!["added", "modified", "removed"].includes(file.status))
        throw new Error("Unsupported change kind");
      const base =
        file.status === "added" ? "" : await source(file.filename, target.base);
      const head =
        file.status === "removed"
          ? ""
          : await source(file.filename, target.head);
      const original = {
        ...file,
        path: file.filename,
        base,
        head,
      };
      const verifiedUnits = fileUnits(original, { full });
      for (const [index, unit] of verifiedUnits.entries())
        units.push({ ...unit, unitId: file.filename + "#" + index });
    } catch {
      plan.issues.push("Cannot fully collect text change: " + file.filename);
    }
  }
  const template = {
    ...(full ? { reviewMode: "full-context-v1" } : {}),
    base: target.base,
    head: target.head,
    mergeBase: target.base,
    pr: target.pr,
    description: pr.body || "",
    complete: true,
    omissions: [],
    standards: text(standards, 60000),
    files: [],
    surrounding: [],
    checks: [],
    scope: { visualAssets: plan.excluded, supportingFilesOmitted: 0 },
    batch: {
      changedPaths: files.map((f) => f.filename),
      instructions: full
        ? "Review all collected changed text together. Complete head files, deleted base lines with surrounding context, removed files, and related source retain original line coordinates. Report insufficient relevant context honestly."
        : "This is one bounded batch. Review its changed lines; other changed paths are inventory, not reviewed evidence. Source excerpts preserve original line numbers. Supporting files provide cross-component context but may be incomplete. Report insufficient relevant context honestly.",
    },
  };
  const present = full ? compactContext : modelContext;
  const inputLimit = full
    ? FULL_REVIEW_LIMITS.characters - 20_000
    : BATCH_LIMITS.changedBytes;
  let batch = structuredClone(template);
  for (const unit of units) {
    const proposed = { ...batch, files: [...batch.files, unit] };
    if (
      batch.files.length &&
      !full &&
      (batch.files.length >= 40 || bytes(present(proposed)) > inputLimit)
    ) {
      plan.batches.push(batch);
      batch = structuredClone(template);
    }
    batch.files.push(unit);
    if (bytes(present(batch)) > inputLimit)
      return fail(
        "A source unit plus mandatory context exceeds the batch budget.",
      );
  }
  if (batch.files.length) plan.batches.push(batch);
  if (!plan.batches.length)
    return fail(
      "No reviewable text changes; excluded assets require human review.",
    );
  if (plan.batches.length > BATCH_LIMITS.batches) {
    plan.batches = [];
    return fail("Review exceeds the 24-batch run bound.");
  }
  // Neighbor, contract and authorization source is repeated as context across batches.
  // Read only a small deterministic sample; every changed line remains mandatory above.
  for (const [index, context] of plan.batches.entries()) {
    context.batch.index = index + 1;
    context.batch.total = plan.batches.length;
    const paths = new Set(context.files.map((f) => f.path)),
      folders = new Set([...paths].map(posix.dirname));
    const imports = new Set();
    for (const file of context.files) {
      // Read already-verified complete blobs so segmented units still retain imports.
      const source = [target.base, target.head]
        .map((ref) => cache.get(trees[ref].get(file.path)?.sha) || "")
        .join("\n");
      for (const match of source.matchAll(
        /(?:from\s*|import\s*\(\s*|import\s*)["'](\.[^"']+)["']/g,
      )) {
        const imported = posix.normalize(
          posix.join(posix.dirname(file.path), match[1]),
        );
        for (const suffix of [
          "",
          ".ts",
          ".tsx",
          ".js",
          ".mjs",
          "/index.ts",
          "/index.tsx",
        ])
          imports.add(imported + suffix);
      }
    }
    const candidates = [...trees[target.head].keys()].filter(
      (p) =>
        !paths.has(p) &&
        /\.(swift|[cm]?[jt]sx?|json|sql|py|html|css)$/.test(p) &&
        !/(package-lock\.json|worker-configuration\.d\.ts)$/.test(p) &&
        (imports.has(p) ||
          folders.has(posix.dirname(p)) ||
          /^(shared\/|worker\/(?:.*auth|account|member)|ios\/CuseSublets\/(?:APIClient|Models|PhotoCapturePolicy))/.test(
            p,
          )),
    );
    candidates.sort(
      (a, b) =>
        Number(!imports.has(a)) - Number(!imports.has(b)) ||
        Number(!/auth|Models|APIClient|shared\//i.test(a)) -
          Number(!/auth|Models|APIClient|shared\//i.test(b)) ||
        a.localeCompare(b, "en"),
    );
    let count = 0;
    for (const path of candidates) {
      if (
        !full &&
        (count >= 8 || (trees[target.head].get(path).size || 0) > 60000)
      ) {
        context.scope.supportingFilesOmitted++;
        continue;
      }
      try {
        const content = await source(path, target.head);
        context.surrounding.push({ path, ref: target.head, content });
        if (
          bytes(present(context)) >
          (full ? inputLimit : BATCH_LIMITS.contextBytes)
        ) {
          context.surrounding.pop();
          context.scope.supportingFilesOmitted++;
          if (full) return fail("Full review context exceeds bound: " + path);
        } else count++;
      } catch (error) {
        context.scope.supportingFilesOmitted++;
        if (full && !(error instanceof UnsupportedSourceError))
          return fail("Cannot collect related source: " + path);
      }
    }
  }
  if (!currentMatches(await api("/pulls/" + target.pr), target))
    return fail("PR changed during collection.");
  return plan;
}

export function planFingerprint(plan) {
  return digest(plan);
}
export const batchFingerprint = (context) => digest(context);
export const batchResult = (context, report) => ({
  id: batchFingerprint(context),
  report,
});
export function combine(plan, results, interrupted = false) {
  if (!Array.isArray(results) || results.length > plan.batches.length)
    throw new Error("Unexpected batch results");
  const findings = new Map();
  let completed = 0;
  results.forEach((entry, index) => {
    exactKeys(entry, ["id", "report"]);
    if (entry.id !== batchFingerprint(plan.batches[index]))
      throw new Error("Batch identity mismatch");
    const result = entry.report;
    validateReport(result);
    if (result.base !== plan.base || result.head !== plan.head)
      throw new Error("Batch commit mismatch");
    const context = plan.batches[index];
    validateFindings(
      {
        status: ["completed", "incomplete"].includes(result.status)
          ? result.status
          : "incomplete",
        findings: result.findings,
      },
      context,
    );
    if (result.status === "completed" && result.gpt.status === "completed")
      completed++;
    for (const f of result.findings) {
      const key = [f.path, f.side, f.start, f.end, f.evidence].join(":");
      const rank = { critical: 0, high: 1, medium: 2, low: 3 };
      if (
        !findings.has(key) ||
        rank[f.severity] < rank[findings.get(key).severity]
      )
        findings.set(key, f);
    }
  });
  const status =
    interrupted ||
    plan.issues.length ||
    !plan.batches.length ||
    completed !== plan.batches.length
      ? "incomplete"
      : "completed";
  const severity = { critical: 0, high: 1, medium: 2, low: 3 };
  return {
    status,
    completed,
    total: plan.batches.length,
    changedFiles: plan.changedFiles,
    units: plan.batches.reduce((n, b) => n + b.files.length, 0),
    excluded: plan.excluded,
    issues: interrupted
      ? [
          ...plan.issues,
          "Review orchestration interrupted; retained completed batches.",
        ]
      : plan.issues,
    findings: [...findings.values()].sort(
      (a, b) =>
        severity[a.severity] - severity[b.severity] ||
        a.path.localeCompare(b.path, "en") ||
        a.start - b.start,
    ),
  };
}
export function coverageManifest(plan) {
  return plan.batches.map((context) => ({
    id: batchFingerprint(context),
    units: context.files.map((file) => ({
      id: file.unitId,
      path: file.path,
      baseStart: file.baseStart,
      headStart: file.headStart,
      baseLines: file.base.split("\n").length,
      headLines: file.head.split("\n").length,
    })),
    supportingPaths: context.surrounding.map((file) => file.path),
  }));
}
export function envelope(plan, results, interrupted = false) {
  return {
    version: 2,
    base: plan.base,
    head: plan.head,
    fingerprint: planFingerprint(plan),
    coverage: coverageManifest(plan),
    results,
    interrupted,
    summary: combine(plan, results, interrupted),
  };
}
export function validateEnvelope(value, plan) {
  exactKeys(value, [
    "version",
    "base",
    "head",
    "fingerprint",
    "coverage",
    "results",
    "summary",
    "interrupted",
  ]);
  if (
    typeof value.interrupted !== "boolean" ||
    value.version !== 2 ||
    value.base !== plan.base ||
    value.head !== plan.head ||
    value.fingerprint !== planFingerprint(plan)
  )
    throw new Error("Review coverage fingerprint mismatch");
  if (JSON.stringify(value.coverage) !== JSON.stringify(coverageManifest(plan)))
    throw new Error("Coverage manifest mismatch");
  const summary = combine(plan, value.results, value.interrupted);
  if (JSON.stringify(value.summary) !== JSON.stringify(summary))
    throw new Error("Forged aggregate report");
  return summary;
}
export async function reviewPlan(
  plan,
  cfg,
  {
    reviewer = review,
    now = Date.now,
    onBatch = () => {},
    isCurrent = async () => true,
  } = {},
) {
  if (cfg.gptProvider !== "subscription")
    throw new Error("Batched review requires subscription");
  const results = [],
    start = now();
  // Collection problems are explicit coverage failures. Do not spend quota on a partial plan.
  if (!plan.issues.length)
    for (const [index, context] of plan.batches.entries()) {
      if (now() - start >= BATCH_LIMITS.runMs) break;
      try {
        if (!(await isCurrent())) return envelope(plan, results, true);
      } catch {
        return envelope(plan, results, true);
      }
      let result;
      try {
        result = await reviewer(context, cfg);
        validateReport(result);
      } catch {
        result = emptyReport(
          plan,
          "failed",
          "Batch execution failed; no result available.",
        );
      }
      results.push(batchResult(context, result));
      await onBatch(index + 1, result.status, envelope(plan, results));
      // A provider outage should not trigger 24 futile calls. Unattempted batches remain missing.
      if (["failed", "unavailable"].includes(result.status)) break;
    }
  return envelope(plan, results);
}
export function renderBatches(plan, value, latest) {
  const summary = validateEnvelope(value, plan);
  const full = plan.batches[0]?.reviewMode === "full-context-v1";
  const report = {
    ...emptyReport(
      plan,
      summary.status,
      `${summary.completed}/${summary.total} ${full ? "full-context text reviews" : "text batches"} completed; ${summary.changedFiles} changed files, ${summary.units} source units. ${summary.excluded.length} assets excluded for human review.`,
    ),
    findings: summary.findings.slice(0, 8),
  };
  report.gpt.status = summary.status;
  report.gpt.model = "claude/claude-opus-5-5" + (full ? "[1m]" : "");
  const lines = [
    renderComment(report, latest.head.sha, plan.repository, latest.base.sha),
  ];
  if (!currentMatches(latest, targetOf(plan))) return lines.join("\n\n");
  lines.push(
    "Coverage: " +
      plan.batches
        .map(
          (b, i) =>
            `batch ${i + 1}: ${value.results[i]?.report.status || "missing"} (${b.files.length} units)`,
        )
        .join("; "),
  );
  if (summary.findings.length > 8)
    lines.push(
      `${summary.findings.length} unique findings combined; the first 8 are shown here. The report.json workflow artifact contains every finding and batch result.`,
    );
  for (const issue of summary.issues)
    lines.push("Coverage failure: " + escape(issue));
  for (const [i, entry] of value.results.entries())
    if (entry.report.status !== "completed")
      lines.push(`Batch ${i + 1}: ` + escape(entry.report.reason));
  if (summary.excluded.length)
    lines.push(
      "Human asset review required: " + summary.excluded.map(escape).join(", "),
    );
  lines.push(
    full
      ? "One request reviews all collected text, requesting Claude Opus 5.5 with extended context and constrained JSON output. The gateway does not independently attest upstream model identity, effort or usage. Exact source evidence and coverage are independently revalidated. Binary assets still require human review; completion is not a guarantee of correctness."
      : "Each batch requests Claude Opus 5.5 through the High-effort subscription route. The gateway does not independently attest upstream model identity, effort or usage. Cross-file context is bounded; completed means all planned text batches completed, not a guarantee of correctness.",
  );
  return lines.join("\n\n");
}
export async function publishBatches(api, target, value, standards) {
  const plan = await collectFullPlan(api, target, standards);
  const summary = validateEnvelope(value, plan);
  const result = await publishComment(api, target, (latest) =>
    renderBatches(plan, value, latest),
  );
  return result.current && summary.status === "completed";
}
