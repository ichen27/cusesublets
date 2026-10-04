# CuseSublets: social community and guided participation

Status: implementation approved October 4, 2026 after Ivan reviewed and preferred the interactive website prototype. Production integration is tracked in ../plans/2026-10-04-social-app.md.

## Intent and acceptance criteria

Ivan wants an open housing community with the public participation of Facebook groups and Reddit, alongside personalized discovery inspired by dating apps. The existing app feels bland and its navigation and user flow feel disconnected. New members should choose whether they want a place or have one, receive guided setup, and be free to finish later. One account can do both. People can publish without document verification, with truthful check labels and contextual notices. Community posts support public likes and comments; private conversations remain available without a mutual-match requirement.

The agreed journey is: choose intent → optional guided setup → community Browse → personalized Matches or public discussion → private conversation. Browse is the default home, with a matches preview when housing criteria are ready.

Success: a newcomer can understand both roles immediately, browse without completing setup, resume a private draft, publish or activate deliberately, comment on a visible post, discover a fitting place/person with explicit reasons, and start a private conversation without losing the post context. Existing listings, searches, saves, messages, checks and bookings remain accessible after migration.

## Product structure and visual direction

Primary destinations on desktop and mobile: **Browse, Matches, Inbox, You**. Mobile uses four bottom tabs; desktop uses persistent navigation. **Post a place** is a consistent desktop action, and is available from the feed and You on mobile. You contains My search, My subleases, Saved, Profile and Verification. Old activity/account/saved/explore hashes remain compatible redirects or entry points into these sections. Existing conversation and listing deep links remain usable.

Proposed visual system: saturated orange actions, deep plum text, light neutral surfaces with selective lavender accents, expressive editorial headings paired with readable sans-serif controls, prominent portraits and human introductions. Use compact functional copy rather than slogans. The generated three-screen concept is illustrative: fictional profiles, listings, counts, map art and incidental brand copy are not implementation requirements. No institutional affiliation or endorsement is implied. The concept's notification bell is illustrative and is omitted from the first implementation; existing Inbox unread indicators remain.

Desktop Browse uses a readable central social feed, a left filter column and a narrow right column for housing status and match previews. Mobile uses one feed column, accessible filter drawer and Map action. Property grid mode remains available under Places for scanning many homes. The social feed is not forced into three narrow columns. Preserve existing useful geographic filters and map/list state. Use actual profile photos or initials, not invented member imagery, in production. Color is never the only status signal.

## Entry and guided setup

First visit offers **Find a place**, **Offer my place**, and **Just exploring**. Role choice is a preference, not a permanent account type. Anonymous choice can be remembered on the device; visitors can always reach Browse without login. Sign-in is required to save housing details to an account or publish. Account setup never automatically activates a search or publishes a listing.

Find-a-place steps: (1) dates and monthly price range, (2) space/bedrooms and required/preferred conditions, (3) one to five desired map regions, (4) short introduction and public-preview summary. Final action **Turn on my search** publishes the existing canonical search. Each step has Back and Finish later. An incomplete search stays private; the home shows a resume prompt and explains which missing fields are needed for matches. A ready search has a visible on/off control. Toggling and editing retain its stable ID and discovery timestamp.

Offer-my-place steps: (1) place, approximate public location and space type, (2) rent, dates and conditions, (3) photos and description, (4) preview and publication. Final action **Publish listing** makes the listing discoverable under existing policy. A separate optional **Get verified** next step explains evidence required for identity, lease and permission checks. Finishing later stores a private draft, not a pending public listing or review submission.

Both flows save account drafts after successful step validation and show Saving/Saved/Retry. Forward progress must not silently discard a failed save. Drafts have server revisions to avoid overwriting changes from another tab; conflicts preserve local entries and offer reload/review. One search draft per account; multiple distinct property drafts are allowed. No listing or search is public until its final publication action succeeds. After publication, return to the resulting post with an explicit confirmation and routes to Matches and Browse. An existing complete member skips first-run onboarding and sees Browse.

