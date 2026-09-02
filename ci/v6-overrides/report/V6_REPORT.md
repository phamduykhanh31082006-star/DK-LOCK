# DK LOCK V6 — Release Report

Status: **6.0.0 LOCKED / RELEASE VALIDATED**

V6 delivers Smart Protection as the coordination layer across V3 Application Protection, V4 Folder/Secure Documents and V5 Account Vault.

Validated capabilities:

- Global Quick Lock clears RAM-only sessions, re-arms application protection and returns protected folders to encrypted-at-rest state.
- Auto Lock supports idle timeout, workstation lock and suspend signals.
- One authoritative global lock epoch/reason is exposed by service state.
- Clipboard Guardian clears DK LOCK-managed secrets without clearing unrelated clipboard content.
- Protection Health reports truthful service/module state.
- SQLite schema 5 migration is idempotent and preserves V3–V5 data.
- IPC V6 keeps V2–V5 transport compatibility while rejecting V6-only commands from older clients.
- WPF Dashboard/Settings/Quick Lock UX is integrated and service-offline behavior remains fail-safe.
- Self-contained Windows x64 Preview Portable publishes and launch-smokes successfully.

Release evidence requires the final Windows pipeline to pass all 20 release gates. V6 remains user-mode protection and does not claim kernel isolation or anti-Administrator guarantees.
