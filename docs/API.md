# CuseSublets API

All endpoints same-origin. Errors `{error:string}` with non-2xx. Money is USD monthly dollars. Dates ISO YYYY-MM-DD. Types match shared/types.ts. Demo requires APP_ENV=development and localhost/127.0.0.1; production uses verified Access JWT. Mutating requests require matching Origin. Private APIs require a session.

- GET `/api/session` → `{user:User|null,demo:boolean}`
- POST `/api/dev/session` `{role:'renter'|'host'|'admin'}` → session above; sets HttpOnly cookie.
- POST `/api/logout` `{}` → `{ok:true}` clears local session. Production logout must also clear Access session through `/cdn-cgi/access/logout`.
- GET `/api/listings` → `{listings:Listing[]}` approved public listings.
- GET `/api/listings/:id` → `{listing:Listing}` (pending only owner/admin).
- POST `/api/listings` `{title,neighborhood,address,price,beds,baths,roomType,startDate,endDate,description,amenities?:string[],images?:string[],videoUrl?:string,matterportUrl?:string,walkMinutes?:number}` → `{listing:Listing}` pending review. Approximate coordinates assigned for Syracuse; address must describe approximate public location.
- GET `/api/mine` → `{listings:Listing[],documents:DocumentRecord[]}`
- POST `/api/profile` `{name:string}` → `{user:User}`; cannot change role/identity.
- GET `/api/messages` → `{messages:Message[],listings:Listing[]}` participant messages.
- POST `/api/messages` `{listingId:string,body:string,recipientId?:string}` → `{message:Message}`. Renter recipient defaults to owner; owner must specify an existing conversation participant.
- GET `/api/offers` → `{offers:Offer[]}` participant offers.
- POST `/api/offers` `{listingId,amount:number,startDate,endDate}` → `{offer:Offer}`
- POST `/api/offers/:id/accept` `{}` → `{booking:Booking}` other proposal participant only; reserves nonoverlapping dates atomically.
- GET `/api/bookings` → `{bookings:Booking[]}` participants only; additional `payoutEligible:boolean` and `payoutBlockers:string[]` on each booking.
- POST `/api/bookings/:id/action` `{action:'sign'|'pay'|'confirm-move-in'|'dispute',reason?:string}` → `{booking:Booking}`. Sign is an explicitly demo-only acknowledgment; pay is simulated, never escrow; live calls fail setup-required. Both parties sign; only renter pays/confirms move-in/disputes. Dispute requires reason. Move-in must reach start date; payout waits 48 hours and requires all reviews.
- POST `/api/listings/:id/documents` multipart fields `file` (PDF/PNG/JPEG, max 5 MB), `kind:'lease'|'permission'` → `{document:DocumentRecord}`. Identity documents rejected: no raw IDs stored.
- GET `/api/documents/:id` → attachment stream, owner/admin only, no-store.
- GET `/api/admin` → `{listings:Listing[],users:User[],documents:DocumentRecord[],bookings:Booking[],audit:Audit[]}`
- POST `/api/admin/listings/:id/review` `{status:'approved'|'needs_info'|'rejected'|'paused',leaseStatus:'pending'|'verified'|'needs_info'|'rejected',permissionStatus: same,reason:string}` → `{listing:Listing}`. Approved requires verified lease and permission; reason audited atomically.
- POST `/api/admin/users/:id/review` `{identity:'verified'|'needs_info'|'rejected',reason:string}` → `{user:User}`. Review records an external identity-review result, never raw ID upload.
- POST `/api/admin/bookings/:id/resolve` `{reason:string}` → `{booking:Booking}`. Resolves open dispute with mandatory audit.

Demo seed is `seeds/demo.sql`, separate from schema migration; never apply seed to production. Seed roles: demo-renter / demo-host / demo-admin. Six approved sample listings plus one pending. No live email/payment/signing/identity-provider integrations are implied.

- GET `/api/login` verifies Cloudflare Access identity then redirects to `/#account`. Configure Access protection for this login path; configure Google as its identity provider. The API also verifies the Access JWT cookie cryptographically on public application paths.
- POST `/api/listings/:id/media` multipart `file` supports PNG/JPEG/WebP up to 5 MB or MP4/WebM up to 25 MB; owner only; returns `{url:string,listing:Listing}` and resets listing to pending review. Maximum 30 total files per listing.
- GET `/api/media/:id` streams uploaded media only for approved listings or their owner/admin.
- Individual bookings and GET bookings include `totalCents:number,currency:"USD"` computed server-side from the agreed monthly amount using a disclosed 30-day proration, alongside `payoutEligible,payoutBlockers`. These are sample totals only; no funds are held or released.

