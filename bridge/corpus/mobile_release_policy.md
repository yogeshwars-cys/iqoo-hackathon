# Mobile Client Build & Release Policy (Demo Suite)

## 1. Release Channels & Cadence
The mobile client ships on three channels with independent cadences:

    CANARY_ROLLOUT_PCT_DAY_1   = 1
    CANARY_ROLLOUT_PCT_DAY_3   = 10
    CANARY_ROLLOUT_PCT_DAY_7   = 50
    STABLE_PROMOTION_DELAY_DAYS = 10

A build is never promoted from canary to stable before STABLE_PROMOTION_DELAY_DAYS (10 days) have elapsed, regardless of how clean its crash telemetry looks — the delay exists specifically to catch regressions that only appear under a full week of real-world device diversity.

## 2. Crash-Rate Kill Gate
A canary build is automatically halted and rolled back — no human approval needed for the halt itself, though resuming it does — when either of the following is true:

- Crash-free session rate drops below 99.5% for the canary cohort over any rolling 4-hour window.
- Any single crash signature accounts for more than 0.3% of all sessions on the build.

Resuming a halted rollout requires the mobile lead to attach a root-cause note to the release ticket before the rollout percentage can be edited again.

## 3. Code Freeze Windows
- A soft freeze begins 5 days before a scheduled stable promotion: only P0/P1 fixes may merge to the release branch, and each requires two reviewer approvals instead of the usual one.
- A hard freeze begins 24 hours before promotion: no merges at all, exceptions require the mobile lead and the on-call reliability engineer to both sign off in the same thread.
- Freezes are lifted automatically at the scheduled promotion time; they are never extended silently — an extension requires posting the new end time to the release channel.

## 4. Permission & Dependency Review
Every dependency bump that changes the app's declared Android permissions is blocked from merging until security review signs off, tracked separately from ordinary code review. `aapt2 dump permissions` runs in CI on every release-branch build and fails the pipeline if the permission set differs from the last approved baseline.

    MAX_APK_SIZE_MB_UNIVERSAL   = 200
    MAX_APK_SIZE_MB_PER_ABI     = 150
    COLD_START_BUDGET_MS        = 2500

A release-branch build exceeding MAX_APK_SIZE_MB_PER_ABI fails CI outright; the universal-APK budget is 50 MB higher because it bundles every ABI's native libraries in one artifact.

## 5. Post-Release Monitoring
For the first 72 hours after a stable promotion, the mobile lead reviews crash telemetry at the start and end of each business day. After 72 hours, review reverts to the standard weekly cadence unless a Severity 1 or 2 incident (see the reliability runbook) is open against the release.
