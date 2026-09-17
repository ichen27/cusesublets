# Backend review — 2026-09-16

Reviewed commit f7ddc3e on feat/initial-marketplace, on the Mac mini SSD. Scope: Worker API, policy, migrations, API contract, approved design and API tests. No implementation changes, deployment or external provider requests.

## Findings

### P1: Keep document-review reasons out of public listing responses

worker/index.ts:51–55 selects l.* and returns every listing column. The admin review writes the full mandatory review reason into reviewNote at worker/index.ts:819–823. Both unauthenticated listing endpoints return that same projection. Consequently, an approval reason containing lease-holder names, permission contacts, or other information used to review private documents becomes public immediately on approval; hiding it in the frontend does not protect it. The same internal reason is already stored in the audit trail.

Return an explicit public listing DTO that excludes reviewNote; include review notes only in owner/admin-authorized responses (and omit them from renter conversation listing projections). Add a regression test using an approval reason with a private marker and assert it is absent from anonymous list/detail responses.

### P2: Invalidate review when new lease or permission evidence arrives

worker/index.ts:722–751 inserts an uploaded lease/permission document but returns without changing either the matching verification status or listing approval. Only media uploads cause a pending transition. An owner can upload revised lease/permission evidence to an approved listing, and it continues advertising verified evidence and passing reservation/payment/payout checks without a reviewer seeing the change. There is no association between a verified status and a specific reviewed document/version that would make it clear that the newly submitted evidence remains unreviewed.

Commit the document metadata and reset of the corresponding lease/permission review status to pending, with listing status pending, in one database batch. Keep the other evidence type's status unless it also needs review. Alternatively explicitly version evidence and approvals, with new submissions unable to inherit an older verification. Test uploading each evidence type after approval and assert public discovery/reservation/payout eligibility is blocked until review.

## Validation and boundaries

- npm test -- --run tests/api-policy.test.ts: 6/6 passing on mini.
- Read-only GET of local runtime /api/listings succeeded and confirmed the public listing payload exposes reviewNote (seed values currently null).
- Inspected the existing integration test and all API routes; did not execute its writes against the shared runtime database.
- Production demo authorization requires development environment plus a loopback hostname; production ignores demo-session cookies. Access tokens are verified with issuer, audience and RS256, and admin role is derived from the current server-side email allowlist.
- POST requests require matching Origin and reject cross-site Fetch Metadata. Owner/participant/admin gates protect messages, bookings, uploads and private document downloads. Private documents stream as attachments with no-store and restrictive CSP.
- Raw body readers bound actual streamed bytes, not just Content-Length; multipart file types and file sizes are separately bounded.
- SQL triggers atomically enforce nonoverlap and current host identity/lease/permission prerequisites at booking insertion and simulated payment transition. Payout eligibility rereads current review states. Live payments and signing return setup-required errors instead of changing payment/signature state.
- Access signature verification was inspected, not exercised against a live identity provider. Existing six unit tests do not provide runtime coverage for that integration.


## Follow-up review — commits 0ce87d5 and 300b190

Both original backend findings are resolved in source:

- Public catalog uses an explicit whitelist without reviewNote; detail and conversation responses include it only for the owner/admin. This also protects against accidentally exposing future listing columns.
- Lease/permission metadata insertion and corresponding verification/listing pending transition now share one D1 batch. Other evidence retains its review result. Current-review booking/payment SQL guards and payout reads consequently block progression until rereview.
- The generated Worker environment type change does not alter these runtime controls.
- Reviewed expanded API integration assertions and successful run evidence in docs/backend-report.md. The regression checks cover private reason markers in anonymous/renter projections, each replacement evidence type, discovery suppression, acceptance/payment rejection, and current booking payout blockers.
- Independently reran npm test: 11/11 passing. npm run typecheck: passing. Did not repeat the mutating integration suite against the coordinator's active runtime.

### Final frontend source findings sent to coordinator

1. P2 — src/Workspace.tsx compares paymentStatus to paid, whereas the Worker produces demo_paid. This prevents the payment timeline from completing and hides Confirm move-in forever after a simulated payment; the pay button also remains visible. Match the actual API state consistently.
2. P2 — src/search.ts validates only listing start <= requested move-in (or listing end >= requested move-out), so one-sided date filters return properties whose availability cannot contain that date. Check the other interval boundary too; test move-in after availability and move-out before availability.
3. P2 — src/PostListing.tsx disables Back after a listing is saved. If a media upload from step 2 fails, the user is trapped at step 3 with that pending file and cannot remove/replace it to retry. Permit editing the remaining upload queue after partial creation, while avoiding a duplicate listing and unintended edits to persisted fields.

These frontend issues were source-reviewed and reported to the coordinator for fixes/browser verification. No implementation edits were made by this reviewer. Backend review is otherwise clean within the stated scope and provider-validation limitations.


## Final scoped review — moderation cda1983 and frontend fixes

Outcome: no remaining P1/P2 findings in this scoped review. The three frontend findings above are resolved in the current working tree: all payment predicates use isPaymentComplete; date filters check both interval bounds and reject reversed requests; failed pending media can be removed on the final submission step without creating another listing.

Reviewed cda1983 account moderation, reports, coordinate validation and Syracuse calendar dates. Suspension gates exclude hosts from public catalog/detail/media, retain owner/participant private reads and renter disputes, block new commercial writes, and derive booking payout blockers from both participants' current database suspension state. Public listing whitelist does not expose the internal hostSuspended field; report reasons and audit entries remain admin-only. Admin suspension mutation rejects self/admin targets and records changes with audit in the same batch. Reservation and payment eligibility retain the existing review triggers alongside the new suspension triggers.

Independent validation:
- npm test: 16/16 passing (7 policy, 8 search, 1 payment-state).
- npm run typecheck: passing.
- Applied all migrations plus demo seed only to an in-memory SQLite database, then verified suspended-renter offer insertion, suspended-host booking insertion, and payment transitions with either participant suspended each abort with the expected prerequisite error.
- Reviewed expanded moderation API integration coverage and its successful runtime evidence in docs/backend-report.md. Did not mutate coordinator runtime data or perform deployment/provider calls.

Browser end-to-end verification remains with the coordinator; no reviewer implementation changes.
