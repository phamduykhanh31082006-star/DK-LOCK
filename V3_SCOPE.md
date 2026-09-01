# DK LOCK V3 — Application Protection Scope & Definition of Done

## 1. Mục tiêu khóa của V3
V3 biến Core Architecture V2 thành **Application Protection khả dụng thực tế trong user-mode**: người dùng có thể thêm ứng dụng Windows `.exe`, bật/tắt protection, DK LOCK phát hiện process mới theo event, đối chiếu policy ở backend, tạm dừng process được bảo vệ, yêu cầu xác thực và chỉ tiếp tục process khi xác thực hợp lệ.

V3 phải kế thừa trực tiếp V0–V2: UI không tự khóa process, Service/Security Core vẫn là nguồn state chuẩn, policy + credential được persistence trong SQLite, IPC có version/timeout, mọi hành động bảo mật ghi Activity và trạng thái Offline phải trung thực.

> **Security boundary:** V3 là enforcement user-mode dành cho MVP/desktop privacy. Nó không tuyên bố kernel-level, tamper-proof hoặc ngăn được Administrator/sophisticated bypass. Process có thể thực thi trong một khoảng rất ngắn trước khi event được nhận và suspend. Hard enforcement bằng WDAC/AppLocker/kernel driver không thuộc V3.

## 2. In Scope
- Application policy CRUD: add/remove/enable/disable protected `.exe` và persistence qua restart.
- Safety validation: từ chối DK LOCK binaries và danh sách Windows critical processes.
- Event-driven Windows process-start monitor; không busy polling.
- Policy cache in-memory cho hot path; SQLite không được query mỗi process event.
- User-mode enforcement coordinator: detect → match policy → suspend → challenge → authenticate → resume/terminate.
- Challenge timeout/cancel cleanup để không để process treo vô hạn.
- Master Password bắt buộc trước khi bật protection lần đầu.
- Optional local PIN 4–8 chữ số dùng cùng authentication boundary.
- Password/PIN verifier dùng Argon2id + random salt; không lưu plaintext secret.
- Authentication throttling/cooldown sau nhiều lần sai; không log secret.
- App-scoped unlock sessions: Once / 5 minutes / 15 minutes / Until DK LOCK locks/restarts.
- Sessions chỉ nằm trong memory; restart/explicit lock xóa session.
- IPC V3 tương thích ngược V2; V2 client/state/activity contract tiếp tục hoạt động.
- Applications UI V3: chọn `.exe`, danh sách policy, enable/disable/remove, protection/backend status, empty/error/loading state.
- Unlock Window V3: app name/path, password/PIN, session duration, wrong-password/cooldown feedback.
- UI challenge subscription bất đồng bộ; không block UI thread.
- Activity events: policy changes, process detected, process suspended/resumed/terminated, auth success/failure/cooldown, session granted/cleared.
- WPF online/offline smoke, challenge render evidence, process enforcement test target, service restart regression.
- V0 + V1 + V2 regression gates tiếp tục PASS.

## 3. Out of Scope
- Folder Protection / Secure Documents.
- Vault / Account Vault.
- Windows Hello.
- Quick Lock / Auto Lock UX hoàn chỉnh (chỉ có internal session-clear primitive để V6 dùng lại).
- Service registration/installer/self-contained end-user setup.
- Kernel driver, WDAC, AppLocker, IFEO, code-injection/hooking.
- Anti-admin tamper protection.
- Cloud, remote lock, email recovery.
- Encryption-at-rest cho tài liệu/Vault (V4+).

