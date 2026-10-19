import { performance } from "node:perf_hooks";
import assert from "node:assert/strict";
import test from "node:test";
import { review, configFromEnv, renderComment } from "./ai-review/core.mjs";
import { validateReport } from "./ai-review/github.mjs";
const context = {
  base: "a".repeat(40),
  head: "b".repeat(40),
  complete: true,
  omissions: [],
  checks: [],
  surrounding: [],
  standards: "Check permissions.",
  files: [
    {
      path: "auth.ts",
      status: "modified",
      patch:
        "@@ -1 +1 @@\n-const allowed = member.active;\n+const allowed = true;",
      base: "const allowed = member.active;",
      head: "const allowed = true;",
    },
  ],
};
const env = {
  GPT_PROVIDER: "subscription",
  SUBSCRIPTION_REVIEW_ROUTE: "agent-v1",
  REVIEW_AGENT: "general-review",
  GITHUB_REPOSITORY: "example/project",
  SUBSCRIPTION_AGENT_KEY: "project-key",
  SUBSCRIPTION_REVIEW_KEY: "legacy-key",
  SUBSCRIPTION_ACCESS_CLIENT_ID: "access-id",
  SUBSCRIPTION_ACCESS_CLIENT_SECRET: "access-secret",
};
const id = "0f8fad5b-d9cb-469f-a165-70867728950e";
const finding = {
  path: "auth.ts",
  side: "RIGHT",
  start: 1,
  end: 1,
  severity: "high",
  title: "Check membership",
  explanation: "Inactive members receive access.",
  evidence: "const allowed = true;",
};
const completion = (value = { status: "completed", findings: [finding] }) => ({
  object: "chat.completion",
  model: "claude/sonnet",
  choices: [
    {
      index: 0,
      message: { role: "assistant", content: JSON.stringify(value) },
      finish_reason: "stop",
    },
  ],
});
const job = (result = completion()) => ({
  id,
  status: "completed",
  agent: "general-review",
  result,
  provenance: {
    commit: context.head,
    base: context.base,
    configRevision: 1,
    image: "sha256:" + "c".repeat(64),
    cliVersion: "2.1.301",
    agentDigest: "d".repeat(64),
    skills: [],
  },
  usage: { durationMs: 12, toolSteps: 2, effort: "high" },
  warnings: ["possible_prompt_injection"],
});
const response = (value, status = 200) =>
  new Response(JSON.stringify(value), { status });
function gateway(result = job(), requests = []) {
  return async (url, options) => {
    requests.push({ url, ...options });
    return options.method === "POST"
      ? response({ id, status: "queued", agent: "general-review" }, 202)
      : response(result);
  };
}

