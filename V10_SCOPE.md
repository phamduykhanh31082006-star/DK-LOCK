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
- Every protected top-level Chrome/Cốc Cốc application window is protected from its first usable UI state, including the browser profile chooser, first-run/no-profile screen, normal browser window, private/incognito window, restore from background, and any later top-level browser window.
- The browser profile chooser is part of the protected application surface. A user must not be able to select or inspect a Chrome/Cốc Cốc profile before DK LOCK authentication succeeds.
- A protected top-level application window is disabled while locked.
- An opaque borderless lock surface covers the exact outer bounds of that protected application window, including the profile-selection screen shown immediately after browser launch.
- The lock surface contains the credential entry; Master Password/PIN is entered on the DK LOCK shield itself, not inside Chrome/Cốc Cốc.
- The protected application is not usable until authentication succeeds. Successful authentication is the only normal path that removes the shield and re-enables the protected window.
- Wrong credentials leave the application fully covered and disabled.
- The shield must follow move, resize, maximize, restore and DPI/monitor changes of the protected window without exposing browser content around its edges.
- The shield is associated with the protected application's z-order and must not remain globally over unrelated applications when the user switches away.
- Protection remains user-mode; no kernel/admin-proof claim is permitted.

## D. Immediate relock after protected application-window lifetime
- V10 adds a RAM-only `UntilApplicationClose` authorization scope.
- Closing the final visible protected top-level window immediately clears that application's authorization.
- Browser background processes do not keep an application authorized.
- Reopening Chrome/Cốc Cốc from an existing background process must show the full-window DK LOCK shield again before profile selection or browser use.
- Multiple windows belonging to the same currently authorized application lifetime may share that RAM-only authorization; once the final protected top-level window closes, the next top-level browser window requires authentication again.

## E. Production foundation and release gate
V10 retains the validated V9 production foundation where relevant: Windows Service, Named Pipe ACL, Master Password/PIN, Quick Lock, onboarding, VI/EN localization, Light/Dark, installer repair/uninstall behavior, persistence, audit logging and exact release integrity.

The desktop protection agent runs for the protected interactive user at logon. Closing the normal DK LOCK control window hides it rather than disabling protection.

Release requires Windows production validation with warnings-as-errors, exact installer hashes, application-window E2E, default-browser discovery, relock after last window closes, repair/uninstall/purge integrity, and focused V0–V9 regression appropriate to the reduced V10 product scope.

Mandatory browser E2E includes:
1. Chrome profile chooser is fully covered before a profile can be selected.
2. Chrome with no existing profile/first-run UI is fully covered.
3. Cốc Cốc equivalent startup/profile UI is fully covered when installed.
4. Wrong Master Password/PIN keeps the complete browser window covered.
5. Correct authentication removes the shield and enables the browser.
6. Maximizing, restoring, moving or resizing the protected browser never exposes an uncovered strip.
7. Closing the final browser window clears authorization even when background browser processes remain alive.
8. Reopening from a surviving background process shows the shield again before profile selection or browser interaction.
9. A second top-level window during the same authorized application lifetime does not create duplicate credential prompts.
10. Quick Lock immediately restores the shield to every protected browser window.
