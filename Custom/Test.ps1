#Requires -Version 5.1
[CmdletBinding()]
param([string]$BinaryDirectory = (Join-Path $PSScriptRoot '..\Output\Binaries\Release\x64'))
. (Join-Path $PSScriptRoot 'Common.ps1')
$tools = Get-CustomTools
$binaryRoot = (Resolve-Path -LiteralPath $BinaryDirectory).Path
$console = Join-Path $binaryRoot 'NanaZip.Universal.Console.exe'
$core = Join-Path $binaryRoot 'NanaZip.Core.dll'
foreach ($file in @($console, $core)) {
    if (-not (Test-Path -LiteralPath $file)) { throw ('Build first; missing: ' + $file) }
}
$testRoot = Join-Path $script:CustomRepoRoot 'Output\Custom\Tests'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Invoke-CustomNative 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',
    (Join-Path $script:CustomRepoRoot 'Tests\CustomBuildTests.ps1'))
Invoke-CustomNative 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',
    (Join-Path $script:CustomRepoRoot 'Tests\InstallerRegistrationTests.ps1'))
Invoke-CustomNative 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',
    (Join-Path $script:CustomRepoRoot 'Tests\InstallerShellHostTests.ps1'))
Invoke-CustomNative $tools.Python @((Join-Path $script:CustomRepoRoot 'Tests\ZipParallelTests.py'), $console)
$fixture = Join-Path $testRoot 'callback-fixture.zip'
Invoke-CustomNative $tools.Python @((Join-Path $PSScriptRoot 'MakeTestArchive.py'), $fixture)
$testExe = Join-Path $binaryRoot 'ZipCallbackTests.exe'
$batch = Join-Path $testRoot 'BuildCallbackTests.cmd'
$lines = @('@echo off', ('call "' + $tools.VcVars + '" >nul'), 'if errorlevel 1 exit /b 1',
    ('cl /nologo /EHsc /std:c++17 /W4 "' + (Join-Path $script:CustomRepoRoot 'Tests\ZipCallbackTests.cpp') +
        '" /Fo:"' + (Join-Path $testRoot 'ZipCallbackTests.obj') + '" /Fe:"' + $testExe + '" /link ole32.lib'),
    'exit /b %errorlevel%')
[IO.File]::WriteAllLines($batch, $lines, [Text.Encoding]::Default)
Invoke-CustomNative 'cmd.exe' @('/d','/c',$batch)
Invoke-CustomNative $testExe @($core, $fixture)
& (Join-Path $script:CustomRepoRoot 'Tests\BuildArchivePreviewTests.ps1')
Write-Host 'PASS: custom build tests, installer states, ZIP integration and direct archive callbacks.'
