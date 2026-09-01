# DK LOCK V6 — Smart Protection Scope

Status: **LOCKED SCOPE / DEVELOPMENT STARTED**  
Target version: **6.0.0**  
Baseline: **V5 validated commit `87b327efccf3051665aca65bd4ad83ecc15c6d83`**  
Development branch: `v6-smart-protection`

## 1. V6 objective

V6 turns the separate protection capabilities delivered in V3–V5 into one coordinated **Smart Protection** system.

The core goal is not to add another isolated vault. The goal is to make Application Protection, Folder Protection, Secure Documents and Account Vault react consistently to one global security state and to Windows/session events.

V6 must preserve the architectural rule established in V0–V5:

`UI -> IPC -> Service / Security Core -> State / Policy / Persistence`

The WPF UI must never become the security authority.

## 2. Required V6 capabilities

### 2.1 Global Quick Lock

One Quick Lock command must atomically request a global transition to the locked state.

Quick Lock must:

- clear all in-memory authentication/application sessions;
- re-arm Application Protection policies;
- request protected folders to return to their locked/encrypted state when safe;
- hide/close sensitive Secure Documents views;
- invalidate Account Vault reveal state;
- cancel active sensitive reveal/copy timers;
- clear DK LOCK-managed sensitive clipboard content when it still owns the clipboard value;
- publish one authoritative global state transition;
- write non-secret Activity events;
- remain asynchronous from the UI thread.

Quick Lock must not falsely claim that an arbitrary already-running third-party process has become kernel-isolated. V6 remains user-mode enforcement.

### 2.2 Auto Lock

V6 must support configurable automatic locking based on:

- user inactivity timeout;
- Windows workstation lock event;
- sleep / suspend transition where observable;
- explicit DK LOCK Quick Lock;
- backend/service restart (sessions are never persisted as unlocked sessions).

Supported inactivity choices for V6:

- Off
- 1 minute
- 5 minutes
- 15 minutes
- 30 minutes

Auto Lock settings must persist in SQLite, while active unlock sessions remain RAM-only.

### 2.3 Session Orchestrator

Create one centralized session/lock orchestrator responsible for cross-feature lock behavior.

It must coordinate:

- V3 Application sessions;
- V4 Folder / Secure Documents authentication state;
- V5 Account Vault reveal/authentication state;
- global lock epoch/version;
- lock reason (`Manual`, `Idle`, `WorkstationLock`, `Suspend`, `ServiceRestart`).

No feature is allowed to invent an independent global-unlocked flag.

### 2.4 Windows activity/session monitor

V6 must use event-driven Windows information where available and low-cost idle sampling where Windows does not expose an equivalent event.

Requirements:

- `GetLastInputInfo` or equivalent for inactivity calculation;
- workstation/session transition integration appropriate for the current user-mode service architecture;
- no high-frequency process/idle busy loop;
- idle checks target <= 1 check/second and normally lower;
- cancellation-safe lifecycle and clean service shutdown.

### 2.5 Clipboard Guardian

For Account Vault password copy and other DK LOCK-managed secret copy operations:

- maintain the existing timed clear behavior;
- associate clipboard cleanup with the copied value/version so unrelated clipboard content is not erased;
- Quick Lock triggers immediate cleanup when DK LOCK still owns the sensitive clipboard value;
- no secret content may be written to logs or Activity.

### 2.6 Protection Health state

Dashboard/service state must expose truthful protection health:

- Core Online / Offline;
- Application Protection armed/not armed;
- Folder protection state summary;
- Secure Documents availability;
- Account Vault availability;
- Smart Protection enabled/disabled;
- Auto Lock configuration;
- last global lock reason/time where safe.

Offline service must never render a false `Protected` state.

### 2.7 V6 UI

V6 must integrate into the existing Design System instead of creating a new visual system.

Required UI changes:

