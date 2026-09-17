# CuseSublets development

- Develop on the Mac mini at `/Volumes/SamsungSSD1/code/cusesublets`; follow the SSD operating standard.
- GitHub source repository: https://github.com/ichen27/cusesublets (private).
- `main` is the stable branch. Use feature branches for changes, run typecheck, unit tests and build, then commit and push all completed work to GitHub. Never leave completed changes only on the mini.
- Before editing, inspect branch and working tree; preserve unrelated changes. Do not force-push.
- Keep credentials, `.env*`, `.dev.vars`, uploads, databases and runtime state out of Git. Runtime state belongs under `/Volumes/SamsungSSD1/tools/`.
- GitHub Actions checks pushes and pull requests. A push does not automatically deploy: use the documented mini deployment procedure, preserving the database and validating the running service.
- Public browsing and account login are separate. Cloudflare Access should protect the login entry, while the Worker validates identity and permissions on private APIs. Google sign-in never grants a verification badge.
