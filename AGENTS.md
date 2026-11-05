# CuseSublets development

- Follow the SSD operating standard on the Mac mini. The canonical checkout at `/Volumes/SamsungSSD1/code/cusesublets` serves a watched preview: editing source or rebuilding assets there can change the live site. Use a separate feature worktree for development; the iPhone branch uses `/Volumes/SamsungSSD1/code/cusesublets-iphone`. Before editing, building, or changing the preview service, read `docs/deployment.md` and verify which checkout the service watches.
- GitHub source repository: https://github.com/ichen27/cusesublets.
- `main` is the stable branch. Use feature branches for changes, run typecheck, unit tests and build, then commit and push all completed work to GitHub. Never leave completed changes only on the mini.
- Before editing, inspect branch and working tree; preserve unrelated changes. Do not force-push.
- Keep credentials, `.env*`, `.dev.vars`, uploads, databases and runtime state out of Git. Runtime state belongs under `/Volumes/SamsungSSD1/tools/`.
- GitHub Actions checks pushes and pull requests. Deploy through `docs/deployment.md`, preserving the database and validating the running service. Local watch-mode changes can affect the preview independently of a Git push.
- Public browsing and account login are separate. Cloudflare Access should protect the login entry, while the Worker validates identity and permissions on private APIs. Google sign-in never grants a verification badge.
- For iPhone changes, read `ios/README.md` for setup and simulator checks, and `docs/mobile/iphone-plan.md` plus `docs/mobile/validation.md` for scope and verified evidence. Keep simulator success, physical capture validation, and distribution readiness distinct.
