param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)
$ErrorActionPreference = 'Stop'
$appRoot = Join-Path $Root 'src/DKLock.App'
$smokePath = Join-Path $appRoot 'Smoke/SmokeTestRunner.cs'

$firstRunXaml = Get-ChildItem -Path $appRoot -Recurse -File -Filter 'FirstRunSetupWindow.xaml' | Select-Object -First 1
if ($null -eq $firstRunXaml) { throw 'V9 FirstRunSetupWindow.xaml missing.' }
$xaml = Get-Content $firstRunXaml.FullName -Raw
$m = [regex]::Match($xaml, 'x:Class\s*=\s*"(?<class>[^"]+\.FirstRunSetupWindow)"')
if (-not $m.Success) { throw 'Unable to resolve FirstRunSetupWindow x:Class.' }
$fullClass = $m.Groups['class'].Value
$usingLine = 'using ' + $fullClass.Substring(0, $fullClass.LastIndexOf('.')) + ';'
$content = Get-Content $smokePath -Raw
if ($content -notmatch [regex]::Escape($usingLine)) {
    $n = [regex]::Match($content, '(?m)^namespace\s+')
    if (-not $n.Success) { throw 'Smoke namespace missing.' }
    $content = $content.Substring(0,$n.Index).TrimEnd() + "`r`n$usingLine`r`n`r`n" + $content.Substring($n.Index)
}
$content = [regex]::Replace($content, '(?m)^(?<indent>\s*)onboarding\.Dispatcher\.BeginInvoke\(', '${indent}_ = onboarding.Dispatcher.BeginInvoke(')
$old = '            Require(await WaitUntilAsync(() => applications.Applications.Count == 1, TimeSpan.FromSeconds(8)), "Add application UI command persists a protection policy", lines);'
if ($content.Contains($old)) {
    $replacement = @'
            var applicationAdded = await WaitUntilAsync(() => applications.Applications.Count == 1, TimeSpan.FromSeconds(8));
            if (!applicationAdded)
            {
                lines.Add($"DIAG_APPLICATION_AFTER_CLICK: Busy={applications.Busy}; VmCount={applications.Applications.Count}; Status={applications.StatusMessage}");
            }
            Require(applicationAdded, "Add application UI command persists a protection policy", lines);
'@
    $content = $content.Replace($old,$replacement.TrimEnd())
}
Set-Content $smokePath $content -Encoding utf8

function Print-Contexts([System.IO.FileInfo[]]$Files,[string]$Pattern,[int]$Before=15,[int]$After=70) {
    foreach ($file in $Files) {
        $hits = Select-String -LiteralPath $file.FullName -Pattern $Pattern
        foreach ($hit in $hits) {
            $lines = Get-Content -LiteralPath $file.FullName
            $start=[Math]::Max(0,$hit.LineNumber-1-$Before); $end=[Math]::Min($lines.Count-1,$hit.LineNumber-1+$After)
            Write-Host "--- $($file.FullName) line $($hit.LineNumber) :: $Pattern ---"
            for($i=$start;$i -le $end;$i++){ Write-Host ('{0,4}: {1}' -f ($i+1),$lines[$i]) }
        }
    }
}

$xamls = @(Get-ChildItem $appRoot -Recurse -File -Filter '*.xaml')
$cs = @(Get-ChildItem $appRoot -Recurse -File -Filter '*.cs')
Print-Contexts -Files $xamls -Pattern 'AddApplicationButton' -Before 25 -After 35
Print-Contexts -Files $cs -Pattern 'static\s+void\s+InvokeButton|void\s+InvokeButton' -Before 20 -After 65
Print-Contexts -Files $cs -Pattern 'class\s+ScriptedV9DialogService' -Before 5 -After 120
Print-Contexts -Files $cs -Pattern 'class\s+AsyncRelayCommand' -Before 5 -After 120
Write-Host 'V9 Add Application binding/command diagnostic captured.'
throw 'V9_DIAGNOSTIC_STOP_AFTER_ADD_BINDING_INSPECTION'