Public catalog, renter listing details and renter conversation listings exclude internal `reviewNote`; owner/admin detail and authorized private views may contain it. Uploading new lease or permission evidence atomically changes that review status and the listing to `pending`, preserving the other evidence review. Acceptance, payment and payout eligibility require fresh completed reviews after the upload.

## Moderation

- `User` now includes optional `suspended:boolean` (API emits a boolean).
- POST `/api/listings/:id/report` `{reason:string}` (10–2000 chars) → `{report:Report}`; authenticated nonowner, visible listing or existing reservation participant; creates an audited open report.
- GET `/api/admin` additionally returns `{reports:Report[]}`. `Report = {id:string,listingId:string,reporterId:string,reason:string,status:'open'|'resolved',createdAt:string}`.
- POST `/api/admin/users/:id/status` `{suspended:boolean,reason:string}` (5–2000 chars) → `{user:User}`; staff cannot suspend themselves or another admin; atomic audit records both suspension and restoration.
- POST `/api/admin/reports/:id/resolve` `{reason:string}` (10–2000 chars) → `{report:Report}`; atomic mandatory-reason audit.
- Suspended accounts retain authenticated reads and existing renter dispute actions, but cannot create listings/offers/messages, accept reservations, upload, sign or pay. Suspended hosts disappear from public catalog/detail/media. Current host/buyer suspension blocks reservation/payment and payout eligibility. Restoration re-enables eligible approved listings without changing historical reviews.

New listing input optionally accepts `lat:number` between 42.9–43.15 and `lng:number` between -76.3–-75.95. Coordinates are rounded to three decimal places for an approximate location. Omitting coordinates defaults to a central Syracuse map position (43.037, -76.127); this is not address geocoding.

## Conversations and negotiation

- GET `/api/conversations` → `{conversations:ConversationSummary[]}`, newest activity first; only the signed-in participant's threads.
- POST `/api/conversations` `{listingId:string}` → `{conversation:ConversationSummary}` (201). Opens or reuses the unique listing/renter thread without sending a message. New threads require a visible approved listing; owners use their existing inbox threads.
- GET `/api/conversations/:id` → `ConversationDetail = {conversation,listing,peer:{id,name},messages,offers,bookings,attachments,events}`. Listing contains current property context; renter views exclude private review notes. Review documents are never included. Historical threads remain readable if a listing is paused or an account is suspended.
- POST `/api/conversations/:id/messages` `{body:string}` (1–2000 chars) → `{message:Message}` (201).
- POST `/api/conversations/:id/documents` multipart `file` → `{attachment:ChatAttachment}` (201). PDF/JPEG/PNG only, declared type must match magic bytes, maximum 5 MiB, maximum 100 documents per thread. Object keys are not returned.
- GET `/api/chat-documents/:id` → protected attachment stream with no-store and sandbox headers. Only the two conversation participants can download, including when an administrator is the requester. These are explicitly shared files, independent of private listing-review evidence.
- POST `/api/conversations/:id/offers` `{amount:number,startDate,endDate,parentOfferId?:string,kind?:'offer'|'request'}` → `{offer:Offer}` (201). Either participant can propose; kind defaults to offer. Dates must be within current availability and start no earlier than today in Syracuse. A counteroffer must reference the other participant's pending proposal in this thread; inserting it and marking the parent countered happen in one database transaction.
- POST `/api/offers/:id/accept` `{}` → `{booking:Booking}` (201). Only the other participant may accept a pending proposal. Acceptance checks current listing review, dates, participant suspension and nonoverlap atomically. The listing owner remains seller even if they proposed.
- POST `/api/offers/:id/decline` `{}` → `{offer:Offer}`; only the other participant can decline a pending proposal.
- POST `/api/offers/:id/withdraw` `{}` → `{offer:Offer}`; only its proposer can withdraw a pending proposal.

Conversation summary fields: `id,listingId,buyerId,sellerId,createdAt,updatedAt,listingTitle,listingImage,peerName,lastMessage?`. An empty image is an empty string; an empty thread has an empty lastMessage. Offers additionally expose `conversationId,proposedBy,parentOfferId,createdAt,kind`; parentOfferId is null for an original proposal. Statuses are pending, countered, accepted, declined or withdrawn. Chat attachments expose `id,conversationId,senderId,name,type,size,createdAt`. Events expose `id,conversationId,actorId,kind,body,offerId?,createdAt`.

Legacy message and offer creation endpoints use the same conversations. Legacy messages retain their database layout; conversation detail derives their thread membership. Migration `0004_conversations.sql` backfills threads from existing messages/offers and marks legacy offers as proposed by the renter. Run migrations against each intended persistence directory only while its runtime is stopped; never share SQLite state between active Wrangler processes.

