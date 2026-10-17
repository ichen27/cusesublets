import { loadStandards } from "./standards.mjs";
import process from "node:process";
import console from "node:console";
import { readFile, writeFile, mkdir, appendFile } from "node:fs/promises";
import { configFromEnv, emptyReport, review } from "./core.mjs";
import {
  collectContext,
  githubApi,
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
  let report;
  try {
    const standards = await loadStandards();
    const context = await collectContext(api, target, standards);
    report = await review(context, configFromEnv(process.env));
  } catch {
    report = emptyReport(
      target,
      "failed",
      "Trusted source collection or configuration failed; no review result available.",
    );
  }
  validateReport(report);
  await mkdir("ai-review-output", { recursive: true });
  await writeFile("ai-review-output/report.json", JSON.stringify(report));
  // Deliberately never print provider errors, bodies, source code, secrets or findings to logs.
  console.log("Advisory review status: " + report.status);
} else if (mode === "publish") {
  let report;
  try {
    const data = await readFile("ai-review-output/report.json");
    if (data.byteLength > 20000) throw new Error("Oversized report");
    report = validateReport(JSON.parse(data.toString("utf8")));
  } catch {
    report = emptyReport(
      target,
      "failed",
      "Review job or report artifact unavailable; no findings available.",
    );
  }
  await publish(api, target, report);
} else throw new Error("Expected pending, review or publish mode");