test("agent route pins repository revisions, uses project key and publishes a safe warning", async () => {
  const requests = [];
  const report = await review(
    context,
    configFromEnv(env),
    gateway(job(), requests),
    async () => {},
  );
  assert.equal(report.status, "completed");
  assert.equal(report.gpt.model, "claude/sonnet");
  assert.equal(report.reviewAgent, "general-review");
  assert.deepEqual(report.warnings, ["possible_prompt_injection"]);
  validateReport(report);
  const request = requests[0];
  assert.equal(
    request.url,
    "https://app-subscription-api.chenagent.com/ci/review",
  );
  assert.equal(request.headers.Authorization, "Bearer project-key");
  assert.equal(request.headers["X-Review-Mode"], undefined);
  const body = JSON.parse(request.body);
  assert.deepEqual(Object.keys(body).sort(), [
    "agent",
    "base",
    "commit",
    "messages",
    "repository",
    "response_format",
  ]);
  assert.equal(body.commit, context.head);
  assert.equal(body.base, context.base);
  assert.equal(body.repository, "example/project");
  assert.equal(body.agent, "general-review");
  assert.equal(body.response_format.type, "json_schema");
  assert.doesNotMatch(body.messages[0].content, /You have no tools/);
  assert.equal(requests[1].url, request.url + "?job=" + id);
  assert.equal(requests[1].redirect, "error");
  assert.match(
    renderComment(report, context.head, "example/project"),
    /possible_prompt_injection/,
  );
});
test("agent mode never reuses the legacy key and rejects unknown route or malformed configuration", async () => {
  let calls = 0;
  const report = await review(
    context,
    configFromEnv({ ...env, SUBSCRIPTION_AGENT_KEY: "" }),
    async () => {
      calls++;
      throw Error("must not call");
    },
  );
  assert.equal(report.status, "unavailable");
  assert.equal(calls, 0);
  for (const bad of [
    { SUBSCRIPTION_REVIEW_ROUTE: "typo" },
    { REVIEW_AGENT: "../bad" },
    { GITHUB_REPOSITORY: "https://evil.example/repo" },
  ])
    assert.throws(() => configFromEnv({ ...env, ...bad }));
});
test("agent jobs reject failed, mismatched, unpinned and unknown-warning replies without resubmission", async () => {
  for (const change of [
    { status: "failed" },
    { agent: "other" },
    { id: "12345678-1234-1234-1234-123456789012" },
    { provenance: { commit: "c".repeat(40), base: context.base } },
    { warnings: ["raw untrusted text"] },
  ]) {
    const requests = [];
    const report = await review(
      context,
      configFromEnv(env),
      gateway({ ...job(), ...change }, requests),
      async () => {},
    );
    assert.notEqual(report.status, "completed");
    assert.equal(requests.filter((r) => r.method === "POST").length, 1);
    assert.doesNotMatch(JSON.stringify(report), /raw untrusted text/);
  }
  const requests = [];
  const report = await review(
    context,
    configFromEnv(env),
    async (url, options) => {
      requests.push(options);
      return response(completion());
    },
    async () => {},
  );
  assert.notEqual(report.status, "completed");
  assert.equal(requests.length, 1);
});
test("agent transport retains completion and citation validation plus one output-only retry", async () => {
  for (const output of [
    { status: "incomplete", findings: [finding] },
    {
      status: "completed",
      findings: [finding, { ...finding, evidence: "invented evidence" }],
    },
  ]) {
    const requests = [];
    const report = await review(
      context,
      configFromEnv(env),
      gateway(job(completion(output)), requests),
      async () => {},
    );
    assert.equal(report.status, "incomplete");
    assert.equal(
      requests.filter((r) => r.method === "POST").length,
      output.status === "incomplete" ? 1 : 2,
    );
    validateReport(report);
  }
  let posts = 0;
  const report = await review(
    context,
    configFromEnv(env),
    async (url, options) => {
      if (options.method === "POST") {
        posts++;
        return response({ id, status: "queued", agent: "general-review" }, 202);
      }
      return response(
        job(
          completion(
            posts === 1
              ? {
                  status: "completed",
                  findings: [
                    finding,
                    { ...finding, evidence: "invented evidence" },
                  ],
                }
              : undefined,
          ),
        ),
      );
    },
    async () => {},
  );
  assert.equal(report.status, "completed");
  assert.equal(posts, 2);
});

test("agent mode keeps the smaller gateway bound even for full-context collection", async () => {
  let calls = 0;
  const report = await review(
    {
      ...context,
      reviewMode: "full-context-v1",
      files: [{ ...context.files[0], head: "x".repeat(410000) }],
    },
    configFromEnv(env),
    async () => {
      calls++;
      throw Error("must not call");
    },
  );
  assert.equal(report.status, "incomplete");
  assert.equal(calls, 0);
  assert.match(report.reason, /input limit/);
});

test("gateway-valid model names survive delivery and independent report validation", async () => {
  for (const model of [
    "claude/Opus_Custom",
    "claude/" + "x".repeat(96) + "[1m]",
  ]) {
    const report = await review(
      context,
      configFromEnv(env),
      gateway(job({ ...completion(), model })),
      async () => {},
    );
    assert.equal(report.status, "completed");
    assert.equal(report.gpt.model, model);
    validateReport(report);
  }
  for (const model of [
    "claude/" + "x".repeat(101),
    "claude/evil\ncontent",
    "other/opus",
  ]) {
    const report = await review(
      context,
      configFromEnv(env),
      gateway(job({ ...completion(), model })),
      async () => {},
    );
    assert.notEqual(report.status, "completed");
  }
});
test("agent deadline includes polling and stops without another submission", async (t) => {
  let now = 0,
    calls = 0;
  t.mock.method(performance, "now", () => now);
  const report = await review(
    context,
    configFromEnv(env),
    async () => {
      calls++;
      return response({ id, status: "queued", agent: "general-review" }, 202);
    },
    async () => {
      now = 1500001;
    },
  );
  assert.equal(report.status, "failed");
  assert.equal(calls, 1);
});
