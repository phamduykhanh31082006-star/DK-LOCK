# DK LOCK V7 — Production Release

Target: `7.0.0`
Baseline: validated DK LOCK V6.0.0 Smart Protection release (`2e4163acf59e8772085d243863b7694c70a527c1`).

## Locked objective

Turn the validated V3–V6 protection stack into an end-user Windows release that can be installed, upgraded, repaired and uninstalled without requiring a .NET SDK/runtime or manual service startup.

V7 is primarily a **productionization and deployment** release. It must not reopen the cryptographic or protection architecture of V3–V6 unless a regression/security defect requires it.

## Required scope

1. One end-user Windows x64 installer executable (`DK_LOCK_V7_Setup.exe`).
2. Self-contained WPF application and self-contained protection service inside the installer payload.
3. Real Windows Service mode with SCM lifecycle handling, automatic startup and restart recovery policy.
4. Production data path under `%ProgramData%\DK LOCK`; application binaries under `%ProgramFiles%\DK LOCK`.
5. Installer owner binding: service IPC pipe is ACL-restricted to LocalSystem, Administrators and the Windows user SID that installed DK LOCK.
6. Embedded payload SHA-256 manifest; installer verifies every payload file before install and every installed file after copy.
7. Staged install/upgrade with rollback of application binaries if installation fails.
8. Upgrade/repair preserves `%ProgramData%` security database, policies, encrypted folders/vault/account metadata and settings.
9. Uninstall removes service, binaries, shortcuts and uninstall registry entry; encrypted/user data is preserved by default, with explicit purge mode available.
10. Start Menu integration and Windows uninstall registration.
11. Product/file version metadata fixed to `7.0.0` and deterministic Release builds.
12. No test-shutdown capability in the production installed service command line.
13. Signing pipeline is supported. If no certificate is configured, the release must say `UNSIGNED`; it must never claim a signature that does not exist.
14. External SHA-256 checksum and release manifest for the installer.
15. V0–V6 full regression plus actual install → service start → WPF online → repair/upgrade → uninstall Windows E2E.
16. Release artifact ZIP/EXE integrity validation before handoff.

## Security boundary

V7 improves deployment, local IPC isolation, binary integrity checks and service lifecycle hardening. It remains a user-mode application and does **not** claim kernel isolation, anti-Administrator guarantees, minifilter enforcement, Secure Boot trust, or tamper-proof protection against an administrator with full machine control.

The final installer may be unsigned when no commercial code-signing certificate is supplied. In that case Windows SmartScreen/Publisher warnings are expected; SHA-256 and payload integrity checks provide integrity evidence but do not replace publisher identity/authenticode trust.

## Out of scope

- kernel driver / filesystem minifilter;
- anti-Administrator guarantees;
- cloud sync / remote lock;
- automatic network updater or background download service;
- Microsoft Store/MSIX distribution;
- purchasing or fabricating a code-signing certificate;
- new password-manager features or new cryptographic formats.

## Definition of Done

V7 is complete only when:

- V0–V6 regressions pass unchanged or with explicitly version-adapted validators;
- Release build is clean with warnings treated as errors;
- service console mode remains regression-compatible and Windows SCM mode is proven on a Windows runner;
- setup `--verify-only` passes against its embedded manifest;
- a silent real install registers and starts the service;
- the installed WPF app reaches the service and passes online smoke;
- service recovery/startup configuration and owner-bound pipe ACL contract are verified;
- repair/reinstall preserves a seeded ProgramData marker/data state;
- uninstall removes service/binaries/registry state and preserves data by default;
- explicit purge mode removes test data in the release gate;
- final installer and tested source artifacts are uploaded with SHA-256 digests;
- the user is told exactly which file to download and its size.
