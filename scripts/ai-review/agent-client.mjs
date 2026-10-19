import { performance } from "node:perf_hooks";

export const AGENT_ENDPOINT =
  "https://app-subscription-api.chenagent.com/ci/review";
export const AGENT_LIMITS = Object.freeze({
  characters: 400000,
  bodyBytes: 640000,
  waitMs: 1500000,
  requestTimeoutMs: 30000,
  pollIntervalMs: 10000,
});
const agentName = (value) =>
  typeof value === "string" && /^[a-z0-9-]{1,40}$/.test(value);
const commit = (value) =>
  typeof value === "string" && /^[a-f0-9]{40}$/.test(value);
const jobId = (value) =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);

export function agentConfig(env) {
  const route = env.SUBSCRIPTION_REVIEW_ROUTE || "legacy";
  if (!["legacy", "agent-v1"].includes(route))
    throw new Error("Unknown subscription review route");
  if (route === "legacy") return {};
  const reviewAgent = env.REVIEW_AGENT || "general-review";
  const reviewRepository = env.GITHUB_REPOSITORY;
  if (
    !agentName(reviewAgent) ||
    typeof reviewRepository !== "string" ||
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(reviewRepository)
  )
    throw new Error("Invalid review agent configuration");
  return {
    reviewAgent,
    reviewRepository,
    gptKey: env.SUBSCRIPTION_AGENT_KEY || "",
  };
}

export function agentBody(body, cfg, context) {
  if (
    !commit(context.head) ||
    !commit(context.base) ||
    (context.repository && context.repository !== cfg.reviewRepository)
  )
    throw new Error("Invalid review revisions");
  return {
    agent: cfg.reviewAgent,
    repository: cfg.reviewRepository,
    commit: context.head,
    base: context.base,
    messages: body.messages,
    response_format: body.response_format || {
      type: "json_schema",
      json_schema: { name: "review", schema: body.json_schema },
    },
  };
}

export function validateAgentMetadata(report) {
  if (report.reviewAgent === undefined && report.warnings === undefined) return;
  if (
    !agentName(report.reviewAgent) ||
    !Array.isArray(report.warnings) ||
    report.warnings.length > 1 ||
    report.warnings.some((value) => value !== "possible_prompt_injection")
  )
    throw new Error("Invalid review agent metadata");
}

// A project job is asynchronous only. Never follow a returned Location with credentials.
// Completion here is delivery; the caller still validates schema, completeness and citations.
export async function requestAgentJob(
  body,
  headers,
  deadline,
  fetcher,
  wait,
  boundedJson,
) {
  const signal = () => {
    const remaining = Math.floor(deadline - performance.now());
    if (remaining <= 0) throw new Error("Review deadline expired");
    return AbortSignal.timeout(
      Math.min(AGENT_LIMITS.requestTimeoutMs, remaining),
    );
  };
  const submitted = await fetcher(AGENT_ENDPOINT, {
    method: "POST",
    redirect: "error",
    signal: signal(),
    headers: {
      ...headers,
      "Content-Type": "application/json",
      Prefer: "respond-async",
    },
    body: JSON.stringify(body),
  });
  if (submitted.status !== 202)
    throw new Error("Expected an asynchronous review job");
  let job = await boundedJson(submitted);
  const id = job.id;
  if (
    !jobId(id) ||
    job.agent !== body.agent ||
    !["queued", "running"].includes(job.status)
  )
    throw new Error("Invalid review job");
  const maxPolls = Math.floor(
    AGENT_LIMITS.waitMs / AGENT_LIMITS.pollIntervalMs,
  );
  for (let polls = 0; ["queued", "running"].includes(job.status); polls++) {
    if (
      polls >= maxPolls ||
      performance.now() + AGENT_LIMITS.pollIntervalMs >= deadline
    )
      throw new Error("Review deadline expired");
    await wait(AGENT_LIMITS.pollIntervalMs);
    job = await boundedJson(
      await fetcher(AGENT_ENDPOINT + "?job=" + id, {
        method: "GET",
        redirect: "error",
        signal: signal(),
        headers,
      }),
    );
    if (job.id !== id || job.agent !== body.agent)
      throw new Error("Mismatched review job");
  }
  if (
    performance.now() >= deadline ||
    job.status !== "completed" ||
    !job.result ||
    job.provenance?.commit !== body.commit ||
    job.provenance?.base !== body.base
  )
    throw new Error("Review job did not complete for the pinned revisions");
  if (
    typeof job.result.model !== "string" ||
    job.result.model.length > 107 ||
    !/^claude\/[A-Za-z0-9][A-Za-z0-9._-]*(?:\[1m\])?$/.test(job.result.model)
  )
    throw new Error("Invalid review model metadata");
  const metadata = { reviewAgent: body.agent, warnings: job.warnings ?? [] };
  validateAgentMetadata(metadata);
  return { completion: job.result, warnings: metadata.warnings };
}
