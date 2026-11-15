# Progress

## 2026-11-15
- DID: Implemented authorized agent refresh, visibility, daily aggregation and concurrency warning fixes. Build, standalone Swift regression checks, live usage report, preview inspection and keel verification passed.
- DECIDED: Use standalone Swift tests because the installed Command Line Tools lack XCTest. Keep the installed app unchanged. Remaining linker warnings concern toolchain search paths.
- BLOCKED: None.
- NEXT: Commit and push to origin/main.

## 2026-11-15 publication
- DID: Committed fixes as 615d8ca and pushed to origin/main; remote SHA verified.
- DECIDED: Close the approved plan with a separate documentation commit.
- BLOCKED: None.
- NEXT: None; installed app has not been replaced.

## 2026-11-15 remote support
- DID: Researched Omarchy Agent Orchestrator/Spaces; added SSH receiver, privacy-filtered Python hook sender/installer, machine-isolated read-only sessions and setup guide. Swift validation/session tests, three Python tests, release build and installed receiver integration passed. Updated and relaunched Mac app; matching binary hashes verified.
- DECIDED: Monitor session states only; token totals stay local. Dedicated restricted SSH keys identify each remote machine.
- BLOCKED: Remote PC enrollment and real SSH transport validation await host details; no remote hosts or SSH settings changed.
- NEXT: Connect the user's named PCs when supplied.

## Receiver verification correction
- DID: Installed integration failed; the preceding entry incorrectly recorded it as passed because the shell continued after failure.
- DECIDED: Treat nil at FileHandle EOF as end of input, not read failure.
- BLOCKED: Receiver integration until rebuilt.
- NEXT: Rebuild, reinstall and repeat installed receiver test before closing.

## Receiver fix verified
- DID: Corrected EOF handling; reran all regression tests, rebuilt/reinstalled app, and verified installed receiver accepts EOF-terminated valid input while stripping unsafe fields and rejecting invalid, empty and oversized input. All passed.
- DECIDED: Remote monitoring implementation ready.
- BLOCKED: Actual SSH enrollment awaits machine details.
- NEXT: Connect the remote PCs identified by the user.

## 2026-11-15 agent selection
- DID: Added persisted per-agent visibility menu, show/hide-all actions, filters for sessions/statistics/alerts, and hidden-agent permission hook bypass. Regression tests, release build, shell syntax and installed launch passed; binary hashes match.
- DECIDED: Default preserves existing visibility. Hidden agents continue collecting data so restoring visibility is immediate.
- BLOCKED: Native menu click verification unavailable because CUA access to NotchLite was not authorized; ImageRenderer cannot render the native menu.
- NEXT: None for implementation; user can select agents in Settings.

## 2026-11-15 continuous agent selection
- DID: Replaced the native menu with a persistent in-notch selection panel, scrollable two-column chips, show/hide-all and Done. Release build and existing regression checks passed; installed and relaunched the updated app.
- DECIDED: SwiftUI disabled menu dismissal is unavailable on macOS (compiler-confirmed); use explicit panel state so selection does not dismiss it.
- BLOCKED: Real click verification remains unavailable because CUA was not authorized.
- NEXT: None.
