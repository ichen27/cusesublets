# CuseSublets — approved design
User approved the marketplace, admin side, orange/cream UI, and CuseSublets name on 2026-09-16. This document consolidates those approvals; proceed without another approval round.

## Product
Syracuse-first sublease marketplace. Public split map/catalog, filters, detail gallery, specific trust badges. Responsive cream/charcoal/orange UI, friendly copy. Schools modeled explicitly for future expansion; initial school Syracuse.

## Working application
React + Vite static frontend served by Cloudflare Worker. D1 persistent records and private R2 uploads. Cloudflare Access JWT validation with Google provider configured externally. Public discovery bypasses login; mutations require authenticated user. Admin allowlist uses server-side email configuration. Local-only demo identities explicitly labeled and disabled by default outside localhost.

Listing creation with photos, room/home video and validated Matterport URL. Draft/pending/approved/needs_info/rejected/paused lifecycle. Separate identity, lease, permission review. Private document review; upload alone never verifies. Admin decision reasons and append-only audit entries. Messaging and offers with owner/participant authorization. Reservation status timeline, agreement acknowledgments, payment test flow, dispute and payout eligibility. Live signing provider and live payments remain disabled until business/provider setup; do not imply demo signatures are a legal signing service. Payment successful only from verified provider webhook, never from return URL. No real Stripe secret or identity provider is assumed.

## Trust invariants
No raw IDs stored. No blanket scam-free guarantee. IDs and lease papers never public. Guests cannot mutate; members cannot use admin APIs; owners cannot accept their own offers; accepted bookings cannot overlap. Positive bounded dollar amounts, valid date intervals. Payout blocked until payment, agreement, required reviews, confirmed move-in plus 48 hours, and no open dispute. Billing totals calculated server-side. Human review defaults to pending. Clearly label sample listings and local demo transactions. Exact public location initially approximate.

## Delivery
New isolated Git branch feat/initial-marketplace at /Volumes/SamsungSSD1/code/cusesublets on mini. Build and runtime tests on mini. Local preview via SSH forwarding; no public deployment requested. Workers deployment configuration and runbook included. External integrations fail closed with actionable setup messages. Automated API authorization/state tests plus desktop/mobile browser checks.
