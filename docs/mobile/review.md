# iPhone implementation review

Baseline: `2e6d7b4`. Initial implementation: `bb319d3`. Follow-up: `c1adcea` plus pagination hardening.

## Standards

- Bounded uploads: the initial client loaded a whole file before checking its size. Corrected to inspect size before reading, read at most the permitted size plus one byte, and perform file I/O away from the UI actor.
- Saved-target resolution: initial saved items depended on the newest 200 feed entries. Corrected to fetch each authorized target directly, including a public canonical search-detail endpoint.
- Follow-up pagination review: a failed page could append partial results while retaining the previous cursor. Corrected to commit each page atomically and prevent overlapping loads.

## Spec

- Initial listing publication sent a zero walk-time value rejected by the API. Corrected with a visible editable field, a valid default and recovery of old zero-valued drafts. Added a simulator publication flow test.
- Initial profile updates could erase existing social links not exposed in the form. Corrected by preserving those values and disabling save until the profile has loaded.
- Draft identity is now stable across native view reconstruction.

Scoped static rechecks confirmed the original upload, saved-target, publication and profile findings resolved. A final recheck of `b1869bc` also confirmed atomic page updates and the overlapping-load guard resolve the follow-up pagination finding. Validation evidence belongs in `validation.md`; static review is not a device-test result.

The full migration remains broader than this first implementation. Photographic reconstruction, device capture quality, distribution and the parity items listed in `iphone-plan.md` remain explicit open work.

## Marketplace parity follow-up

The standards review found calendar controls using the device time zone while storage uses Syracuse dates; the root environment now supplies America/New_York. The spec review found completed-lease reviews of renters unreachable from host conversations; conversation peers now link to member profiles. The comment keyboard has an explicit dismissal control. Both reviewers rechecked these fixes without further actionable findings. CI then identified map-intercepted scrolling in the expanded interaction test; that recording led to a noninteractive listing-detail map preview. Current CI evidence is tracked in validation.md.

## Photographic tour review

Two-axis review of `eb8b6de...d95f016` found the native uppercase UUID / lowercase processor-route mismatch; processor routing now accepts native UUID case and the full API lifecycle test uses uppercase IDs. Storage cleanup now retains a private deletion tombstone until object deletion succeeds, with a transient-storage-failure test. The browser clears retained tour state on context changes (the listing parent also keys it by account). The native viewer directs export to the working native share control instead of offering a blocked download link. Processor termination now happens inside the private-directory scope before cleanup, with a timeout-ordering test. A browser check also corrected PlayCanvas's default canvas fill behavior so it stays within its parent at desktop and phone widths.
