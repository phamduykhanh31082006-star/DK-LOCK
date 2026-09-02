param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'

$pipeFactory = Join-Path $Root 'src/DKLock.Infrastructure/NamedPipeSecurityFactory.cs'
if (-not (Test-Path $pipeFactory)) {
    throw "V7 patch target not found: $pipeFactory"
}

$content = Get-Content $pipeFactory -Raw
if ($content -notmatch '#pragma warning disable CA1416') {
    $reason = '// V7: this factory is intentionally Windows-only because production named-pipe ACLs use Windows access-control APIs.'
    $content = "#pragma warning disable CA1416`r`n$reason`r`n" + $content.TrimEnd() + "`r`n#pragma warning restore CA1416`r`n"
    Set-Content -Path $pipeFactory -Value $content -Encoding utf8
}

Write-Host 'Applied V7 Windows-only named-pipe ACL analyzer annotation patch.'
