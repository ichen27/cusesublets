# Advisory pull request review

CuseSublets uses the same subscription reviewer as Slice Consulting, adapted from `sliceconsultingsu/slice-launcher` revision `b1b9691`. Every pull request targeting `main` gets one updated advisory comment when opened, pushed, reopened, edited or marked ready. Manual reruns are available through **Actions → Advisory AI review → Run workflow**, selecting `main` and an open PR number.

The workflow requests **Claude Opus 5.5** (`claude/claude-opus-5-5`) through the owner's existing subscription gateway. The gateway requests **High** reasoning, disables tools and automatic model switching, and has no paid API fallback. The response echoes the requested route; it does not independently attest the upstream model, reasoning setting, token usage or cost. Reviews consume the shared subscription allowance and depend on the Mac mini, tunnel, gateway and subscription sign-in.

## CI and trust boundaries

`Checks / check` runs TypeScript, web and database regression tests, production builds and reviewer tests. The iPhone feature branch also has its native simulator/API workflow. AI advice remains advisory; a successful workflow means the report was handled, not necessarily that a review completed.

The `pull_request_target` workflow checks out only the exact trusted base commit. It never installs dependencies from, imports, builds or executes contributor code. Node's built-in APIs retrieve exact base/head source and patches as data. [Review standards](review-standards.md) and AGENTS.md come from the trusted base. Relative imports only guide context selection.

Three separate jobs queue the comment, request the review, and publish the validated result. Only the middle job receives endpoint credentials and it cannot write PR comments. The publisher has no provider credentials; it independently checks the report schema, exact changed-line evidence and current base/head before updating the bot-owned comment. Findings are escaped before publication. Malformed output, missing credentials, unsupported or oversized input and stale commits are explicitly reported; they never become a clean review.

## Connection and secrets

The `ai-review` GitHub environment is restricted to the `main` branch and contains only:

- `SUBSCRIPTION_REVIEW_KEY`
- `SUBSCRIPTION_ACCESS_CLIENT_ID`
- `SUBSCRIPTION_ACCESS_CLIENT_SECRET`

These are the existing shared machine-review credentials used by Slice, scoped to `https://app-subscription-api.chenagent.com/ci/slice/review`. The historical path name is intentional. They cannot access the personal API, dashboard, saved defaults or other model routes. No master gateway key or provider login is copied to GitHub. Ordinary build jobs do not use this environment.

The credentials are shared, not independently scoped per repository. The Access token expires October 15, 2027. Rotate the secret trio in both repositories when rotating the shared connection. To disable only CuseSublets, disable its advisory workflow and remove its environment secrets; revoking the shared Access identity or review key also disables Slice. Restrict changes to this trusted workflow through normal reviewed PRs. Never expose credentials in command arguments, logs or artifacts.

## Scope and limits

The reviewer requires the PR branch to contain the current base. Merge `main` into a stale branch and rerun. Reviews cover at most 40 changed files, 80 fetched source blobs and 370,000 bytes of numbered context; supporting context usually stops at 175,000 bytes. Swift, native project metadata, Python, SQL and web source can participate. Full changed text and complete patches are required. Raster images are disclosed for human inspection; renames, other unsupported binaries, oversized source, truncated patches and changes beyond the limits produce an incomplete result without calling the model. Large migrations need smaller reviewable PRs or separate human review; an incomplete report is not approval.

One submission creates a serial gateway job, with up to four jobs waiting. Status polling does not repeat inference. The gateway allows 300 seconds of inference; the client polls for at most eight minutes, bounds each HTTP request to 30 seconds and does not retry inference. Abandoned jobs expire after two minutes without polling. Responses, comments, findings and GitHub reads are bounded. Legacy compatibility transports remain unit-tested in the adapter, but this workflow always selects subscription with Jev disabled and has no fallback credentials.

## Review and fix loop

Read the comment's status and exact base/head. Assess findings against source and intended behavior, fix supported issues, run applicable checks and push to the same PR. Read the fresh review; repeat for up to two useful fix/review rounds. Record unresolved findings and unavailable/incomplete coverage. Do not rerun unchanged code merely to obtain a favorable result. Human inspection of excluded assets and normal merge requirements remain necessary.

## Validate and bootstrap

```sh
npm run test:reviewer
```

The reviewer tests require Node 22 and no dependencies or credentials. They exercise hostile text, evidence validation, source bounds, stale commits, credential absence, queued jobs, response failures and native supporting context. The normal Checks workflow runs them before installing application dependencies.

Installing `pull_request_target` on a feature branch alone cannot activate it: merge the reviewed CI setup into `main`, provision the restricted environment, then run a small open PR through the hosted workflow. Verify the published current-commit status, not just a green Actions job. Keep the mobile release PR separate. Code sync does not deploy the marketplace or apply migrations.
