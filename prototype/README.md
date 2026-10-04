# CuseSublets interactive community concept

Isolated browser prototype of the approved social visual direction: three desktop columns, orange/plum/lavender, serif headings, no handwritten decorations. Responsive mobile version has four bottom destinations.

Uses fictional people and property records. Likes, bookmarks, comments, search/listing drafts, sample posts and conversations are stored in this browser under `cusesublets-community-concept-v1`. It has no production API calls, login, real document uploads or external message delivery. Photos are remote Unsplash sample assets; map tiles are OpenStreetMap. Desired regions are approximate named rectangles in this preview; production polygon drawing remains in the existing app.

Run on the Mac mini from the repository root:

```sh
npx tsc --noEmit -p prototype/tsconfig.json
npx vite build --config prototype/vite.config.ts
python3 -m http.server 8931 --bind 127.0.0.1 --directory prototype-dist
```

For development with live reload, use `npx vite --config prototype/vite.config.ts` instead of the static server (never both on8931). From the MacBook forward `ssh -N -L 8931:127.0.0.1:8931 mini`, then open http://127.0.0.1:8931/ .

Current preview log/PID: `/Volumes/SamsungSSD1/tools/cusesublets/community-preview/`. Main demo8917 and hosted8918 use their original source/build/data and are unaffected. Stop only the PID recorded for this preview after confirming its command. Rebuild prototype-dist to update the static preview; restarting the server is unnecessary.

Try: welcome → Find a place → three setup steps → Browse → like/save/comment → Matches → Interested → unverified notice → simulated Inbox. From You resume setup, toggle search, create/edit/pause a sample listing, view saved posts, or reset sample data. Publishing a fitting listing enables the host direction in the Match source selector. Next cycles sample matches without a permanent rejection signal.

Validation:39 tests (including3 prototype fit cases), both TypeScript configurations, both builds, and GitHub checks. Browser checked first-run setup and desired areas, active search, public comment/save/like, search draft isolation, unverified contact and explicit simulated send, per-recipient draft preservation after refresh, listing questionnaire and host matches,390px no overflow. This is a design prototype, not completion of the production social-community specification.
