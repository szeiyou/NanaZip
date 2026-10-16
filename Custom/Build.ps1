#Requires -Version 5.1
[CmdletBinding()]
param([version]$Version, [string]$InterfaceDirectory, [switch]$Rebuild, [switch]$SkipTests)
. (Join-Path $PSScriptRoot 'Common.ps1')
$tools = Get-CustomTools
$logs = Join-Path $script:CustomRepoRoot 'Output\Custom\Logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$target = if ($Rebuild) { 'Rebuild' } else { 'Build' }
Push-Location $script:CustomRepoRoot
try {
    foreach ($project in @('NanaZip.Core\NanaZip.Core.vcxproj', 'NanaZip.Universal\NanaZip.Universal.Console.vcxproj',
        'NanaZip.UI.Modern\NanaZip.ShellExtension.vcxproj')) {
        Write-Host ('Building ' + $project)
        $logName = [IO.Path]::GetFileNameWithoutExtension($project) + '.binlog'
        Invoke-CustomNative $tools.MSBuild @($project, '/restore', ('/t:' + $target), '/m', '/v:minimal',
            '/p:Configuration=Release', '/p:Platform=x64', '/p:PreferredToolArchitecture=x64', '/p:NanaZipShellStandalone=true',
            ('/bl:' + (Join-Path $logs $logName)))
    }
    $state = Get-CustomSourceState
    [ordered]@{ SourceCommit=$state.Commit; SourceBranch=$state.Branch; SourceDirty=$state.Dirty
        SourceFingerprint=$state.Fingerprint; CompiledAtUtc=[DateTime]::UtcNow.ToString('o')
        RuntimeSHA256=(Get-CustomRuntimeHashes (Join-Path $script:CustomRepoRoot 'Output\Binaries\Release\x64'))
        FullRegressionTestsPassed=$false } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $script:CustomRepoRoot 'Output\Custom\runtime-build.json') -Encoding utf8
    if (-not $SkipTests) {
        & (Join-Path $PSScriptRoot 'Test.ps1')
        $recordPath = Join-Path $script:CustomRepoRoot 'Output\Custom\runtime-build.json'
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        $record.FullRegressionTestsPassed = $true
        $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding utf8
    }
    & (Join-Path $PSScriptRoot 'Package.ps1') -Version $Version -InterfaceDirectory $InterfaceDirectory -SkipTests:$SkipTests
} finally { Pop-Location }
