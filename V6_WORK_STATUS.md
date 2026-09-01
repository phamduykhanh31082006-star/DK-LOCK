# DK LOCK V6 — Work Status

Version target: `6.0.0`  
Current stage: **6.0.0-rc.1 / DEVELOPMENT**  
Branch: `v6-smart-protection`  
Baseline: V5 validated commit `87b327efccf3051665aca65bd4ad83ecc15c6d83`

## Locked objective

Build Smart Protection as a coordination layer over the already validated V3 Application Protection, V4 Folder/Secure Documents and V5 Account Vault capabilities.

## Implementation order

1. V5 baseline rehydration/compatibility harness for V6 CI.
2. SQLite V6 settings migration.
3. Global lock reason/state contracts.
4. SmartProtectionSettings contracts.
5. Global Session/Lock Orchestrator.
6. Idle/activity monitor abstraction + Windows implementation.
7. Workstation/session transition adapter.
8. Clipboard Guardian ownership/version behavior.
9. IPC protocol V6 commands/events while retaining V2–V5 compatibility.
10. Quick Lock integration across Application/Folder/Documents/Accounts.
11. Settings + Dashboard UX integration.
12. V6 contract/integration tests.
13. V0–V5 regression suite.
14. Windows service + WPF runtime smoke.
15. Preview Portable regression and release evidence.

## Release state

- Scope locked: YES
- V5 baseline accepted: YES
- V6 branch created: YES
- V6 implementation: STARTED
- Windows V6 release gate: PENDING
- V6 release locked: NO

V6 must not be labeled complete until the locked Definition of Done in `V6_SCOPE.md` is satisfied.
