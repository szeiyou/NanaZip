. (Join-Path $PSScriptRoot '..\Custom\Common.ps1')
$tools = Get-CustomTools
$testRoot = Join-Path $script:CustomRepoRoot 'Output\Custom\Tests'
$binaryRoot = Join-Path $script:CustomRepoRoot 'Output\Binaries\Release\x64'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$probe = Join-Path $binaryRoot 'ArchivePreviewProbe.exe'
$batch = Join-Path $testRoot 'BuildArchivePreviewProbe.cmd'
$lines = @('@echo off', ('call "' + $tools.VcVars + '" >nul'), 'if errorlevel 1 exit /b 1',
    ('cl /nologo /EHsc /std:c++17 /utf-8 /W4 /DUNICODE /D_UNICODE "' +
        (Join-Path $PSScriptRoot 'ArchivePreviewProbe.cpp') + '" "' +
        (Join-Path $script:CustomRepoRoot 'NanaZip.UI.Modern\ArchivePreview.cpp') +
        '" /Fo:"' + $testRoot + '\\" /Fe:"' + $probe + '" /link ole32.lib oleaut32.lib'),
    'exit /b %errorlevel%')
[IO.File]::WriteAllLines($batch, $lines, [Text.Encoding]::Default)
Invoke-CustomNative 'cmd.exe' @('/d','/c',$batch)
$shellProbe = Join-Path $binaryRoot 'ShellPreviewTests.exe'
$shellLines = @('@echo off', ('call "' + $tools.VcVars + '" >nul'), 'if errorlevel 1 exit /b 1',
    ('cl /nologo /EHsc /std:c++17 /utf-8 /W4 "' + (Join-Path $PSScriptRoot 'ShellPreviewTests.cpp') +
        '" /Fo:"' + (Join-Path $testRoot 'ShellPreviewTests.obj') + '" /Fe:"' + $shellProbe +
        '" /link ole32.lib shell32.lib uuid.lib'), 'exit /b %errorlevel%')
[IO.File]::WriteAllLines($batch, $shellLines, [Text.Encoding]::Default)
Invoke-CustomNative 'cmd.exe' @('/d','/c',$batch)
Invoke-CustomNative $tools.Python @((Join-Path $PSScriptRoot 'ArchivePreviewTests.py'),$probe,
    (Join-Path $binaryRoot 'NanaZip.Core.dll'),(Join-Path $binaryRoot 'NanaZip.Universal.Console.exe'),
    $shellProbe,(Join-Path $binaryRoot 'NanaZip.ShellExtension.dll'))
