import { loadStandards } from "./standards.mjs";
import process from "node:process";
import console from "node:console";
import {
  readFile,
  writeFile,
  mkdir,
  appendFile,
  rename,
} from "node:fs/promises";
import {
  BATCH_LIMITS,
  collectPlan,
  reviewPlan,
  publishBatches,
  envelope,
} from "./batches.mjs";
import { configFromEnv, emptyReport } from "./core.mjs";
import {
  githubApi,
  currentMatches,
  publish,
  validateReport,
  validateTarget,
} from "./github.mjs";

const mode = process.argv[2];
const event = JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, "utf8"));
const repository = process.env.GITHUB_REPOSITORY;
const api = githubApi(repository, process.env.GITHUB_TOKEN);
let target;
if (process.env.TARGET_BASE && mode !== "pending") {
  target = {
    pr: Number(process.env.TARGET_PR),
    base: process.env.TARGET_BASE,
    head: process.env.TARGET_HEAD,
    repository,
  };
} else if (event.pull_request) {
  target = {
    pr: Number(event.number),
    base: event.pull_request.base.sha,
    head: event.pull_request.head.sha,
    repository,
  };
} else {
  if (process.env.GITHUB_REF !== "refs/heads/main")
    throw new Error("Manual reviews must run protected main");
  const pr = Number(event.inputs?.pr);
  if (!Number.isSafeInteger(pr) || pr < 1) throw new Error("Invalid PR number");
  const current = await api("/pulls/" + pr);
  target = { pr, base: current.base.sha, head: current.head.sha, repository };
}
validateTarget(target);
async function saveReport(report) {
  const data = JSON.stringify(report);
  if (Buffer.byteLength(data) > BATCH_LIMITS.artifactBytes)
    throw new Error("Report artifact exceeds bound");
  await mkdir("ai-review-output", { recursive: true });
  await writeFile("ai-review-output/report.tmp", data);
  await rename("ai-review-output/report.tmp", "ai-review-output/report.json");
}
if (mode === "pending") {
  if (process.env.GITHUB_OUTPUT)
    await appendFile(
      process.env.GITHUB_OUTPUT,
      "base=" +
        target.base +
        "\nhead=" +
        target.head +
        "\npr=" +
        target.pr +
        "\n",
    );
  await publish(
    api,
    target,
    emptyReport(
      target,
      "pending",
      "Review queued for this head; all earlier findings are stale.",
    ),
  );
} else if (mode === "review") {
  let report, plan;
  try {
    const standards = await loadStandards();
    plan = await collectPlan(api, target, standards);
    report = envelope(plan, []);
    await saveReport(report);
    report = await reviewPlan(plan, configFromEnv(process.env), {
      isCurrent: async () =>
        currentMatches(await api("/pulls/" + target.pr), target),
      onBatch: async (index, status, partial) => {
        report = partial;
        await saveReport(partial);
        console.log(`Batch ${index}: ${status}`);
      },
    });
  } catch {
    report =
      report?.version === 2
        ? envelope(plan, report.results, true)
        : emptyReport(
            target,
            "failed",
            "Trusted source collection or configuration failed; no review result available.",
          );
  }
  if (report.version === 1) validateReport(report);
  await saveReport(report);
  // Deliberately never print provider errors, bodies, source code, secrets or findings to logs.
  const status = report.version === 2 ? report.summary.status : report.status;
  console.log("Advisory review status: " + status);
  if (status !== "completed") process.exitCode = 1;
} else if (mode === "publish") {
  let report;
  try {
    const data = await readFile("ai-review-output/report.json");
    if (data.byteLength > BATCH_LIMITS.artifactBytes)
      throw new Error("Oversized report");
    report = JSON.parse(data.toString("utf8"));
    if (report.version !== 2) {
      validateReport(report);
      if (report.status === "completed")
        throw new Error("Successful publication requires batch coverage");
    }
  } catch {
    report = emptyReport(
      target,
      "failed",
      "Review job or report artifact unavailable; no findings available.",
    );
  }
  let completed = false;
  try {
    if (report.version === 2)
      completed = await publishBatches(
        api,
        target,
        report,
        await loadStandards(),
      );
    else await publish(api, target, report);
  } catch {
    await publish(
      api,
      target,
      emptyReport(
        target,
        "failed",
        "Report coverage or source revalidation failed; review is not complete.",
      ),
    );
  }
  if (!completed) process.exitCode = 1;
} else throw new Error("Expected pending, review or publish mode");
