import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import {
  collectPlan,
  fileUnits,
  combine,
  envelope,
  validateEnvelope,
  reviewPlan,
  publishBatches,
  BATCH_LIMITS,
} from "./ai-review/batches.mjs";
import {
  emptyReport,
  modelContext,
  parsePatch,
  validateFindings,
} from "./ai-review/core.mjs";
const base = "a".repeat(40),
  head = "b".repeat(40);
const target = { base, head, pr: 1, repository: "owner/repo" };
const added = (path, content) => ({
  filename: path,
  status: "added",
  additions: content.split("\n").length,
  deletions: 0,
  patch:
    `@@ -0,0 +1,${content.split("\n").length} @@\n` +
    content
      .split("\n")
      .map((l) => "+" + l)
      .join("\n"),
  content,
});
function fixture(
  files = Array.from({ length: 106 }, (_, i) =>
    added(
      `ios/File${String(i).padStart(3, "0")}.swift`,
      `let value${i} = ${i}`,
    ),
  ),
) {
  const responses = {
    "/pulls/1": {
      number: 1,
      state: "open",
      base: { sha: base, ref: "main", repo: { full_name: target.repository } },
      head: { sha: head },
      changed_files: files.length,
      body: "Review changes.",
    },
    [`/compare/${base}...${head}`]: { merge_base_commit: { sha: base } },
    [`/git/trees/${base}?recursive=1`]: { tree: [], truncated: false },
    [`/git/trees/${head}?recursive=1`]: { tree: [], truncated: false },
    "/issues/1/comments?per_page=100&page=1": [],
  };
  files.forEach((f, i) => {
    const id = (i + 1).toString(16).padStart(40, "0");
    responses[`/git/trees/${head}?recursive=1`].tree.push({
      path: f.filename,
      type: "blob",
      mode: "100644",
      sha: id,
      size: Buffer.byteLength(f.content || ""),
    });
    responses[`/git/blobs/${id}`] = {
      encoding: "base64",
      content: Buffer.from(f.content || "").toString("base64"),
      size: Buffer.byteLength(f.content || ""),
    };
  });
  for (let page = 1; page <= 3; page++)
    responses[`/pulls/1/files?per_page=100&page=${page}`] = files
      .slice((page - 1) * 100, page * 100)
      .map(({ content, ...f }) => f);
  const writes = [];
  const api = async (path, opts) => {
    if (opts?.method) {
      writes.push(opts.body);
      return { id: 1 };
    }
    assert.ok(path in responses, path);
    return structuredClone(responses[path]);
  };
  return { api, responses, writes };
}
const complete = (context, findings = []) => ({
  ...emptyReport(context, "completed", ""),
  findings,
  gpt: {
    ...emptyReport(context, "completed", "").gpt,
    status: "completed",
    model: "claude/claude-opus-5-5",
  },
});
const answer = (file) => ({
  path: file.path,
  side: "RIGHT",
  start: file.headStart || 1,
  end: file.headStart || 1,
  severity: "high",
  title: "Example finding",
  explanation: "Synthetic regression evidence.",
  evidence: file.head.split("\n")[0],
});

