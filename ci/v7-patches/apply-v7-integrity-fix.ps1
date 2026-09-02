param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'
$installerPath = Join-Path $Root 'tools/DKLock.Setup/InstallerEngine.cs'
if (-not (Test-Path $installerPath)) { throw "V7 installer patch target not found: $installerPath" }
$installerText = Get-Content $installerPath -Raw

# Restore the original strict public payload validator. Static/runtime contracts rely on unlisted files
# being rejected with SetEquals; the setup executable is handled separately by VerifyInstalledDirectory.
$installerText = $installerText.Replace(
    'public static void VerifyDirectory(string root, params string[] allowedExtraFiles)',
    'public static void VerifyDirectory(string root)')
$installerText = [regex]::Replace(
    $installerText,
    '(?m)^[ \t]*var allowedExtras = allowedExtraFiles\.ToHashSet\(StringComparer\.OrdinalIgnoreCase\);\r?\n',
    '',
    1)

$modifiedCondition = @'
        var unexpected = actualFiles.Except(expectedFiles).Except(allowedExtras).FirstOrDefault();
        var missing = expectedFiles.Except(actualFiles).FirstOrDefault();
        if (unexpected is not null || missing is not null)
'@
$strictCondition = @'
        if (!actualFiles.SetEquals(expectedFiles))
'@
$normalized = $installerText -replace "`r`n", "`n"
if ($normalized.Contains($modifiedCondition)) {
    $normalized = $normalized.Replace($modifiedCondition, $strictCondition)
    $installerText = $normalized -replace "`n", "`r`n"
}
elseif ($installerText -notmatch 'if \(!actualFiles\.SetEquals\(expectedFiles\)\)') {
    throw 'Could not restore strict V7 payload file-set condition.'
}

$payloadThrow = '            throw new InvalidDataException($"Payload file set mismatch. unexpected={unexpected ?? "none"}; missing={missing ?? "none"}");'
if ($installerText.Contains($payloadThrow) -and $installerText -notmatch 'var unexpected = actualFiles\.Except\(expectedFiles\)\.FirstOrDefault\(\);') {
    $declarations = "            var unexpected = actualFiles.Except(expectedFiles).FirstOrDefault();`r`n            var missing = expectedFiles.Except(actualFiles).FirstOrDefault();`r`n"
    $installerText = $installerText.Replace($payloadThrow, $declarations + $payloadThrow)
}

# Replace installed-directory helper. The root-level setup EXE cannot self-hash inside the payload
# manifest, so hash it independently, move it outside the payload root for the strict manifest check,
# then restore it in a finally block. Repair launched from the installed setup is already relocated to
# a temp executable, so the installed copy is never the currently executing image here.
$helperPattern = '(?s)    private static void VerifyInstalledDirectory\(string root\).*?\r?\n    }\r?\n\r?\n    private static string Quote\(string value\)'
if ($installerText -notmatch $helperPattern) { throw 'Could not locate V7 VerifyInstalledDirectory helper.' }
$helperReplacement = @'
    private static void VerifyInstalledDirectory(string root)
    {
        const string setupName = "DK_LOCK_V7_Setup.exe";
        var installedSetup = Path.Combine(root, setupName);
        var runningSetup = Environment.ProcessPath ?? throw new InvalidOperationException("Unable to resolve running setup executable for integrity verification.");
        if (!File.Exists(installedSetup)) throw new InvalidDataException("Installed setup executable is missing.");

        using (var source = File.OpenRead(runningSetup))
        using (var installed = File.OpenRead(installedSetup))
        {
            var sourceHash = SHA256.HashData(source);
            var installedHash = SHA256.HashData(installed);
            if (!CryptographicOperations.FixedTimeEquals(sourceHash, installedHash))
                throw new InvalidDataException("Installed setup executable integrity verification failed.");
        }

        var outsidePayload = Path.Combine(Path.GetTempPath(), $"dklock-v7-setup-verify-{Guid.NewGuid():N}.exe");
        File.Move(installedSetup, outsidePayload, overwrite: true);
        try
        {
            PayloadIntegrity.VerifyDirectory(root);
        }
        finally
        {
            if (File.Exists(outsidePayload)) File.Move(outsidePayload, installedSetup, overwrite: true);
        }
    }

    private static string Quote(string value)
'@
$installerText = [regex]::Replace($installerText, $helperPattern, $helperReplacement, 1)

if ($installerText -notmatch 'if \(!actualFiles\.SetEquals\(expectedFiles\)\)') { throw 'Strict SetEquals payload check is missing after patch.' }
if ($installerText -match 'allowedExtraFiles|allowedExtras') { throw 'Allowed-extra payload relaxation unexpectedly remains after patch.' }
if ($installerText -notmatch 'PayloadIntegrity\.VerifyDirectory\(root\);') { throw 'Installed payload strict verification call is missing.' }

Set-Content -Path $installerPath -Value $installerText -Encoding utf8
Write-Host 'Applied V7 strict payload + independent setup integrity verification patch.'
