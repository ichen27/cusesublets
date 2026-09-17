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
- POST `/api/offers/:id/accept` `{}` → `{booking:Booking}` owner only; reserves nonoverlapping dates atomically.
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