## Community Browse and posts

Browse supports **For you / Latest** and **All / Places / People**, filters and Map. Latest orders original publication times; changing text or toggling visibility does not bump a post. Existing records without a reliable publication time keep their unknown-date label. For you uses the existing housing-fit rules for relevant candidates, followed by remaining eligible recent posts; it labels the personalized group and broader community results separately. Likes, identity and demographic attributes do not affect housing-fit ranking. Without complete criteria, For you explains that it is showing recent activity and offers setup. Anonymous users see Latest by default.

A place post starts with author portrait, display name, public housing role, timestamp and overflow menu. It contains the author's introduction, property media, rent, dates, approximate area and specific checks. A search post uses the same social structure with budget, dates, space needs and desired areas; it is the presentation of the one canonical search, never an additional repeatable seeker post. Opening a post preserves feed position and provides a shareable URL. Posting a place and activating a search are the only creation types in this release; freeform community-topic posts are out of scope.

Actions: **Like, Comment, Save, Message**. Liking is a public reaction, one per account per post; members can undo it. Saving is private and uses a bookmark icon, distinct from the heart used for Like. Existing saved listings remain saved. Search posts can also be saved, with unavailable states shown only to the saver. Public like counts and the signed-in member's reaction are visible; the first release does not expose a liker directory.

Comments expand inline with a full thread available in post detail. Signed-in, nonsuspended users can comment and reply one level deep. Text only, up to 1500 characters; no attachments or rendered HTML. Members can edit their own comments (edited label), soft-delete them, or report another comment. Deleted or removed parents with replies retain a neutral tombstone. Parent and reply must belong to the same post. New comments are chronological, with paginated loading; two recent comments preview in the feed. Failed submissions retain the draft and offer retry; an idempotency key prevents duplicate comments when retrying.

Comments are explicitly public. The composer reminds users to share phone numbers and documents privately. Post authors can participate and report comments but do not receive staff moderation powers. Staff can remove/restore comments with reasons and audit entries; suspension disables new posts, comments, likes and contact. Start with per-account limits of 10 comment/reply submissions per 10 minutes and 120 reaction mutations per 10 minutes, enforced server-side with clear retry messaging. Reports reuse the existing reporting workflow with comment targets. Public endpoints paginate; do not fetch every comment for each feed card.

When a search is turned off or a listing is paused/removed, its public post, comments and reactions disappear together; direct public URLs return unavailable. Retain data for restoration and moderation. Existing private conversation participants keep conversation history. New social writes and contact creation must recheck post eligibility at write time, including concurrent pause/removal.

## Matches and private contact

Matches uses a focused card presentation with large media, a visible person, rent/dates, relevant check labels and concise **Why it fits** reasons. **For my search / For my listing** selects perspective; members with both activities can switch without changing their roles. Preserve the existing shared eligibility rules: dates, budget range, room type, whole-place bedrooms, desired region and required conditions. Rank eligible pairs by preferred conditions, then rent, then stable IDs. Do not display fabricated percentages or rank by identity, demographics, likes or popularity.

Actions: **Next**, **Save**, **Interested**, and **View post & conversation**. Next advances the current session's cards and is not a permanent dislike or feedback signal; provide Back and a review-again end state. Interested opens a private conversation composer with the relevant listing/search context. The action alone does not send an automatic message or reveal private contact information. The member explicitly sends their own first message. Mutual interest is not required. Hosts select a fitting owned live listing before contacting a seeker. Search-off, suspension and availability guards apply at the server even when a card is stale.

Browse's matches preview shows the real eligible count and up to three candidates. Incomplete/off search and no-live-listing states offer the relevant setup/resume/activate action. Empty results explain that there are no full fits and link to editable criteria and Browse; never invent recommendations that violate required conditions.

## Verification at the point of interest

Publishing and verification remain independent. Display specific existing states: identity, lease and permission, with badges only when the corresponding evidence has been reviewed successfully. Uploading documents means **Under review**, not Verified. Missing, outdated or rejected checks must not be presented as successful. Clicking a badge opens a short explanation of what it establishes and its limits.

