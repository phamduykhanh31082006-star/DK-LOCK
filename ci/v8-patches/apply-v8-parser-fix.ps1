param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$script = Join-Path $Root 'scripts/test-v8.ps1'
if (-not (Test-Path $script)) { throw "V8 test script not found: $script" }

$content = Get-Content $script -Raw
$content = $content.Replace('for $language: $($setupUi.ExitCode)', 'for ${language}: $($setupUi.ExitCode)')
$content = $content.Replace('for $language: $($ui.ExitCode)', 'for ${language}: $($ui.ExitCode)')
Set-Content -Path $script -Value $content -Encoding utf8

$verified = Get-Content $script -Raw
if ($verified.Contains('for $language:')) { throw 'V8 parser fix did not remove all ambiguous language variable references.' }

foreach ($projectRelative in @('src/DKLock.App/DKLock.App.csproj', 'tools/DKLock.Setup/DKLock.Setup.csproj')) {
    $project = Join-Path $Root $projectRelative
    if (-not (Test-Path $project)) { throw "V8 localization project not found: $project" }
    $projectContent = Get-Content $project -Raw
    $projectContent = $projectContent.Replace('EmbeddedResource Include="Resources\Strings.en-US.json" LogicalName=', 'EmbeddedResource Include="Resources\Strings.en-US.json" WithCulture="false" LogicalName=')
    $projectContent = $projectContent.Replace('EmbeddedResource Include="Resources\Strings.vi-VN.json" LogicalName=', 'EmbeddedResource Include="Resources\Strings.vi-VN.json" WithCulture="false" LogicalName=')
    Set-Content -Path $project -Value $projectContent -Encoding utf8
    $projectVerified = Get-Content $project -Raw
    if (($projectVerified | Select-String -Pattern 'WithCulture="false"' -AllMatches).Matches.Count -lt 2) {
        throw "V8 localization resources are not forced into the main assembly: $projectRelative"
    }
}

Write-Host 'Applied V8 PowerShell parser fix and culture-neutral embedded-resource packaging fix.'
