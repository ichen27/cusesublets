import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import {
  collectPlan,
  collectFullPlan,
  fileUnits,
  combine,
  envelope,
  validateEnvelope,
  reviewPlan,
  publishBatches,
  BATCH_LIMITS,
  batchResult,
} from "./ai-review/batches.mjs";
import {
  emptyReport,
  modelContext,
  compactContext,
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
  const results = plan.batches.map((b) =>
    batchResult(b, complete(b, [answer(b.files[0])])),
  );
  assert.equal(combine(plan, results).findings.length, 3);
  assert.equal(combine(plan, results).status, "completed");
  for (const status of ["incomplete", "failed", "unavailable"]) {
    const r = [...results];
    r[1] = batchResult(
      plan.batches[1],
      emptyReport(plan, status, "synthetic failure"),
    );
    const all = combine(plan, r);
    assert.equal(all.status, "incomplete");
    assert.equal(all.findings.length, 2);
  }
  assert.equal(combine(plan, results.slice(0, 2)).status, "incomplete");
  const forged = envelope(plan, results);
  forged.summary.completed = 99;
  assert.throws(() => validateEnvelope(forged, plan), /Forged/);
  const wrong = structuredClone(envelope(plan, results));
  wrong.results[0].report.head = "c".repeat(40);
  assert.throws(() => validateEnvelope(wrong, plan), /commit/);
  const uncovered = structuredClone(envelope(plan, results));
  uncovered.results[0].report.findings = [answer(plan.batches[2].files[0])];
  assert.throws(() => validateEnvelope(uncovered, plan), /location/);
});
test("publisher independently rebuilds coverage and rejects fabricated successful summaries", async () => {
  const f = fixture();
  const plan = await collectFullPlan(f.api, target, "s");
  const result = envelope(
    plan,
    plan.batches.map((b) => batchResult(b, complete(b))),
  );
  assert.equal(await publishBatches(f.api, target, result, "s"), true);
  assert.match(
    f.writes.at(-1).body,
    /1\/1 full-context text reviews completed/,
  );
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
    await writeFile(
      join(dir, "ai-review-output/report.json"),
      JSON.stringify(complete(target)),
    );
    const legacy = spawnSync(
      process.execPath,
      ["--import", preload, command, "publish"],
      { cwd: dir, env, encoding: "utf8" },
    );
    assert.equal(
      legacy.status,
      1,
      "Legacy success must not bypass batch coverage verification",
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("duplicated or reordered empty successes cannot stand in for missing batches", async () => {
  const plan = await collectPlan(fixture().api, target, "s");
  const results = plan.batches.map((b) => batchResult(b, complete(b)));
  assert.throws(
    () => envelope(plan, [results[0], results[0], results[2]]),
    /identity/,
  );
  assert.throws(
    () => envelope(plan, [results[1], results[0], results[2]]),
    /identity/,
  );
});
test("transient orchestration failure retains completed findings and marks interruption", async () => {
  const plan = await collectPlan(fixture().api, target, "s");
  let reads = 0;
  const result = await reviewPlan(
    plan,
    { gptProvider: "subscription" },
    {
      reviewer: async (c) => complete(c, [answer(c.files[0])]),
      isCurrent: async () => {
        if (++reads === 2) throw new Error("GitHub unavailable");
        return true;
      },
    },
  );
  assert.equal(result.results.length, 1);
  assert.equal(result.interrupted, true);
  assert.equal(result.summary.status, "incomplete");
  assert.equal(result.summary.findings.length, 1);
  assert.equal(validateEnvelope(result, plan).completed, 1);
});
test("aggregate retains more than eight findings in the artifact", async () => {
  const plan = await collectPlan(fixture().api, target, "s");
  const results = plan.batches.map((b) =>
    batchResult(b, complete(b, b.files.slice(0, 5).map(answer))),
  );
  assert.equal(envelope(plan, results).summary.findings.length, 15);
});
test("large modified files retain evidence coordinates on both diff sides", () => {
  const lines = Array.from(
      { length: 4000 },
      (_, i) => `value${i}=${"x".repeat(70)}`,
    ),
    before = lines.join("\n");
  const oldA = lines[99],
    oldB = lines[2999];
  lines[99] = "newA";
  lines[2999] = "newB";
  const units = fileUnits({
    path: "large.ts",
    status: "modified",
    base: before,
    head: lines.join("\n"),
    additions: 2,
    deletions: 2,
    patch: `@@ -100 +100 @@\n-${oldA}\n+newA\n@@ -3000 +3000 @@\n-${oldB}\n+newB`,
  });
  assert.equal(units.length, 2);
  for (const side of ["LEFT", "RIGHT"]) {
    const finding = {
      ...answer(units[1]),
      side,
      start: 3000,
      end: 3000,
      evidence: side === "LEFT" ? oldB : "newB",
    };
    assert.equal(
      validateFindings(
        { status: "completed", findings: [finding] },
        { files: units },
      ).findings.length,
      1,
    );
  }
});

test("artifact identifies covered source units and rejects altered coverage manifests", async () => {
  const plan = await collectPlan(fixture().api, target, "s");
  const report = envelope(plan, []);
  assert.equal(report.coverage.flatMap((b) => b.units).length, 106);
  report.coverage[0].units.pop();
  assert.throws(() => validateEnvelope(report, plan), /manifest/);
});
test("duplicate findings within a response retain the higher severity", () => {
  const f = {
    path: "a.ts",
    patch: "@@ -0,0 +1 @@\n+unsafe",
    base: "",
    head: "unsafe",
    headStart: 1,
    baseStart: 1,
  };
  const high = answer(f),
    low = { ...high, severity: "low" };
  assert.equal(
    validateFindings(
      { status: "completed", findings: [high, low] },
      { files: [f] },
    ).findings[0].severity,
    "high",
  );
});

test("full context keeps all changed source together and includes related source beyond eight files", async () => {
  const f = fixture();
  const tree = f.responses[`/git/trees/${head}?recursive=1`].tree;
  for (let i = 0; i < 12; i++) {
    const id = (1000 + i).toString(16).padStart(40, "0");
    const content = `let supporting${i} = true`;
    tree.push({
      path: `ios/Supporting${i}.swift`,
      type: "blob",
      mode: "100644",
      sha: id,
      size: content.length,
    });
    f.responses[`/git/blobs/${id}`] = {
      encoding: "base64",
      content: Buffer.from(content).toString("base64"),
      size: content.length,
    };
  }
  const plan = await collectFullPlan(f.api, target, "standards");
  assert.deepEqual(plan.issues, []);
  assert.equal(plan.batches.length, 1);
  const c = plan.batches[0];
  assert.equal(c.files.length, 106);
  assert.equal(c.surrounding.length, 12);
  assert.equal(c.scope.supportingFilesOmitted, 0);
  const shown = compactContext(c);
  assert.match(shown.files[0].head, /^1:let value/);
  assert.deepEqual(shown.files[0].changedRight, [[1, 1]]);
  assert.equal(shown.files[0].patch, undefined);
  assert.equal(plan.batches[0].files[0].patch.startsWith("@@"), true);
  const propertyOrderPlan = await collectFullPlan(
    f.api,
    { repository: target.repository, head, base, pr: 1 },
    "standards",
  );
  assert.equal(
    envelope(plan, []).fingerprint,
    envelope(propertyOrderPlan, []).fingerprint,
  );
});

test("full context verifies large patches without obsolete segment limits", async () => {
  for (const content of [
    "x".repeat(120000),
    Array(400).fill("x".repeat(1000)).join("\n"),
  ]) {
    const file = added("large.ts", content);
    const plan = await collectFullPlan(
      fixture([file]).api,
      target,
      "standards",
    );
    assert.deepEqual(plan.issues, []);
    assert.equal(plan.batches.length, 1);
    assert.equal(plan.batches[0].files[0].head, content);
    assert.throws(
      () =>
        fileUnits(
          { ...file, path: file.filename, base: "", head: "wrong" },
          { full: true },
        ),
      /evidence mismatch/,
    );
  }
});

test("compact context retains complete head and deleted base lines with context", () => {
  const baseLines = Array.from({ length: 200 }, (_, i) => `old${i + 1}`);
  const headLines = [...baseLines];
  headLines[99] = "replacement";
  const f = {
    path: "x.ts",
    status: "modified",
    base: baseLines.join("\n"),
    head: headLines.join("\n"),
    patch: "@@ -100 +100 @@\n-old100\n+replacement",
  };
  const c = compactContext({ files: [f], surrounding: [] }).files[0];
  assert.equal(c.base.split("\n").length, 81);
  assert.match(c.base, /^60:old60/);
  assert.match(c.base, /140:old140$/);
  assert.equal(c.head.split("\n").length, 200);
  assert.match(c.head, /100:replacement/);
});

test("wide citations narrow only to unique exact evidence in the original changed range", () => {
  const head = Array.from({ length: 30 }, (_, i) => `source${i}`).join("\n");
  const f = { ...added("range.ts", head), path: "range.ts", head, base: "" };
  const finding = {
    ...answer(f),
    start: 1,
    end: 20,
    evidence: "source15\nsource16",
  };
  const valid = validateFindings(
    { status: "completed", findings: [finding] },
    { files: [f] },
  );
  assert.equal(valid.findings[0].start, 16);
  assert.equal(valid.findings[0].end, 17);
  assert.equal(finding.start, 1);
  assert.equal(
    validateFindings(
      { status: "incomplete", findings: [finding] },
      { files: [f] },
    ).status,
    "incomplete",
  );
  for (const patch of [
    { evidence: "source25" },
    { evidence: "source1" },
    { end: 200 },
    { end: 31 },
    { evidence: head },
  ])
    assert.throws(() =>
      validateFindings(
        { status: "completed", findings: [{ ...finding, ...patch }] },
        { files: [f] },
      ),
    );
  const limited = {
    ...f,
    patch: "@@ -15,2 +16,2 @@\n-source15\n-source16\n+source15\n+source16",
  };
  assert.throws(
    () =>
      validateFindings(
        { status: "completed", findings: [finding] },
        { files: [limited] },
      ),
    /outside changed/,
  );
});

test("full-context mandatory and selected supporting overflow fail before inference", async () => {
  const huge = "x".repeat(800000);
  const mandatory = fixture([
    added("a.ts", huge),
    added("b.ts", huge),
    added("c.ts", huge),
  ]);
  const supporting = fixture([added("a.ts", "changed")]);
  for (let i = 0; i < 4; i++) {
    const id = (1000 + i).toString(16).padStart(40, "0");
    supporting.responses[`/git/trees/${head}?recursive=1`].tree.push({
      path: `support${i}.ts`,
      type: "blob",
      mode: "100644",
      sha: id,
      size: huge.length,
    });
    supporting.responses[`/git/blobs/${id}`] = {
      encoding: "base64",
      content: Buffer.from(huge).toString("base64"),
      size: huge.length,
    };
  }
  for (const f of [mandatory, supporting]) {
    let calls = 0;
    const plan = await collectFullPlan(f.api, target, "standards");
    assert.ok(plan.issues.length > 0);
    const result = await reviewPlan(
      plan,
      { gptProvider: "subscription" },
      {
        reviewer: async () => {
          calls++;
          throw new Error("must not run");
        },
      },
    );
    assert.equal(calls, 0);
    assert.equal(result.summary.status, "incomplete");
  }
});

test("full-context fingerprint is stable across GitHub file and tree ordering", async () => {
  const f = fixture(),
    other = fixture();
  // Reverse the entire enumeration before repaging, not just within pages.
  const allFiles = [1, 2, 3]
    .flatMap(
      (page) => other.responses[`/pulls/1/files?per_page=100&page=${page}`],
    )
    .reverse();
  for (let page = 1; page <= 3; page++)
    other.responses[`/pulls/1/files?per_page=100&page=${page}`] =
      allFiles.slice((page - 1) * 100, page * 100);
  // Include a nonempty base tree to exercise both trees' enumeration order.
  for (const fixture of [f, other]) {
    const entries = fixture.responses[`/git/trees/${head}?recursive=1`].tree
      .slice(0, 2)
      .map((entry, index) => ({
        ...entry,
        path: `metadata/reference${index}.txt`,
      }));
    fixture.responses[`/git/trees/${base}?recursive=1`].tree =
      structuredClone(entries);
    fixture.responses[`/git/trees/${head}?recursive=1`].tree.push(...entries);
  }
  for (const ref of [base, head])
    other.responses[`/git/trees/${ref}?recursive=1`].tree.reverse();
  const a = await collectFullPlan(f.api, target, "standards");
  const b = await collectFullPlan(other.api, target, "standards");
  assert.equal(envelope(a, []).fingerprint, envelope(b, []).fingerprint);
});

test("segmented tests keep their imported implementation as priority supporting context", async () => {
  const f = fixture([
    added(
      "tests/check.mjs",
      'import { check } from "../implementation/check.mjs";\n' +
        Array(3000).fill("// padding padding padding padding").join("\n"),
    ),
  ]);
  const id = "c".repeat(40),
    content = "export function check() {}";
  f.responses[`/git/trees/${head}?recursive=1`].tree.push({
    path: "implementation/check.mjs",
    type: "blob",
    mode: "100644",
    sha: id,
    size: content.length,
  });
  f.responses[`/git/blobs/${id}`] = {
    encoding: "base64",
    content: Buffer.from(content).toString("base64"),
    size: content.length,
  };
  const plan = await collectPlan(f.api, target, "standards");
  assert.deepEqual(plan.issues, []);
  assert.ok(plan.batches.some((b) => b.files.some((f) => f.headStart > 1)));
  for (const b of plan.batches)
    assert.ok(b.surrounding.some((f) => f.path === "implementation/check.mjs"));
  const full = await collectFullPlan(f.api, target, "standards");
  assert.deepEqual(full.issues, []);
  assert.equal(full.batches.length, 1);
  assert.ok(
    full.batches[0].surrounding.some(
      (f) => f.path === "implementation/check.mjs",
    ),
  );
});

test("unsupported unchanged neighbors are disclosed while failed source reads still block full review", async () => {
  const f = fixture([added("a.ts", "changed")]);
  const tree = f.responses[`/git/trees/${head}?recursive=1`].tree;
  for (const [i, mode, size, content] of [
    [1, "120000", 4, "link"],
    [2, "100644", 1000001, ""],
    [3, "100644", 1, "AA=="],
    [4, "100644", 1, "/w=="],
  ]) {
    const id = (1000 + i).toString(16).padStart(40, "0");
    tree.push({ path: `neighbor${i}.ts`, type: "blob", mode, sha: id, size });
    if (i > 2)
      f.responses[`/git/blobs/${id}`] = { encoding: "base64", content, size };
  }
  const plan = await collectFullPlan(f.api, target, "standards");
  assert.deepEqual(plan.issues, []);
  assert.equal(plan.batches[0].scope.supportingFilesOmitted, 4);
  assert.equal(plan.batches[0].surrounding.length, 0);
  const missingId = "e".repeat(40);
  tree.push({
    path: "unavailable.ts",
    type: "blob",
    mode: "100644",
    sha: missingId,
    size: 10,
  });
  const broken = await collectFullPlan(f.api, target, "standards");
  assert.match(broken.issues.join(" "), /Cannot collect related source/);
});

test("failed full collection publishes full-context labels even without a batch", async () => {
  const f = fixture([added("a.ts", "a")]);
  f.responses["/pulls/1"].changed_files = 301;
  const plan = await collectFullPlan(f.api, target, "standards");
  assert.equal(plan.batches.length, 0);
  assert.equal(
    await publishBatches(f.api, target, envelope(plan, []), "standards"),
    false,
  );
  const comment = JSON.stringify(f.writes);
  assert.match(comment, /0\/0 full-context text reviews/);
  assert.match(comment, /extended context/);
  assert.doesNotMatch(comment, /Each batch requests/);
});

test("agent warning survives independent envelope validation and publication", async () => {
  const f = fixture([added("auth.ts", "const allowed = true;")]);
  const plan = await collectFullPlan(f.api, target, "s");
  const result = envelope(
    plan,
    plan.batches.map((b) =>
      batchResult(b, {
        ...complete(b),
        reviewAgent: "general-review",
        warnings: ["possible_prompt_injection"],
      }),
    ),
  );
  assert.equal(await publishBatches(f.api, target, result, "s"), true);
  assert.match(f.writes.at(-1).body, /possible_prompt_injection/);
  assert.match(f.writes.at(-1).body, /Repository agents/);
  assert.doesNotMatch(
    f.writes.at(-1).body,
    /requesting Claude Opus 5.5 with extended context/,
  );
});
