# DK LOCK V10 — Application Locker Refocus — LOCKED SCOPE

## Objective
V10 reduces DK LOCK to one primary product job: protect selected Windows applications when the computer is temporarily shared with another person. V10 keeps the V9 production foundation but retires unrelated vault/content surfaces from the product experience.

## A. Focused product surface
- Product navigation: Dashboard, Applications, Activity, Settings.
- Folder Protection, Secure Documents and Account Vault are retired from the V10 product surface and service capability surface.
- Existing V9 encrypted data is preserved on disk for rollback/migration; V10 must never silently delete it.

## B. Browser-first defaults
- Google Chrome and Cốc Cốc are first-class default protected applications when installed.
- Discovery covers machine installations and the original interactive user's LocalAppData profile.
- An explicit user removal is respected and is not undone on every service restart.

## C. Full-window application lock
- Protection is window-aware, not process-start-only.
- A protected top-level application window is disabled while locked.
- An opaque borderless lock surface covers the exact bounds of that protected application window.
- The lock surface contains the credential entry; the protected application is not usable until authentication succeeds.
- Wrong credentials leave the application covered and disabled.
- The shield is associated with the protected application's z-order and must not remain globally over unrelated applications when the user switches away.
- Protection remains user-mode; no kernel/admin-proof claim is permitted.

## D. Immediate relock after application-window lifetime
- V10 adds a RAM-only `UntilApplicationClose` authorization scope.
- Closing the final visible protected top-level window immediately clears that application's authorization.
- Browser background processes do not keep an application authorized.
- Reopening a browser window from an existing background process must lock again.
- Generic V10 relock is defined by protected top-level application-window lifetime, not an internal browser tab; internal tab lifecycle is browser-specific and outside the generic application-lock contract.

## E. Production foundation and release gate
V10 retains the validated V9 production foundation where relevant: Windows Service, Named Pipe ACL, Master Password/PIN, Quick Lock, onboarding, VI/EN localization, Light/Dark, installer repair/uninstall behavior, persistence, audit logging and exact release integrity.

The desktop protection agent runs for the protected interactive user at logon. Closing the normal DK LOCK control window hides it rather than disabling protection.

Release requires Windows production validation with warnings-as-errors, exact installer hashes, application-window E2E (including a browser-like background-process/reopen scenario), default-browser discovery, relock after last window closes, repair/uninstall/purge integrity, and focused V0–V9 regression appropriate to the reduced V10 product scope.