## 4. Architecture invariants của V3
1. **Service owns enforcement.** UI chỉ gửi command/credential và hiển thị challenge/result.
2. **Single Source of Truth giữ nguyên.** UI không tự set `Protected` nếu Service chưa xác nhận.
3. **Event-driven process monitor.** Không tạo vòng scan liên tục để tìm process.
4. **Hot-path policy cache.** Process event không query SQLite trực tiếp.
5. **Fail-safe truthful state.** Service offline → UI `Protection offline`; không giữ badge xanh stale.
6. **Credential secrecy.** Không persist/log plaintext; verifier = Argon2id(salt, parameters).
7. **Ephemeral sessions.** Session token không persist DB và phải mất sau Service restart/lock-all.
8. **Challenge cleanup.** Timeout/cancel phải resume hoặc terminate theo policy rõ ràng; không để zombie/suspended process vô hạn.
9. **Backward IPC compatibility.** V2 ping/state/activity vẫn dùng được trong V3 service.
10. **No security overclaim.** V3 UI/docs không dùng từ ngữ ngụ ý kernel/tamper-proof execution prevention.

## 5. Locked V3 protection flow

```text
Windows process start event
        ↓
ProcessStartMonitor
        ↓
PolicyCache lookup
        ↓
No match/session valid ─────→ allow
        ↓ match + locked
ProcessController.Suspend
        ↓
ProtectionChallenge
        ↓ IPC V3 event
DKLock.App Unlock Window
        ↓
AuthenticationService
   ┌────┴────┐
 fail       pass
  ↓           ↓
keep       SessionManager
suspended      ↓
/cooldown   Resume process
  ↓           ↓
timeout     Activity + State
terminate
```

## 6. Performance / UX targets
- UI command acknowledgement: immediate visual feedback, async backend work.
- Policy cache lookup: target < 5 ms typical.
- Process-start event → enforcement action: target < 500 ms typical on supported desktop; CI acceptance < 1500 ms to avoid runner flakiness.
- Unlock Window shown after challenge: target < 300 ms after UI receives challenge.
- Idle service: event-driven, no process scanning loop.
- WPF navigation/functionality from V1 remains responsive and regression PASS.

## 7. Definition of Done — LOCKED TARGET 3.0.0
- [ ] V3 Impact Analysis + traceability complete.
- [ ] V3 source has no unfinished placeholder in in-scope features.
- [ ] SQLite schema migrates V2 schema `1 → 2` idempotently without losing existing data.
- [ ] Policy CRUD persists across service restart.
- [ ] Safety policy rejects DK LOCK + Windows critical executables.
- [ ] Windows process-start monitor detects CI test target via event.
- [ ] Policy cache match works without DB query on event hot path.
- [ ] Protected test process is suspended when no valid session exists.
- [ ] Correct Master Password resumes process.
- [ ] Wrong credential does not resume process and is activity-logged without secret.
- [ ] Auth throttling/cooldown works.
- [ ] Optional PIN enrollment/verification works when enabled.
- [ ] Once / 5m / 15m / Until Lock session semantics pass tests.
- [ ] Service restart clears sessions but retains policies/credentials.
- [ ] Challenge timeout cleans up process deterministically.
- [ ] V2 IPC ping/state/activity remains compatible.
- [ ] V3 policy/auth/challenge IPC commands pass contract tests.
- [ ] Applications UI CRUD + truthful backend state works on Windows.
- [ ] WPF Unlock Window renders and challenge path passes smoke test.
- [ ] Service offline UI/fail-safe regression PASS.
- [ ] V0 regression PASS.
- [ ] V1 regression PASS.
- [ ] V2 regression PASS.
- [ ] `dotnet restore` Windows PASS.
- [ ] `dotnet build -c Release` Windows PASS with 0 errors; release-warning budget reviewed.
- [ ] V3 unit/contract/integration tests PASS.
- [ ] Actual Windows process enforcement E2E PASS.
- [ ] Runtime evidence text + PNG saved.
- [ ] ZIP + report are created **only after** every applicable gate above PASS.
- [ ] Final ZIP integrity + SHA-256 PASS.

## 8. Release rule
V3 stays `3.0.0-rc.*` until every applicable Definition of Done item is PASS. If one required gate fails, **không xuất `DK_LOCK_V3.zip` và không tuyên bố V3 LOCKED**.