- functional Quick Lock action in the shell/dashboard;
- Smart Protection section in Settings;
- inactivity timeout selector;
- workstation-lock auto-lock toggle where applicable;
- clear current protection-health presentation;
- transient user feedback after Quick Lock/Auto Lock without popup spam;
- keyboard/focus behavior consistent with V1–V5;
- all IPC/database/security work asynchronous.

## 3. Data / IPC requirements

### SQLite

Migrate V5 schema forward without destructive reset.

Persist only configuration/history needed for V6, such as:

- Auto Lock enabled state;
- idle timeout setting;
- workstation-lock policy;
- last safe lock metadata if required.

Never persist active authenticated sessions or plaintext secrets.

### IPC V6

Introduce protocol V6 commands/events for:

- Quick Lock;
- Smart Protection settings read/update;
- protection-health snapshot;
- global lock transition subscription/notification where required.

Backward transport compatibility with V2, V3, V4 and V5 clients remains a release gate. Older clients must not be able to invoke V6-only commands.

## 4. Security invariants

V6 is not allowed to weaken the locked baselines.

Mandatory invariants:

1. Master Password/PIN verifier behavior remains protected.
2. V4 encrypted folder/document content remains authenticated-encryption protected.
3. V5 Account Vault fields remain encrypted at rest.
4. Active sessions are RAM-only and cleared by service restart/global Quick Lock.
5. No password/PIN/account secret/document secret appears in Activity or ordinary logs.
6. UI cannot directly mutate protected data or security state outside the service/security contracts.
7. Service offline => UI must fail safe and report offline truthfully.
8. V6 makes no kernel-level, anti-Administrator or tamper-proof claim.

## 5. Performance targets

- Quick Lock UI acknowledgement: immediate visual acknowledgement, backend execution asynchronous.
- Global in-memory session invalidation: target < 100 ms typical.
- Idle monitor CPU usage: effectively negligible when idle.
- IPC health/settings operations: target < 300 ms typical local machine.
- No encryption, SQLite migration, IPC wait or process operation on the WPF UI thread.

Performance numbers are engineering targets, not universal hardware guarantees.

## 6. Explicitly out of scope for V6

The following are reserved for V7 or later unless a defect requires a compatibility fix:

- production installer / MSI / setup wizard;
- permanent Windows Service registration installer workflow;
- code-signing pipeline;
- automatic updater;
- Windows Hello production integration;
- cloud sync / cloud backup;
- remote lock;
- email recovery / online account backend;
- kernel driver / filesystem minifilter;
- WDAC/AppLocker management;
- anti-Administrator tamper guarantees;
- telemetry/analytics backend.

## 7. V6 release gate

V6 can be marked `6.0.0` only after the applicable release suite passes.

Required release evidence:

1. V6 static architecture/security/UX validation.
2. V0 validation regression.
3. V1 UX regression.
4. V2 Core/IPC regression.
5. V3 real-process Application Protection regression.
6. V4 Folder + Secure Documents regression.
7. V5 Account Vault + crypto regression.
8. .NET restore.
9. Production Release build with 0 errors and no accepted new warnings.
10. SQLite migration/idempotency tests.
11. Quick Lock cross-feature integration tests.
12. Auto Lock idle test.
13. Workstation/session event behavior test where runner support permits; deterministic abstraction contract test is mandatory.
14. Clipboard Guardian tests proving unrelated clipboard values are not cleared.
15. Service restart clears sessions and preserves configuration/data.
16. IPC V2–V5 backward compatibility tests.
17. Actual service + WPF online smoke.
18. WPF offline/fail-safe smoke.
19. Runtime evidence review.
20. Self-contained Windows x64 preview publish/launch regression.

Any discovered product/security defect affecting the locked V6 scope must be corrected before V6 is declared complete.

## 8. Definition of Done

V6 is done when a user can configure Smart Protection, use Quick Lock, and rely on DK LOCK to consistently return V3–V5 protected capabilities to one authoritative locked state after manual lock, configured inactivity, relevant Windows session transitions or service restart — without breaking V0–V5 behavior.