test("106 changed files paginate into bounded batches with each text unit exactly once", async () => {
  const plan = await collectPlan(fixture().api, target, "Trusted standards");
  assert.deepEqual(plan.issues, []);
  assert.equal(plan.changedFiles, 106);
  assert.equal(plan.batches.length, 3);
  const units = plan.batches.flatMap((b) => b.files);
  assert.equal(units.length, 106);
  assert.equal(new Set(units.map((f) => f.unitId)).size, 106);
  for (const b of plan.batches) {
    assert.ok(b.files.length <= 40);
    assert.ok(
      Buffer.byteLength(JSON.stringify(modelContext(b))) <=
        BATCH_LIMITS.contextBytes,
    );
  }
});
test("oversized files split with original coordinates and cover every changed line once", () => {
  const source = Array.from(
    { length: 1500 },
    (_, i) => `let value${i} = "${"x".repeat(120)}"`,
  ).join("\n");
  const f = added("ios/Large.swift", source),
    units = fileUnits({ ...f, path: f.filename, base: "", head: source });
  assert.ok(units.length > 1);
  const covered = units.flatMap((u) => [...parsePatch(u.patch).right]);
  assert.equal(covered.length, 1500);
  assert.equal(new Set(covered).size, 1500);
  for (const unit of units) {
    const line = [...parsePatch(unit.patch).right][0];
    const evidence = source.split("\n")[line - 1];
    assert.equal(
      validateFindings(
        {
          status: "completed",
          findings: [{ ...answer(unit), start: line, end: line, evidence }],
        },
        { files: [unit] },
      ).findings.length,
      1,
    );
    assert.equal(
      modelContext({ files: [unit], surrounding: [] }).files[0].head[0].line,
      unit.headStart,
    );
  }
});
test("patch evidence and missing patch rows cannot be hidden by chunking", () => {
  const f = added("file.ts", "one\ntwo");
  assert.throws(
    () => fileUnits({ ...f, path: f.filename, base: "", head: "one\nforged" }),
    /mismatch/,
  );
  assert.throws(
    () =>
      fileUnits({
        ...f,
        path: f.filename,
        base: "",
        head: f.content,
        additions: 1,
      }),
    /Incomplete/,
  );
});
test("missing pages, duplicate files and changed heads cannot report complete coverage", async () => {
  for (const mutate of [
    (r) => r["/pulls/1/files?per_page=100&page=2"].pop(),
    (r) =>
      (r["/pulls/1/files?per_page=100&page=2"][0] =
        r["/pulls/1/files?per_page=100&page=1"][0]),
    (r) => (r["/pulls/1"].head.sha = "c".repeat(40)),
  ]) {
    const f = fixture();
    mutate(f.responses);
    const plan = await collectPlan(f.api, target, "standards");
    assert.ok(plan.issues.length);
    assert.equal(combine(plan, []).status, "incomplete");
  }
});
test("supported binary assets are disclosed; unsupported source and secrets block inference", async () => {
  const image = {
    filename: "image.png",
    status: "added",
    additions: 0,
    deletions: 0,
  };
  const plan = await collectPlan(
    fixture([added("a.ts", "a"), image]).api,
    target,
    "s",
  );
  assert.deepEqual(plan.excluded, ["image.png"]);
  assert.deepEqual(plan.issues, []);
  for (const name of ["archive.zip", ".env.production", "ios/private.p8"]) {
    const p = await collectPlan(
      fixture([added("a.ts", "a"), { ...image, filename: name }]).api,
      target,
      "s",
    );
    assert.ok(p.issues.length);
    let called = 0;
    const result = await reviewPlan(
      p,
      { gptProvider: "subscription" },
      {
        reviewer: () => {
          called++;
        },
      },
    );
    assert.equal(called, 0);
    assert.equal(result.summary.status, "incomplete");
  }
  const only = await collectPlan(fixture([image]).api, target, "s");
  assert.equal(combine(only, []).status, "incomplete");
});
test("combined result retains findings from every batch and cannot turn missing or failed batches green", async () => {
  const plan = await collectPlan(fixture().api, target, "s");
  const results = plan.batches.map((b) => complete(b, [answer(b.files[0])]));
  assert.equal(combine(plan, results).findings.length, 3);
  assert.equal(combine(plan, results).status, "completed");
  for (const status of ["incomplete", "failed", "unavailable"]) {
    const r = [...results];
    r[1] = emptyReport(plan, status, "synthetic failure");
    const all = combine(plan, r);
    assert.equal(all.status, "incomplete");
    assert.equal(all.findings.length, 2);
  }
  assert.equal(combine(plan, results.slice(0, 2)).status, "incomplete");
  const forged = envelope(plan, results);
  forged.summary.completed = 99;
  assert.throws(() => validateEnvelope(forged, plan), /Forged/);
  const wrong = structuredClone(envelope(plan, results));
  wrong.results[0].head = "c".repeat(40);
  assert.throws(() => validateEnvelope(wrong, plan), /commit/);
  const uncovered = structuredClone(envelope(plan, results));
  uncovered.results[0].findings = [answer(plan.batches[2].files[0])];
  assert.throws(() => validateEnvelope(uncovered, plan), /location/);
});
test("publisher independently rebuilds coverage and rejects fabricated successful summaries", async () => {
  const f = fixture();
  const plan = await collectPlan(f.api, target, "s");
  const result = envelope(
    plan,
    plan.batches.map((b) => complete(b)),
  );
  assert.equal(await publishBatches(f.api, target, result, "s"), true);
  assert.match(f.writes.at(-1).body, /3\/3 text batches completed/);
  result.results.pop();
  await assert.rejects(
    () => publishBatches(f.api, target, result, "s"),
    /Forged/,
  );
});
test("batch execution is serial, retains valid results and stops on provider outage or run deadline", async () => {
  const plan = await collectPlan(fixture().api, target, "s");
  let calls = 0,
    active = 0;
  const result = await reviewPlan(
    plan,
    { gptProvider: "subscription" },
    {
      reviewer: async (context) => {
        assert.equal(active++, 0);
        await Promise.resolve();
        active--;
        return ++calls === 2
          ? emptyReport(context, "failed", "outage")
          : complete(context, [answer(context.files[0])]);
      },
    },
  );
  assert.equal(calls, 2);
  assert.equal(result.summary.status, "incomplete");
  assert.equal(result.summary.findings.length, 1);
  let time = 0;
  const limited = await reviewPlan(
    plan,
    { gptProvider: "subscription" },
    {
      now: () => time,
      reviewer: async (c) => {
        time = BATCH_LIMITS.runMs;
        return complete(c);
      },
    },
  );
  assert.equal(limited.results.length, 1);
  assert.equal(limited.summary.status, "incomplete");
});
test("CLI writes failure artifact, publishes it and exits nonzero for incomplete review", async () => {
  const dir = await mkdtemp(join(tmpdir(), "review-cli-"));
  try {
    const f = fixture([added("a.ts", "a")]);
    f.responses["/pulls/1"].changed_files = 301;
    const preload = join(dir, "mock.mjs");
    await writeFile(
      preload,
      `const responses=${JSON.stringify(f.responses)}; globalThis.fetch=async(url,options)=>{const path=url.replace('https://api.github.com/repos/owner/repo','');if(options.method==='POST'||options.method==='PATCH')return new Response('{"id":1}');if(!(path in responses))throw new Error('unexpected path');return new Response(JSON.stringify(responses[path]));};`,
    );
    const event = join(dir, "event.json");
    await writeFile(
      event,
      JSON.stringify({ number: 1, pull_request: f.responses["/pulls/1"] }),
    );
    // Run from an isolated working directory with only trusted standards and no dependencies.
    await writeFile(join(dir, "AGENTS.md"), "test standards");
    await import("node:fs/promises").then((fs) => fs.mkdir(join(dir, "docs")));
    await writeFile(join(dir, "docs/review-standards.md"), "test standards");
    const env = {
      PATH: process.env.PATH,
      GITHUB_EVENT_PATH: event,
      GITHUB_REPOSITORY: target.repository,
      GITHUB_TOKEN: "synthetic",
      GPT_PROVIDER: "subscription",
    };
    const command = resolve("scripts/ai-review/run.mjs");
    const run = spawnSync(
      process.execPath,
      ["--import", preload, command, "review"],
      { cwd: dir, env, encoding: "utf8" },
    );
    assert.equal(run.status, 1, run.stderr);
    const report = JSON.parse(
      await readFile(join(dir, "ai-review-output/report.json")),
    );
    assert.equal(report.summary.status, "incomplete");
    const published = spawnSync(
      process.execPath,
      ["--import", preload, command, "publish"],
      { cwd: dir, env, encoding: "utf8" },
    );
    assert.equal(published.status, 1, published.stderr);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
