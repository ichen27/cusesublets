import assert from "node:assert/strict";
import test from "node:test";
import {
  review,
  validateFindings,
  configFromEnv,
  SUBSCRIPTION_LIMITS,
  OUTPUT_SCHEMA,
} from "./ai-review/core.mjs";
import { validateReport } from "./ai-review/github.mjs";
const maxFindings = OUTPUT_SCHEMA.properties.findings.maxItems;
const base = "a".repeat(40),
  head = "b".repeat(40);
const context = {
  base,
  head,
  complete: true,
  omissions: [],
  checks: [],
  surrounding: [],
  standards: "Permissions must be checked.",
  files: [
    {
      path: "auth.ts",
      status: "modified",
      patch:
        "@@ -1,2 +1,2 @@\n-const allowed = member.active;\n+const allowed = true;\n return allowed;",
      base: "const allowed = member.active;\nreturn allowed;\n",
      head: "const allowed = true;\nreturn allowed;\n",
    },
  ],
};
const finding = {
  path: "auth.ts",
  side: "RIGHT",
  start: 1,
  end: 1,
  severity: "high",
  title: "Reject suspended members",
  explanation: "The unconditional value allows suspended members to enter.",
  evidence: "const allowed = true;",
};
const output = { status: "completed", findings: [finding] };
const subscriptionCfg = configFromEnv({
  GPT_PROVIDER: "subscription",
  SUBSCRIPTION_REVIEW_KEY: "synthetic",
  SUBSCRIPTION_ACCESS_CLIENT_ID: "synthetic",
  SUBSCRIPTION_ACCESS_CLIENT_SECRET: "synthetic",
});
const subscriptionResponse = (value = output) => ({
  model: subscriptionCfg.gptModel,
  object: "chat.completion",
  choices: [
    {
      message: { role: "assistant", content: JSON.stringify(value) },
      finish_reason: "stop",
    },
  ],
});
const response = (value) => new Response(JSON.stringify(value));
const jobId = "0f8fad5b-d9cb-469f-a165-70867728950e";
const jobResponse = (value) =>
  new Response(JSON.stringify(value), { status: 202 });
test("subscription accepts one enclosing JSON fence and retries malformed text only once", async () => {
  for (const wrap of [
    (s) => s,
    (s) => "```json\n" + s + "\n```",
    (s) => "```\r\n" + s + "\r\n```",
  ]) {
    let calls = 0;
    const result = await review(context, subscriptionCfg, async () => {
      calls++;
      const raw = subscriptionResponse();
      raw.choices[0].message.content = wrap(JSON.stringify(output));
      return response(raw);
    });
    assert.equal(result.status, "completed");
    assert.equal(calls, 1);
  }
  for (const content of [
    "prose\n" + JSON.stringify(output),
    "```json\n```json\n" + JSON.stringify(output) + "\n```\n```",
    JSON.stringify(output) + JSON.stringify(output),
  ]) {
    let calls = 0;
    const result = await review(context, subscriptionCfg, async () => {
      calls++;
      const raw = subscriptionResponse();
      raw.choices[0].message.content = content;
      return response(raw);
    });
    assert.equal(result.status, "failed");
    assert.equal(calls, 2);
    assert.doesNotMatch(JSON.stringify(result), /prose/);
  }
});

const leftFinding = {
  ...finding,
  side: "LEFT",
  evidence: "const allowed = member.active;",
};
const badFinding = { ...finding, evidence: "untrusted-invalid-evidence" };

test("completed repair replaces the earlier assessment and sends only sanitized feedback", async () => {
  const bodies = [];
  const result = await review(
    context,
    subscriptionCfg,
    async (_url, options) => {
      bodies.push(JSON.parse(options.body));
      return response(
        subscriptionResponse({
          status: "completed",
          findings: bodies.length === 1 ? [finding, badFinding] : [leftFinding],
        }),
      );
    },
  );
  assert.equal(result.status, "completed");
  assert.deepEqual(result.findings, [leftFinding]);
  assert.equal(bodies.length, 2);
  assert.equal(
    bodies[0].messages[1].content,
    bodies[1].messages.at(-1).content,
  );
  assert.match(bodies[1].messages[1].content, /evidence_mismatch/);
  for (const body of bodies) {
    assert.equal(body.messages.at(-1).role, "user");
    assert.ok(body.messages.at(-1).content.trim());
  }
  assert.doesNotMatch(JSON.stringify(bodies[1]), /untrusted-invalid-evidence/);
  validateReport(result);
});

test("a bad finding cannot discard valid findings or turn unresolved review green", async () => {
  for (const second of [
    subscriptionResponse({
      status: "completed",
      findings: [leftFinding, badFinding],
    }),
    { ...subscriptionResponse(), choices: [] },
    subscriptionResponse({ status: "incomplete", findings: [leftFinding] }),
    null,
  ]) {
    let calls = 0;
    const result = await review(context, subscriptionCfg, async () => {
      calls++;
      if (calls === 1)
        return response(
          subscriptionResponse({
            status: "completed",
            findings: [finding, badFinding],
          }),
        );
      if (second === null) throw new Error("private transport detail");
      return response(second);
    });
    assert.equal(calls, 2);
    assert.equal(result.status, "incomplete");
    assert.equal(result.gpt.status, "incomplete");
    assert.deepEqual(result.findings[0], finding);
    assert.doesNotMatch(
      JSON.stringify(result),
      /untrusted-invalid-evidence|private transport detail/,
    );
    validateReport(result);
    validateFindings(
      { status: result.status, findings: result.findings },
      context,
    );
  }
});

