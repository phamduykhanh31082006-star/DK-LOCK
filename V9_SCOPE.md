# DK LOCK V9 — Functional Productization & UX Rebuild

Version target: **9.0.0**  
Baseline: **DK LOCK V8.0.0 COMPLETED / RELEASED / LOCKED**  
Development branch: `v9-functional-productization`

## Locked objective

V9 is not a feature-count release. V9 exists to make the product **usable end to end from the real WPF interface**. A backend capability does not count as complete unless a normal user can discover it, invoke it, understand its state and complete its workflow from the UI.

## V9-A — Functional UI reliability

1. Fix command lifecycle and `CanExecuteChanged` propagation for Applications, Folders, Secure Documents, Accounts and Settings.
2. A command that becomes available after refresh/connection/busy state must visibly re-enable without reopening the page.
3. Protection actions are unavailable while the security service is offline and re-enable when it reconnects.
4. Remove eager page refresh races during app construction; initialize the visible experience only after the connection coordinator has started.
5. Every async action has a deterministic success/failure state and never leaves the primary action permanently disabled.

## V9-B — First-run product setup

Fresh installs must follow this order:

`Security Service -> Master Password -> optional PIN -> Smart Protection -> Ready`

Requirements:
- service readiness is checked before security setup;
- master password is a first-class setup step rather than an accidental side effect of adding a protected item;
- PIN is optional and can be configured later;
- Smart Protection defaults are visible and editable during setup;
- no plaintext credential is persisted by the UI;
- existing V8 users with an already-configured master password are not forced through fresh-install onboarding.

## V9-C — Real user workflows

The release gate must exercise actual UI commands through the Windows application for:

1. Add an application protection policy.
2. Add a protected folder and reach encrypted-at-rest state.
3. Add an encrypted Secure Documents copy.
4. Add an encrypted Account Vault entry.
5. Configure PIN after master-password setup.
6. Execute Quick Lock from the main window.

Backend-only IPC tests remain required, but they no longer substitute for UI workflow tests.

## V9-D — Design System V2

1. Light theme is the default for visual clarity.
2. A coherent dark theme remains available in Settings.
3. Theme choice is remembered per Windows account and is non-sensitive.
4. Product XAML may not hard-code presentation colors outside theme resource dictionaries.
5. Sidebar, content canvas, cards, inputs, dialogs, disabled states and status badges use the same token system.
6. Empty states explain the next action instead of presenting blank pages.
7. Internal implementation labels such as V2/V3/V4/V5/V6/V8 are removed from end-user copy.

## V9-E — Release validation standard

V9 cannot be marked COMPLETE / RELEASED / LOCKED until all of the following pass on the exact Windows release source:

- V9 static architecture/UX validation;
- full locked functional regression for V0–V8 behavior;
- warnings-as-errors production build with **0 warnings / 0 errors**;
- V9 command-state regression;
- bilingual first-run setup runtime smoke;
- real UI functional E2E against the Windows Service;
- application/folder/document/account encrypted-data checks;
- service/IPC/ACL/repair/uninstall/purge regression;
- light and dark theme runtime screenshots;
- exact final installer SHA-256 verification;
- release metadata/report/runtime evidence consistency.

## Security boundary

V9 keeps the V8 security architecture and does not introduce kernel-level claims. Protection remains coordinated by the Windows Service and user-mode components. Sensitive unlock sessions remain RAM-only. Folder/document/account confidentiality remains cryptographic where already provided by the locked baseline.

## Release artifact convention

The end-user delivery artifact will be **`DK_LOCK_V9_USER_INSTALLER.zip`**, containing the exact validated `DK_LOCK_V9_Setup.exe`, checksum and release metadata. The raw EXE is still produced for integrity validation but ZIP is the primary user download.
