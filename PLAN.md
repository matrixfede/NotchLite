# PLAN — Agent usage fixes
Plan status: APPROVED (2026-11-15)

## Objective
Fix the issues identified in the agent usage audit and publish to GitHub.

## Active requirements
- R1: Fix audited refresh, visibility, statistics and compiler warnings (user, 2026-11-15).
- R2: Commit and push to GitHub (user, 2026-11-15).

## Plan
| # | Task | Status | Depends on | Verification | Notes |
|---|------|--------|------------|--------------|-------|
| 1 | Fix usage refresh and presentation, compiler warnings | ✅ done | — | sh Tests/run.sh; swift build; usage report | Build, Swift regression checks, live report and rendered preview passed; keel VERIFY: PASS |
| 2 | Commit and push verified changes | ✅ done | 1 | git diff --check; remote SHA | Fix commit 615d8ca verified on origin/main |

## Contracts
- Task 1 — OUT: `Sources/NotchLite/UsageService.swift` — shape: queued manual refresh, shorter refresh intervals, failed attempt retry.
- Task 2 — OUT: `PROGRESS.md` — shape: append-only verification record.

## Decisions
- Existing explicit authorization covers implementation and publication.
- ASSUMED: update source and GitHub; do not replace running installed app.
- No keel hooks installed in this repository; do not introduce hooks as part of bug fixes.
