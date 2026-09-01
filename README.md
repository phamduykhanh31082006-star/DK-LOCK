# DK LOCK — V1 UX/UI Foundation

DK LOCK V1 kế thừa toàn bộ nền móng V0 và triển khai **WPF shell + MVVM + Design System + navigation + trạng thái UI trung thực** cho ứng dụng Windows.

## Mục tiêu V1

- Có solution .NET 8 với 6 module đúng dependency direction đã khóa ở V0.
- Có WPF App Shell chạy trong một cửa sổ chính, không tạo “popup maze”.
- Có 7 trang chính: Dashboard, Applications, Folders, Vault, Accounts, Activity, Settings.
- Có Design System dùng resource dictionary tập trung: color, spacing, radius, typography, button, card, input, navigation, status.
- Có navigation dựa trên ViewModel/DataTemplate, không chứa security enforcement trong UI.
- Có presentation state tập trung cho shell và service-health placeholder trung thực.
- Các capability chưa có backend thật được disabled/ghi rõ version dự kiến; không giả vờ “Protected”.
- Có keyboard navigation/hotkey cơ bản và trạng thái focus rõ.
- Có test/validator V1 và Windows runtime smoke-test script.

## Trạng thái capability ở V1

V1 là bản **UX/UI Foundation**, vì vậy Security Engine/Windows Service chưa được triển khai. Dashboard phải hiển thị trạng thái `Protection engine not connected — V1 UI foundation`, không được tuyên bố hệ thống đang bảo vệ máy.

## Build trên Windows

Yêu cầu môi trường phát triển:

- Windows 10/11 x64
- .NET SDK 8.x
- PowerShell 7/Windows PowerShell

Chạy release gate V1:

```powershell
./scripts/test-v1.ps1
```

Script sẽ chạy static/consistency validator, restore/build solution, contract tests và WPF smoke test.

## Release Gate

Theo `DKLOCK_RULES.md` R26–R28: **chỉ được xuất ZIP + report V1 sau khi toàn bộ test áp dụng PASS**. Nếu Windows/.NET runtime test chưa chạy thì V1 chưa được phát hành.
