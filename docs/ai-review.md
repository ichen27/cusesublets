# Advisory pull request review

CuseSublets uses the same subscription reviewer as Slice Consulting, adapted from `sliceconsultingsu/slice-launcher` revision `b1b9691`. Every pull request targeting `main` gets one updated advisory comment when opened, pushed, reopened, edited or marked ready. Manual reruns are available through **Actions → Advisory AI review → Run workflow**, selecting `main` and an open PR number.

The workflow requests **Claude Opus 5.5** (`claude/claude-opus-5-5[1m]`) through the owner's existing subscription gateway. The gateway requests **High** reasoning, disables tools and automatic model switching, and has no paid API fallback. The response echoes the requested route; it does not independently attest the upstream model, reasoning setting, token usage or cost. Reviews consume the shared subscription allowance and depend on the Mac mini, tunnel, gateway and subscription sign-in.

## CI and trust boundaries

`Checks / check` runs TypeScript, web and database regression tests, production builds and reviewer tests. The iPhone feature branch also has its native simulator/API workflow. AI findings remain advisory. The review and publisher jobs now fail unless the full text review completes and publication independently validates its coverage and evidence. Missing credentials, partial input, provider failures, missing artifacts and stale commits cannot produce a successful workflow. A completed review may contain actionable findings; it does not mean those findings were fixed.

The `pull_request_target` workflow checks out only the exact trusted base commit. It never installs dependencies from, imports, builds or executes contributor code. Node's built-in APIs retrieve exact base/head source and patches as data. [Review standards](review-standards.md) and AGENTS.md come from the trusted base. Relative imports only guide context selection.

Three separate jobs queue the comment, request one full-context review, and publish their combined result. Only the middle job receives endpoint credentials and it cannot write PR comments. The publisher has no provider credentials; it independently checks the report schema, exact changed-line evidence and current base/head before updating the bot-owned comment. Findings are escaped before publication. Malformed output, missing credentials, unsupported or oversized input and stale commits are explicitly reported; they never become a clean review.

## Connection and secrets

The `ai-review` GitHub environment is restricted to the `main` branch and contains only:

- `SUBSCRIPTION_REVIEW_KEY`
- `SUBSCRIPTION_ACCESS_CLIENT_ID`
- `SUBSCRIPTION_ACCESS_CLIENT_SECRET`

These are the existing shared machine-review credentials used by Slice, scoped to `https://app-subscription-api.chenagent.com/ci/slice/review`. The historical path name is intentional. They cannot access the personal API, dashboard, saved defaults or other model routes. No master gateway key or provider login is copied to GitHub. Ordinary build jobs do not use this environment.

The credentials are shared, not independently scoped per repository. The Access token expires October 15, 2027. Rotate the secret trio in both repositories when rotating the shared connection. To disable only CuseSublets, disable its advisory workflow and remove its environment secrets; revoking the shared Access identity or review key also disables Slice. Restrict changes to this trusted workflow through normal reviewed PRs. Never expose credentials in command arguments, logs or artifacts.

## Scope and limits

The reviewer requires the PR branch to contain the current base. It enumerates up to 300 changed files through paginated GitHub API reads, checks the count and uniqueness, and rechecks base/head before and after collection. Each source blob is bounded to 1 MB; the run reads at most 12 MB of source with at most 1,000 GitHub requests. Source and patches remain data, never executable code.

All changed text is mandatory. The collector verifies every patch row against immutable base/head source, then keeps complete current changed files together in one request. Old source includes every deleted line with 40 lines of context; removed files remain complete. Compact `line:text` source strings and changed-line ranges avoid duplicating source as both JSON line objects and patches. All eligible neighboring source and shared/authentication contracts are included, rather than an eight-file sample. If mandatory or selected related source cannot fit, collection fails explicitly before inference. Cross-file context remains a finite scope, not a guarantee that every repository behavior has been understood.

The compact context is bounded to 1,980,000 UTF-8 bytes, leaving room for instructions within the gateway's 2,000,000-character / 3,000,000-byte full-review limits. This transport bound is not a token guarantee: the provider also enforces its context window, and a context overflow fails explicitly. The request sets `X-Review-Mode: full-context-v1`, selects the explicit extended-context route, and supplies the finding JSON Schema. Deploy gateway support before activating this client. The gateway uses Claude Code's constrained structured output, then this client independently checks every finding against the original diff and source. No formatting-only success or unverifiable citation is accepted.

Raster assets and binary `.ply`/`.roomcapture` samples directly under `docs/mobile/fixtures/` remain explicitly excluded from **text** review and listed for human inspection. Image-only changes, unknown binaries, sensitive files, renames, truncated patches and uncollectable source make the report incomplete and fail CI. Binary exclusions alone do not imply the text review failed.

One submission creates a gateway job, with no client inference retries or provider fallback. The client polls for up to 20 minutes using bounded 30-second HTTP requests; gateway inference is limited to 15 minutes. The workflow review job allows 30 minutes for collection, queueing, inference and artifact upload. Abandoned gateway jobs expire after two minutes without polling. The initial and final report are saved atomically, and the artifact uploads even when review fails.

The publisher independently rebuilds the full plan from trusted standards and GitHub source, matches its SHA-256 fingerprint and validates every finding's changed-line evidence and current base/head. Completed means the one planned text review completed. The reviewer is asked to consolidate duplicate root causes and return up to 40 findings; hitting that limit with additional findings must be reported incomplete. Exact duplicate evidence is also deduplicated in trusted code. The comment shows the first eight findings and the artifact contains the full report and coverage manifest, retained for 14 days. Missing or tampered results fail publication and produce a failure comment.

The workflow selects the subscription route with Jev disabled. The earlier batch collector and legacy transports remain regression-tested but are not the production collection strategy. No model/provider fallback or paid API key is introduced. Token usage and spending remain unreported by the gateway; request/time bounds are not a dollar cap.

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
