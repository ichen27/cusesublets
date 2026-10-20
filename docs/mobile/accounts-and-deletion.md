# iPhone accounts and deletion

Status: implemented on the feature branch and tested with synthetic accounts. Hosted identity-provider configuration, real Apple authorization and distribution signing remain unverified. This document describes behavior, not a claim of App Store approval or legal compliance.

## Sessions

The app stores its eight-hour session in the device-only Keychain. It checks local expiry before provider/network I/O, refreshes server identity on foreground and every minute while active, rejects responses from a previous session, and clears downloaded private files when a session ends or a cold launch has no valid credential. Offline logout clears the iPhone immediately; it reports that server revocation could not be confirmed. Owner-scoped unfinished captures survive ordinary logout for recovery; account deletion removes that owner's local captures.

## Sign in with Apple

The app uses AuthenticationServices with a server-issued, five-minute, one-use nonce challenge. The Worker verifies Apple RS256 signatures, issuer, app audience, token age and nonce, exchanges the authorization code, and compares both identity subjects. An existing email is never silently linked. Refresh tokens are encrypted with AES-GCM, with the Apple subject authenticated as associated data, for later revocation.

Configure these Worker secrets through the deployment environment, never Git:

- `APPLE_CLIENT_ID`: the registered iPhone bundle identifier.
- `APPLE_TEAM_ID` and `APPLE_KEY_ID`: the Apple team and Sign in with Apple key identifiers.
- `APPLE_PRIVATE_KEY`: the PEM-encoded `.p8` signing key.
- `APPLE_TOKEN_KEY`: 64 hexadecimal characters from a cryptographically secure generator. Back it up securely; losing it prevents decrypting retained revocation credentials. Key rotation needs an explicit re-encryption migration.

Enable Sign in with Apple on the matching App ID and signing profile. Register the HTTPS server notification URL `/api/auth/apple/notifications`. This is the only added authentication POST exempt from browser Origin validation: its signed Apple notification is verified instead. Credential revocation/account deletion notifications invalidate sessions; email forwarding events update forwarding availability. Event timestamps fence older/out-of-order notifications and concurrent authentication. Apple identity deletion does not itself erase an independently held CuseSublets account; the in-app account deletion flow does that.

The release app offers Google only when the backend also reports Apple configured. Debug builds retain Google for hosted testing. Email/password remains available when social providers are unconfigured. A successful configuration check is not proof of working provider authorization.

## Account deletion

Choose **You → Delete account**, read the consequences, and type DELETE. No email or customer-service conversation is required. A random receipt is saved in device-only Keychain before the request; its hash is stored by the server. **You → Account deletion status** works after logout/relaunch and recovers a lost response without revealing profile data.

One database transaction removes credentials/sessions, drafts, layouts, tour metadata, upload metadata, reviews and reactions; erases authored text and profile fields; removes listing/search details; and disables the account permanently. Database triggers reject writes authenticated before deletion and prevent identity resurrection. Authored messages are replaced with a deletion notice. Shared booking/offer references, the other participant's own messages, and immutable audit action/time references retain an empty “Deleted member” placeholder. Free-text dispute and relevant audit reasons are removed. Pending offers are withdrawn. Deletion does not itself cancel a lease, pay a refund or resolve a legal dispute. The retained shared-reference policy requires operator/legal review before real transactions; it is not presented as a legally mandated retention exception.

Storage prefixes and the encrypted Apple revocation credential remain in a durable cleanup job until cleanup succeeds. Every 15 minutes, the scheduled Worker retries due jobs. A second sweep after at least 15 minutes catches uploads already in flight before deletion. Small accounts normally complete within 30 minutes; larger accounts, queued requests and outages can delay it. Each invocation handles one leased job and at most eight resource pages, checkpointing progress durably. A complete pass beginning after the settling window is required for completion; daily completed-job sweeps also resume across invocations. Monitor queue age and provide more frequent scheduled invocations if volume grows. The receipt distinguishes processing from complete. Completed jobs retain opaque cleanup prefixes for daily late-write sweeps. The job does not retain original names, emails, documents or authored text. Apple revocation must succeed before completion.

**Deployment requirement:** enable Cron Triggers and monitor `account_deletion_retry` events / overdue jobs. A local watched Wrangler server does not automatically execute cloud cron. Configure an equivalent scheduled invocation before enabling real accounts on a local deployment. Do not claim cleanup completion without the status receipt. Backup/restore operations must replay deletion records before restored data is made available; historical operator backups are outside the active-storage cleanup job and need an approved expiry/erasure schedule before release.

Retired Google subject IDs cannot recreate the deleted account through an old Access JWT. A user can create a separate email/password account; re-enabling Google for that subject needs an explicit account-linking flow, which is not implemented.

## Validation

- Real SQLite tests: challenge consumption/replay, email collision, suspension, token revocation, webhook ordering, revocation arriving before identity update/session insertion, atomic erasure, immutable deletion fences, and storage failure/retry.
- Isolated API test: owned content disappearance, invalidated login, receipt secrecy, surviving participant history, and schema-compatible deleted listings.
- Native tests: local expiry, unauthorized response, cold-launch cleanup, offline logout, Apple provider error fallback, owner-scoped deletion recovery, and deleted-listing decoding.
- Real Apple/Google hosted authorization, external notification delivery, device Keychain behavior, backup policy and release signing remain separate gates.

Primary references: [Apple account deletion guidance](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion), [login services guideline](https://developer.apple.com/app-store/review/guidelines/#login-services), [Apple account notifications](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts), [Cloudflare scheduled handlers](https://developers.cloudflare.com/workers/runtime-apis/handlers/scheduled/).