Signing/payment controls still use `/api/bookings/:id/action`. Hosted calls remain setup-required (503); local demo acknowledgments and simulated payments create clearly labeled chat events and never represent a legal signature or money movement.

Isolated verification: apply migrations and demo seed with `--persist-to .wrangler-chat-test`; start Wrangler on 8920 with the same isolated directory and `APP_ENV=development`; run `API_BASE=http://127.0.0.1:8920 python3 tests/chat-runtime.py`. Never use this test state for the existing 8917/8918 services.

## Profiles and optional manual checks

New listings publish immediately (approved) with pending lease and permission checks. Existing listings retain their status. Reservations/payment still require verified host identity, lease and permission. Uploading media or replacement evidence preserves publication status; replacement evidence resets only its corresponding check.

- GET /api/profile returns user, profile (bio, phone, socials, avatar, photos), identityDocuments and identityNote. Private account information.
- POST /api/profile accepts optional name, phone, bio, socials. Omitted fields are preserved. Email cannot be changed here. Name changes invalidate identity approval and require new evidence. Social URLs must use HTTPS.
- POST /api/profile/media accepts multipart file (JPG/PNG, maximum 5MB) and kind (avatar/photo). Returns url. Gallery maximum 12.
- POST /api/profile/media/remove accepts url, removes an owned image and returns updated account.
- GET /api/profile-media/:id returns public image; unavailable for suspended accounts. Storage metadata is independent from private evidence.
- POST /api/profile/identity accepts multipart file (PDF/JPG/PNG, maximum 5MB; bytes checked). Returns document (id, name, type, createdAt); resets identity check.
- GET /api/identity-documents/:id is owner/admin only, attachment download with no-store.
- GET /api/users/:id returns profile, listings, reviews, reviewableBookings. Explicit public profile projection excludes email, phone, evidence and review reasons. Listings are published only; eligible bookings visible only to authenticated counterpart.
- POST /api/users/:id/reviews accepts bookingId, rating, body. Integer 1–5 stars and 10–2000 characters. Requires paid booking, move-in, past end date in Syracuse, no open dispute, active participants and no cancellation. Local development accepts simulated payment. Unique per booking/reviewer; no self reviews.
- GET /api/admin/identities returns submissions with userId, name, email, identity, identityNote and documents. Current-name evidence only, newest first.
- POST /api/admin/identities/:userId/review accepts status (verified/needs_info/rejected), reason and documentId. Requires latest evidence matching current name version. Self-review denied. Existing /api/admin/users/:id/review accepts identity as status alias but also requires documentId.
- Listing review retains status, leaseStatus, permissionStatus and reason; requires leaseDocumentId and/or permissionDocumentId for each check set to verified. IDs must refer to latest evidence of the respective kind. Evidence revalidation and audited decision are atomic. Publication approval can coexist with pending checks. Admin cannot verify own evidence.

Admin and owner listing document arrays are newest first, including uploads in the same millisecond. Use the first document of each kind. Identity evidence never appears in public profile media.

Isolated validation: migrate/seed with --persist-to .wrangler-checks, run Wrangler on 8921 with same persistence path, then run tests/api-runtime.py, tests/chat-runtime.py, tests/profiles-runtime.py with API_BASE=http://127.0.0.1:8921. Profiles test advances a test reservation in that isolated database; do not run against operational data.

## Email and password authentication

- POST `/api/auth/signup` `{name,email,password}` → `{user}`. Always creates a member with pending identity. Existing emails return 409; no Google linking or staff elevation.
- POST `/api/auth/login` `{email,password}` → `{user}`. Wrong credentials and suspended users return the same 401 message.
- GET `/api/auth/status` → `{hasPassword:boolean}`, authenticated nonsuspended users only.
- POST `/api/auth/password` `{currentPassword,newPassword}` → `{ok:true}`, requires a password session and current password; atomically revokes other password sessions and issues a fresh one.
- POST `/api/logout` revokes the current password session and expires password/demo cookies even if the Cloudflare cookie has expired.

Passwords are 15–128 characters; request bodies at most 4 KiB. Login/signup share atomic per-email (10) and per-IP (40) attempt limits per 15-minute window. Password sessions last eight hours. Cookies are HttpOnly, SameSite=Lax, Secure outside local demo. Hosted preview remains browsing-only. Password cookies take precedence on ordinary requests; explicit Google login clears that preference after successful JWT authentication.

Emails are not verified through signup. Identity badges require separate staff review. There is no automated email verification or forgotten-password email because no mail provider is configured. Staff credentials may be provisioned offline on the existing user; never put passwords in Git, command arguments or logs. Credential format and design are in [email/password plan](plans/email-password.md).