When Interested or Message is chosen for a listing with incomplete checks, show one concise notice identifying the missing checks, for example: **This listing's lease and permission to sublease haven't been checked. Review the details before making commitments or sending money.** Actions: **Continue to message** and **View checks**. This acknowledgement does not block publication or create a verification record. Keep it local to the composer session; reopening contact shows the current check state. When a host contacts a seeker whose identity is unverified, identify that specific missing identity check without implying property-document checks apply to the seeker. No copy claims that a verified person/property is guaranteed safe. Existing document privacy, review authority and booking prerequisites remain intact.

## Activity and continuity

Public threads and the existing Inbox provide the first release's conversation continuity. A separate notification center, email and push notifications are out of scope.

You shows independent **Looking for a place** and **Offering a place** sections, resume drafts, edit/pause controls, Saved, profile and verification. Offering status derives from published available listings. Search status is independently controlled. Existing account/profile/admin functionality remains reachable. Back navigation and returning from a thread restore Browse filters, scroll and map viewport. Public action prompts preserve the intended destination across login.

## Architecture and data boundaries

Implement as coordinated workstreams: (1) app shell and onboarding/drafts, (2) post presentation plus social data and moderation, (3) focused Matches and contextual trust flow. The release shares one visual system and navigation model. Reuse current canonical searches, listing records, shared fit/geometry functions, conversations and evidence states.

Add distinct private onboarding/draft storage; do not overload published listing records with incomplete drafts. Give posts stable references to listing IDs or canonical-search IDs, unique per target. Add reactions (unique post/member), comments (author, parent, text, timestamps, soft-deletion/moderation state), comment reports. Extend private saves to searches without converting existing saves to public reactions. Add API modules for drafts, post social actions, keeping validation/authorization outside React. Extract existing monolithic route logic only as required to create these boundaries.

All mutations require current session, exact origin, ownership/role checks, limits and target-visibility checks. Public projections omit email, phone, draft contents, documents, internal review notes and internal moderation data. Validate text lengths, reply depth and state on the server. Use atomic unique constraints and conditional writes for reactions, publication, contact and moderation races. Index post/time pagination. Soft deletion and moderation never erase audit history.

New tables and backfills are additive. Existing original records and conversation/report references are retained. Rollout keeps old deep links working. Do not change matching rules, payment/signing providers, Access policies or private-document permissions as part of this redesign.

## Verification and rollout

Verify skipped/resumed setup, owner-only incomplete drafts, revision conflicts, validation before publication, both roles, one canonical search, duplicate submit/retry handling, no feed bump on edits/toggles, saves-versus-likes privacy, reply nesting, rate limits, moderation and pause races, and exact check-state notices. Match tests retain all current housing-fit eligibility cases and confirm private messaging needs no mutual like.

Browser acceptance follows the full journey on desktop and narrow mobile: first visit → choose role → finish later → Browse → resume → publish/activate → public comment → Matches → trust notice → explicit private message → return to prior feed position. Test keyboard navigation, focus in drawers/dialogs, clear labels, reduced motion, touch targets and contrast. Demonstration members/media stay in isolated state. Run existing typecheck/unit/build and runtime/hosted guards, plus the new integration coverage; review real screens against the approved concept before rollout.

Use a feature branch, pass GitHub checks, back up each exact persistence directory while its service is stopped, apply additive migrations separately to demo and hosted state, and preserve record IDs/counts and existing check states. Never seed hosted data. Publish the UI only when the social APIs and moderation controls are ready together. Record rollback source and state snapshots; avoid restoring a snapshot over subsequent member activity without reconciliation.

## Review focus

Confirm the proposed visual treatment, feed-first four-tab navigation, optional resumable setup, social actions and moderation scope, and Interested opening a composer rather than sending automatically. After this written spec is reviewed, prepare the implementation plan and execution sequence. Ivan subsequently authorized implementation on October 4; preserve existing records during rollout.
