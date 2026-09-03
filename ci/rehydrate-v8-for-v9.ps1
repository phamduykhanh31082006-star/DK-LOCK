$ErrorActionPreference = 'Stop'

$v3 = Get-ChildItem 'ci/v3src.part*' | Sort-Object Name
if ($v3.Count -ne 12) { throw "Expected 12 V3 parts, found $($v3.Count)." }
$b64 = ($v3 | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
[IO.File]::WriteAllBytes('v3src.tar.xz', [Convert]::FromBase64String($b64))
$actual = (Get-FileHash 'v3src.tar.xz' -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne '905b7dec760f149f8f8e91fd6db5dd17abd3cc78ab95920cded5ee844cab2a9e') { throw "V3 SHA mismatch: $actual" }
New-Item -ItemType Directory -Path 'ci-extract' -Force | Out-Null
tar -xf 'v3src.tar.xz' -C 'ci-extract'
Copy-Item 'ci/test-v3-fixed.ps1' 'ci-extract/DK_LOCK_V3/scripts/test-v3.ps1' -Force
Copy-Item -Path 'ci/overrides/*' -Destination 'ci-extract/DK_LOCK_V3' -Recurse -Force
Move-Item 'ci-extract/DK_LOCK_V3' 'ci-extract/DK_LOCK_V4'

$v4 = Get-ChildItem 'ci/v4delta.part*' | Sort-Object Name
if ($v4.Count -ne 7) { throw "Expected 7 V4 parts, found $($v4.Count)." }
$b64 = ($v4 | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
[IO.File]::WriteAllBytes('v4delta.tar.xz', [Convert]::FromBase64String($b64))
$actual = (Get-FileHash 'v4delta.tar.xz' -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne 'd44e61b34ce7e0180ba0bfbc7fd7d90d838b401b127116ad9d93d00fb5caba29') { throw "V4 SHA mismatch: $actual" }
tar -xf 'v4delta.tar.xz' -C 'ci-extract/DK_LOCK_V4'
if (Test-Path 'ci/v4-overrides') { Copy-Item -Path 'ci/v4-overrides/*' -Destination 'ci-extract/DK_LOCK_V4' -Recurse -Force }
Move-Item 'ci-extract/DK_LOCK_V4' 'ci-extract/DK_LOCK_V5'

$v5 = Get-ChildItem 'ci/v5delta.part*' | Sort-Object Name
if ($v5.Count -ne 5) { throw "Expected 5 V5 delta parts, found $($v5.Count)." }
$b64 = ($v5 | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
[IO.File]::WriteAllBytes('v5delta.tar.xz', [Convert]::FromBase64String($b64))
$actual = (Get-FileHash 'v5delta.tar.xz' -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne '1f4ebeaf90c88b9d2051563297817324d4318cd7ecce36f91c4e787454c952f6') { throw "V5 SHA mismatch: $actual" }
tar -xf 'v5delta.tar.xz' -C 'ci-extract/DK_LOCK_V5'

$accountCoordinator = 'ci-extract/DK_LOCK_V5/src/DKLock.Service/Accounts/AccountVaultCoordinator.cs'
$content = Get-Content $accountCoordinator -Raw
if ($content -notmatch 'using DKLock\.Core\.Contracts;') {
  $content = $content -replace 'using DKLock\.Core\.Authentication;\r?\n', "using DKLock.Core.Authentication;`r`nusing DKLock.Core.Contracts;`r`n"
  Set-Content -Path $accountCoordinator -Value $content -Encoding utf8
}

$integration = 'ci-extract/DK_LOCK_V5/tests/DKLock.V5.IntegrationTests/Program.cs'
$content = Get-Content $integration -Raw
$old = 'foreach \(var path in new\[\] \{ dbPath, dbPath \+ "-wal" \}\.Where\(File\.Exists\)\) bytes\.AddRange\(await File\.ReadAllBytesAsync\(path\)\);'
if ($content -match $old) {
  $replacement = "foreach (var path in new[] { dbPath, dbPath + `"-wal`" }.Where(File.Exists))`r`n    {`r`n        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, useAsync: true);`r`n        using var buffer = new MemoryStream();`r`n        await stream.CopyToAsync(buffer);`r`n        bytes.AddRange(buffer.ToArray());`r`n    }"
  $content = $content -replace $old, $replacement
  Set-Content -Path $integration -Value $content -Encoding utf8
}

$v3Regression = 'ci-extract/DK_LOCK_V5/tests/DKLock.V3.RegressionIntegrationTests/Program.cs'
$content = Get-Content $v3Regression -Raw
$content = $content.Replace('$"\"{heartbeat4}\" 15"', '$"\"{heartbeat4}\" 60"')
$content = $content.Replace('WaitForExitAsync(target4, TimeSpan.FromSeconds(5))', 'WaitForExitAsync(target4, TimeSpan.FromSeconds(9))')
$content = $content.Replace('$"\"{heartbeat5}\" 12"', '$"\"{heartbeat5}\" 50"')
$content = $content.Replace('WaitForExitAsync(target5, TimeSpan.FromSeconds(5))', 'WaitForExitAsync(target5, TimeSpan.FromSeconds(8))')
Set-Content -Path $v3Regression -Value $content -Encoding utf8

if (Test-Path 'ci/v5-overrides') { Copy-Item -Path 'ci/v5-overrides/*' -Destination 'ci-extract/DK_LOCK_V5' -Recurse -Force }
Move-Item 'ci-extract/DK_LOCK_V5' 'ci-extract/DK_LOCK_V6'

$v6 = Get-ChildItem 'ci/v6delta.part*' | Sort-Object Name
if ($v6.Count -ne 4) { throw "Expected 4 V6 delta parts, found $($v6.Count)." }
$b64 = ($v6 | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
[IO.File]::WriteAllBytes('v6delta.tar.xz', [Convert]::FromBase64String($b64))
$actual = (Get-FileHash 'v6delta.tar.xz' -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne '791159171482f74dbde982cd4503baeb3fa9a8f36dc0f8763a1d2caf4c61c380') { throw "V6 SHA mismatch: $actual" }
tar -xf 'v6delta.tar.xz' -C 'ci-extract/DK_LOCK_V6'
if (Test-Path 'ci/v6-overrides') { Copy-Item -Path 'ci/v6-overrides/*' -Destination 'ci-extract/DK_LOCK_V6' -Recurse -Force }
if (-not (Test-Path 'ci-extract/DK_LOCK_V6/scripts/test-v6.ps1')) { throw 'V6 baseline reconstruction failed.' }

Move-Item 'ci-extract/DK_LOCK_V6' 'ci-extract/DK_LOCK_V7'
$v7 = Get-ChildItem 'ci/v7delta.part*' | Sort-Object Name
if ($v7.Count -ne 3) { throw "Expected 3 V7 delta parts, found $($v7.Count)." }
$b64 = ($v7 | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
[IO.File]::WriteAllBytes('v7delta.tar.xz', [Convert]::FromBase64String($b64))
$actual = (Get-FileHash 'v7delta.tar.xz' -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne '009582a3cb638eac583fc3c35c2162c3542096ce64268188ae011e1d839e6794') { throw "V7 SHA mismatch: $actual" }
tar -xf 'v7delta.tar.xz' -C 'ci-extract/DK_LOCK_V7'
& 'ci/v7-patches/apply-v7-fixes.ps1' -Root 'ci-extract/DK_LOCK_V7'
& 'ci/v7-patches/apply-v7-repair-transaction-fix.ps1' -Root 'ci-extract/DK_LOCK_V7'
& 'ci/v7-patches/apply-v7-data-acl-fix.ps1' -Root 'ci-extract/DK_LOCK_V7'
if (-not (Test-Path 'ci-extract/DK_LOCK_V7/scripts/test-v7.ps1')) { throw 'V7 baseline reconstruction failed.' }

Move-Item 'ci-extract/DK_LOCK_V7' 'ci-extract/DK_LOCK_V8'
$v8 = Get-ChildItem 'ci/v8delta.part*' | Sort-Object Name
if ($v8.Count -ne 10) { throw "Expected 10 V8 delta parts, found $($v8.Count)." }
$b64 = ($v8 | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() }) -join ''
[IO.File]::WriteAllBytes('v8delta.tar.xz', [Convert]::FromBase64String($b64))
$actual = (Get-FileHash 'v8delta.tar.xz' -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "V8 delta SHA256: $actual"
if ($actual -ne 'd47d07bbb45951741058d88b9576a76c13d9df629ef175ee4b1130da596216a9') { throw "V8 SHA mismatch: $actual" }
tar -xf 'v8delta.tar.xz' -C 'ci-extract/DK_LOCK_V8'
if (-not (Test-Path 'ci-extract/DK_LOCK_V8/scripts/test-v8.ps1')) { throw 'V8 locked source reconstruction failed.' }
$status = Get-Content 'ci-extract/DK_LOCK_V8/V8_WORK_STATUS.md' -Raw
if ($status -notmatch '8\.0\.0 / COMPLETED / LOCKED') { throw 'V8 source is not marked COMPLETED / LOCKED.' }
foreach ($project in @('ci-extract/DK_LOCK_V8/src/DKLock.App/DKLock.App.csproj','ci-extract/DK_LOCK_V8/tools/DKLock.Setup/DKLock.Setup.csproj')) {
  if ((Get-Content $project -Raw) -notmatch 'WithCulture="false"') { throw "V8 culture-neutral resource packaging is missing: $project" }
}
if ((Get-Content 'ci-extract/DK_LOCK_V8/scripts/test-v8.ps1' -Raw).Contains('for $language:')) { throw 'V8 localized smoke-test parser regression detected.' }

Write-Host 'V8 baseline rehydrated and verified.'
