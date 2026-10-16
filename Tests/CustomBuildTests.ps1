$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Custom\Common.ps1')
function Assert-Throws($Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected rejection did not occur.' }
}
if ((Get-CustomNextVersion @([version]'7.0.1870.0') $null).ToString() -ne '7.0.1870.1') { throw 'Version increment failed.' }
if ((Get-CustomNextVersion @([version]'7.0.1900.3',[version]'7.0.1845.0') $null).ToString() -ne '7.0.1900.4') { throw 'Newest installed/generated version was ignored.' }
if ((Get-CustomNextVersion @([version]'7.0.1900.65535') $null).ToString() -ne '7.0.1901.0') { throw 'Revision rollover failed.' }
Assert-Throws { Get-CustomNextVersion @([version]'7.0.1900.0') ([version]'7.0.1870.0') }
Assert-Throws { Get-CustomNextVersion @() ([version]'7.1.0') }
Assert-Throws { Get-CustomNextVersion @() ([version]'7.1.70000.0') }
Write-Output 'PASS: custom versions advance beyond installed and generated packages; invalid/downgrade versions rejected.'
$state = Get-CustomSourceState
$temporary = Join-Path $PSScriptRoot ('..\Output\Custom\Tests\provenance-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
$temporary = (Resolve-Path -LiteralPath $temporary).Path
try {
    foreach ($name in @('NanaZip.Core.dll','NanaZip.Codecs.dll','NanaZip.ZS.Codecs.dll')) {
        [IO.File]::WriteAllText((Join-Path $temporary $name), 'original test bytes')
    }
    $recordPath = Join-Path $temporary 'runtime-build.json'
    [ordered]@{ SourceFingerprint=$state.Fingerprint; RuntimeSHA256=(Get-CustomRuntimeHashes $temporary) } |
        ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding utf8
    Assert-CustomRuntimeRecord $recordPath $temporary $state.Fingerprint | Out-Null
    Assert-Throws { Assert-CustomRuntimeRecord $recordPath $temporary 'changed-source' }
    [IO.File]::AppendAllText((Join-Path $temporary 'NanaZip.Core.dll'), 'modified')
    Assert-Throws { Assert-CustomRuntimeRecord $recordPath $temporary $state.Fingerprint }
    Assert-Throws { Assert-CustomRuntimeRecord (Join-Path $temporary 'missing.json') $temporary $state.Fingerprint }
    Write-Output 'PASS: stale source, replaced DLL and missing compile record are rejected before packaging.'
} finally {
    $safeRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\Output\Custom\Tests')).Path
    if (-not $temporary.StartsWith($safeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