test("format repair can recover but completed envelopes, refusals and wrong routes do not retry", async () => {
  let calls = 0;
  const repaired = await review(context, subscriptionCfg, async () => {
    calls++;
    const raw = subscriptionResponse();
    if (calls === 1) raw.choices[0].message.content = "invalid JSON";
    return response(raw);
  });
  assert.equal(repaired.status, "completed");
  assert.equal(calls, 2);
  const refusal = subscriptionResponse();
  refusal.choices[0].message.refusal = "private refusal";
  for (const raw of [
    refusal,
    { ...subscriptionResponse(), model: "wrong" },
    subscriptionResponse({ status: "incomplete", findings: [finding] }),
  ]) {
    calls = 0;
    const result = await review(context, subscriptionCfg, async () => {
      calls++;
      return response(raw);
    });
    assert.equal(calls, 1);
    assert.notEqual(result.status, "completed");
  }
});

test("union overflow is explicit and exact duplicates retain the higher severity", async () => {
  const longFinding = { ...finding, evidence: "x".repeat(100) };
  const longContext = {
    ...context,
    files: [
      {
        ...context.files[0],
        patch: "@@ -1 +1 @@\n-old\n+" + longFinding.evidence,
        base: "old",
        head: longFinding.evidence,
      },
    ],
  };
  let calls = 0;
  const result = await review(longContext, subscriptionCfg, async () => {
    calls++;
    const findings = Array.from(
      { length: calls === 1 ? maxFindings - 1 : 2 },
      (_, i) => ({
        ...longFinding,
        evidence: "x".repeat(i + (calls === 1 ? 1 : maxFindings)),
      }),
    );
    if (calls === 1) findings.push(badFinding);
    return response(subscriptionResponse({ status: "incomplete", findings }));
  });
  assert.equal(result.status, "incomplete");
  assert.equal(result.findings.length, maxFindings);
  assert.match(
    result.reason,
    new RegExp(`exceed the ${maxFindings}-finding limit`),
  );
  calls = 0;
  const deduped = await review(context, subscriptionCfg, async () =>
    response(
      subscriptionResponse({
        status: "completed",
        findings:
          ++calls === 1
            ? [finding, badFinding]
            : [{ ...finding, severity: "critical" }],
      }),
    ),
  );
  assert.equal(deduped.status, "completed");
  assert.equal(deduped.findings.length, 1);
  assert.equal(deduped.findings[0].severity, "critical");
});

test("repair and async polling share a deadline and late validation cannot start another job", async (t) => {
  const { performance } = await import("node:perf_hooks");
  let now = 0;
  t.mock.method(performance, "now", () => now);
  let posts = 0;
  const result = await review(
    context,
    subscriptionCfg,
    async (_url, options) => {
      if (options.method === "POST") {
        posts++;
        if (posts === 1) {
          now = SUBSCRIPTION_LIMITS.waitMs - 200000;
          return response(
            subscriptionResponse({
              status: "completed",
              findings: [finding, badFinding],
            }),
          );
        }
        return jobResponse({ id: jobId, status: "queued" });
      }
      return response({ id: jobId, status: "running" });
    },
    async (ms) => {
      now += ms;
    },
  );
  assert.equal(posts, 2);
  assert.equal(result.status, "incomplete");
  assert.deepEqual(result.findings, [finding]);
  assert.ok(now < SUBSCRIPTION_LIMITS.waitMs);
  now = 0;
  posts = 0;
  const late = await review(context, subscriptionCfg, async () => {
    posts++;
    now = SUBSCRIPTION_LIMITS.waitMs - 100000;
    return response(
      subscriptionResponse({
        status: "completed",
        findings: [finding, badFinding],
      }),
    );
  });
  assert.equal(posts, 1);
  assert.equal(late.status, "incomplete");
});

test("input rejection discloses no provider call and repair overflow retains the original failure", async () => {
  let baseBytes = 0;
  await review(
    { ...context, standards: "" },
    subscriptionCfg,
    async (_url, options) => {
      baseBytes = Buffer.byteLength(options.body);
      return response(subscriptionResponse());
    },
  );
  const nearLimit = Math.floor(
    (SUBSCRIPTION_LIMITS.bodyBytes - baseBytes - 100) / 4,
  );
  let calls = 0;
  const fetcher = async () => {
    calls++;
    return response(
      subscriptionResponse({
        status: "completed",
        findings: [finding, badFinding],
      }),
    );
  };
  const blocked = await review(
    { ...context, standards: "\\".repeat(nearLimit + 100) },
    subscriptionCfg,
    fetcher,
  );
  assert.equal(calls, 0);
  assert.equal(blocked.status, "incomplete");
  assert.equal(blocked.gpt.status, "unavailable");
  assert.match(blocked.reason, /no provider called/);
  const partial = await review(
    { ...context, standards: "\\".repeat(nearLimit) },
    subscriptionCfg,
    fetcher,
  );
  assert.equal(calls, 1);
  assert.equal(partial.status, "incomplete");
  assert.deepEqual(partial.findings, [finding]);
  assert.match(partial.reason, /evidence_mismatch; repair_input_limit/);
});
