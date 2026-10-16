$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\Custom\Installer\Install.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $path).Path,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw $errors[0] }
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-IdleNanaZipShellHosts'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$package=[pscustomobject]@{InstallLocation='C:\Test\NanaZip_1.0.0.0_x64__test'}
$script:stopped=@()
function Get-CimInstance {
    param($ClassName,$Filter,$ErrorAction)
    $classId=if($script:mode -eq 'other-class'){'17696EAC-9568-4CF5-BB8C-82515AAD6C09'}else{'469D94E9-6AF4-4395-B396-99B1308F8CE5'}
    [pscustomobject]@{ProcessId=4242;CommandLine=('"'+$env:windir+'\System32\dllhost.exe" /Processid:{'+$classId+'}')}
}
function Get-Process {
    param($Id,$Name,$ErrorAction)
    if ($Name) {
        if ($script:mode -eq 'running-job') { [pscustomobject]@{Id=1234} }
        return
    }
    if ($Id -eq $PID) { return [pscustomobject]@{SessionId=7} }
    $session=if($script:mode -eq 'other-session'){8}else{7}
    $executable=if($script:mode -eq 'other-executable'){'C:\Other\dllhost.exe'}else{Join-Path $env:windir 'System32\dllhost.exe'}
    $module=if($script:mode -eq 'other-package'){'C:\OtherPackage\NanaZip.ShellExtension.dll'}else{Join-Path $package.InstallLocation 'NanaZip.ShellExtension.dll'}
    $process=[pscustomobject]@{Id=4242;SessionId=$session;Path=$executable;Modules=@([pscustomobject]@{FileName=$module});Handle=0}
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {param($timeout) return $true}
    return $process
}
function Stop-Process { param($InputObject,[switch]$Force,$ErrorAction); $script:stopped += $InputObject.Id }
foreach($mode in @('idle','running-job','other-class','other-session','other-executable','other-package')) {
    $script:mode=$mode; $script:stopped=@()
    Stop-IdleNanaZipShellHosts $package
    if($mode -eq 'idle') { if($script:stopped.Count -ne 1 -or $script:stopped[0] -ne 4242){throw 'Idle verified host was not released.'} }
    elseif($script:stopped.Count){throw ('Unrelated or busy host was stopped: '+$mode)}
    Write-Output ('PASS: shell host release scope: '+$mode)
}
