# Advisory pull request review

CuseSublets uses the same subscription reviewer as Slice Consulting, adapted from `sliceconsultingsu/slice-launcher` revision `b1b9691`. Every pull request targeting `main` gets one updated advisory comment when opened, pushed, reopened, edited or marked ready. Manual reruns are available through **Actions → Advisory AI review → Run workflow**, selecting `main` and an open PR number.

The workflow requests **Claude Opus 5.5** (`claude/claude-opus-5-5`) through the owner's existing subscription gateway. The gateway requests **High** reasoning, disables tools and automatic model switching, and has no paid API fallback. The response echoes the requested route; it does not independently attest the upstream model, reasoning setting, token usage or cost. Reviews consume the shared subscription allowance and depend on the Mac mini, tunnel, gateway and subscription sign-in.

## CI and trust boundaries

`Checks / check` runs TypeScript, web and database regression tests, production builds and reviewer tests. The iPhone feature branch also has its native simulator/API workflow. AI findings remain advisory. The review and publisher jobs now fail unless every planned text batch completes and publication independently validates its coverage and evidence. Missing credentials, partial input, provider failures, missing artifacts and stale commits cannot produce a successful workflow. A completed review may contain actionable findings; it does not mean those findings were fixed.

The `pull_request_target` workflow checks out only the exact trusted base commit. It never installs dependencies from, imports, builds or executes contributor code. Node's built-in APIs retrieve exact base/head source and patches as data. [Review standards](review-standards.md) and AGENTS.md come from the trusted base. Relative imports only guide context selection.

Three separate jobs queue the comment, request bounded reviews serially, and publish their combined result. Only the middle job receives endpoint credentials and it cannot write PR comments. The publisher has no provider credentials; it independently checks the report schema, exact changed-line evidence and current base/head before updating the bot-owned comment. Findings are escaped before publication. Malformed output, missing credentials, unsupported or oversized input and stale commits are explicitly reported; they never become a clean review.

## Connection and secrets

The `ai-review` GitHub environment is restricted to the `main` branch and contains only:

- `SUBSCRIPTION_REVIEW_KEY`
- `SUBSCRIPTION_ACCESS_CLIENT_ID`
- `SUBSCRIPTION_ACCESS_CLIENT_SECRET`

These are the existing shared machine-review credentials used by Slice, scoped to `https://app-subscription-api.chenagent.com/ci/slice/review`. The historical path name is intentional. They cannot access the personal API, dashboard, saved defaults or other model routes. No master gateway key or provider login is copied to GitHub. Ordinary build jobs do not use this environment.

The credentials are shared, not independently scoped per repository. The Access token expires October 15, 2027. Rotate the secret trio in both repositories when rotating the shared connection. To disable only CuseSublets, disable its advisory workflow and remove its environment secrets; revoking the shared Access identity or review key also disables Slice. Restrict changes to this trusted workflow through normal reviewed PRs. Never expose credentials in command arguments, logs or artifacts.

## Scope and limits

The reviewer requires the PR branch to contain the current base. It enumerates up to 300 changed files through paginated GitHub API reads, checks the count and uniqueness, and rechecks base/head before and after collection. Each source blob is bounded to 1 MB; the run reads at most 12 MB of source with at most 1,000 GitHub requests. Source and patches remain data, never executable code.

All changed text is mandatory. Large files are divided at diff hunks into source units with surrounding lines and original line numbers; oversized hunks are divided into smaller segments. Patch rows must match the exact base/head blobs and every changed line is assigned to a unit. Units are deterministically packed into at most 24 batches, at most 40 units per batch, with 200 KB of mandatory numbered context and 280 KB including supporting source. Each batch receives the changed-path inventory, trusted standards and a bounded sample of related source, including shared contracts and authorization code. Cross-batch dependencies can still require human review; file coverage does not prove semantic completeness.

Raster assets and binary `.ply`/`.roomcapture` samples directly under `docs/mobile/fixtures/` are explicitly excluded from **text** review and listed for human inspection. Image-only changes, unknown binaries, sensitive files, renames, truncated patches, oversized individual segments and uncollectable source make the report incomplete and fail CI. Exclusions are shown even when all text batches complete.

One submission per batch creates a gateway job, with no inference retries or provider fallback. Batches run serially to respect the shared provider slot. Each permits up to eight minutes of polling, bounded 30-second HTTP requests and 300 seconds of gateway inference. The run stops starting batches after 60 minutes or if base/head changes; the job has a 75-minute timeout. A provider outage stops further submissions, leaving unattempted batches explicitly missing. Completed batches are saved atomically after each response, and the artifact is uploaded even when the review step fails. Abandoned gateway jobs expire after two minutes without polling. No gateway change or extra queue concurrency is required.

The publisher independently rebuilds the exact plan from trusted standards and GitHub source, matches its SHA-256 fingerprint, and validates every batch's findings against its own changed lines. The aggregate succeeds only when all planned text batches complete. Findings are combined, deduplicated by location/evidence and sorted by severity; duplicate evidence retains the higher severity. The comment shows the first eight with a count of the remainder. The bounded `report.json` artifact contains every finding, per-batch status and coverage summary, retained for 14 days. Missing or tampered results fail publication and produce a failure comment. A green result never conceals an incomplete batch.

The deployed workflow always selects the subscription route with Jev disabled. Legacy single-review transports remain tested for compatibility, but cannot be selected for batch execution. Token usage and spending are unreported by the subscription gateway; the batch count/time bounds limit requests rather than asserting a dollar cap.

## Review and fix loop

Read the comment's status and exact base/head. Assess findings against source and intended behavior, fix supported issues, run applicable checks and push to the same PR. Read the fresh review; repeat for up to two useful fix/review rounds. Record unresolved findings and unavailable/incomplete coverage. Do not rerun unchanged code merely to obtain a favorable result. Human inspection of excluded assets and normal merge requirements remain necessary.

## Validate and bootstrap

```sh
npm run test:reviewer
```

The reviewer tests require Node 22 and no dependencies or credentials. They include an actual CLI subprocess regression proving that incomplete review saves an artifact and both review/publish exit nonzero, plus paginated 106-file coverage, split-file coordinates, tampered aggregates, provider failure and partial results. They exercise hostile text, evidence validation, source bounds, stale commits, credential absence, queued jobs, response failures and native supporting context. The normal Checks workflow runs them before installing application dependencies.

Installing `pull_request_target` on a feature branch alone cannot activate it: merge the reviewed CI setup into `main`, provision the restricted environment, then run a small open PR through the hosted workflow. Verify the published current-commit status, not just a green Actions job. Keep the mobile release PR separate. Code sync does not deploy the marketplace or apply migrations.

## Repository enforcement

The `main` branch requires a pull request, a passing current `check`, and resolved review conversations. Force pushes and branch deletion are blocked, including for administrators. AI review is advisory and is not a required status check. The `ai-review` environment permits only branch `main` and contains the three narrow endpoint credentials listed above. The installation was merged separately from the iPhone feature so it does not release mobile code or run database migrations.

Output validation accepts plain JSON or exactly one enclosing JSON fence and checks each finding separately against changed source. A completed response that fails output validation may trigger one fresh review, with sanitized feedback and the unchanged original source. Both attempts share the existing eight-minute batch deadline; a retry starts only with at least three minutes remaining. Transport, wrong-model, refusal and truncated-response failures never trigger retries. Failed or incomplete repairs retain validated partial findings; a fully valid completed replacement is authoritative and can withdraw earlier claims. Unresolved validation or partial-result overflow remains unsuccessful. No raw invalid output is published.
