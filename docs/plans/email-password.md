# Email and password accounts

Approved scope: retain Google and local demo; add password signup, login, and password changes. Public signup always creates an unverified member. Existing email ownership is never silently linked. Staff credentials are provisioned offline against the existing staff user.

Plan: add credential/session/rate-limit migration; test real scrypt hashing; implement bounded public auth endpoints and revocable opaque sessions; add accessible login/signup/password-change forms; verify isolated workerd runtime, typecheck, unit tests and build.

Passwords use scrypt N=16384,r=8,p=5 with a random 16-byte salt and 32-byte key. Hash serialization is scrypt$16384$8$5$<salt hex>$<key hex>. Sessions expire after eight hours and store only SHA-256 token hashes. Rate limits use atomic D1 counters for IP and normalized email, shared across login/signup, in 15-minute windows. Password changes revoke all sessions. Hosted cookies are Secure/HttpOnly/SameSite=Lax; POST requires exact origin.

No email delivery is configured: signup does not verify email and there is no self-service forgotten-password reset. Google collisions must use the existing account method; no automatic account linking. Password changes require the current password. Identity verification remains a separate reviewed workflow.
