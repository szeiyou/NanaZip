param([Parameter(Mandatory=$true)][string]$InterfaceDirectory, [string]$ShellDllPath)
. (Join-Path $PSScriptRoot '..\Custom\Common.ps1')
if (-not $ShellDllPath) { $ShellDllPath = Join-Path $script:CustomRepoRoot 'Output\Binaries\Release\x64\NanaZip.ShellExtension.dll' }
$tools = Get-CustomTools
$testRoot = Join-Path $script:CustomRepoRoot 'Output\Custom\Tests'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$probe = Join-Path $testRoot 'ShellExtractionProbe.exe'
$capture = Join-Path $testRoot 'ShellGuiCapture.exe'
$source = Join-Path $PSScriptRoot 'ShellExtractionProbe.cpp'
$batch = Join-Path $testRoot 'BuildShellExtractionTests.cmd'
$lines = @('@echo off', ('call "' + $tools.VcVars + '" >nul'), 'if errorlevel 1 exit /b 1',
    ('cl /nologo /EHsc /std:c++17 /utf-8 /W4 "' + $source + '" /Fo:"' + $testRoot + '\ShellExtractionProbe.obj" /Fe:"' + $probe + '" /link ole32.lib shell32.lib uuid.lib'),
    'if errorlevel 1 exit /b 1',
    ('cl /nologo /EHsc /std:c++17 /utf-8 /W4 /DSHELL_GUI_CAPTURE "' + $source + '" /Fo:"' + $testRoot + '\ShellGuiCapture.obj" /Fe:"' + $capture + '" /link /SUBSYSTEM:WINDOWS'),
    'exit /b %errorlevel%')
[IO.File]::WriteAllLines($batch, $lines, [Text.Encoding]::Default)
Invoke-CustomNative 'cmd.exe' @('/d','/c',$batch)
Invoke-CustomNative $tools.Python @((Join-Path $PSScriptRoot 'ShellExtractionTests.py'), $InterfaceDirectory, $ShellDllPath, $probe, $capture)
