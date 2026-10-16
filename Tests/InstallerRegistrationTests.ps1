param([string]$InstallerPath = (Join-Path $PSScriptRoot '..\Custom\Installer\Install.ps1'))
$ErrorActionPreference = 'Stop'
# Run only the real deployment/result block, with OS deployment calls replaced.
# Certificate trust, process management and the rest of the installer never run.
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $InstallerPath).Path,
    [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
$body = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0].Body
$start = @($body.Statements | Where-Object { $_.Extent.Text -match '^Add-AppxPackage\s' })[0].Extent.StartOffset
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $InstallerPath).Path)
$deployment = [scriptblock]::Create($source.Substring($start, $body.Extent.EndOffset - $start - 1))
$info = [pscustomobject]@{ PackageIdentity = 'Test.NanaZip'; Version = '7.0.1870.0' }
$packagePath = 'X:\test-only.msixbundle'
$script:messages = [Collections.Generic.List[string]]::new()
function Write-Host { param($Object, $ForegroundColor); $script:messages.Add([string]$Object) }
function Add-AppxPackage {
    param($Path, [switch]$DeferRegistrationWhenPackagesAreInUse, [switch]$ForceApplicationShutdown, $ErrorAction)
    if (-not $DeferRegistrationWhenPackagesAreInUse -or $ForceApplicationShutdown) {
        throw 'Simulated 0x80073D02: update must support deferred registration while in use.'
    }
    if ($script:scenario -eq 'deployment-failure') { throw 'Simulated deployment failure' }
}
function Get-AppxPackage {
    param($Name, $PackageTypeFilter)
    if ($script:scenario -eq 'missing') { return $null }
    $version = if ($script:scenario -eq 'installed') { '7.0.1870.0' } else { '7.0.1845.0' }
    [pscustomobject]@{ Version = $version; PackageFullName = ('Test.NanaZip_' + $version) }
}
foreach ($scenario in @('deferred', 'installed', 'deployment-failure', 'missing')) {
    $script:scenario = $scenario
    $script:messages.Clear()
    $failure = $null
    try { & $deployment } catch { $failure = $_ }
    $text = $script:messages -join "`n"
    if ($scenario -eq 'deferred') {
        if ($failure) { throw ('Deferred update must be accepted: ' + $failure) }
        if ($text -notmatch 'pending|deferred' -or $text -match '(?m)^Installed:') { throw 'Deferred update was misreported as installed.' }
    } elseif ($scenario -eq 'installed') {
        if ($failure -or $text -notmatch '(?m)^Installed:') { throw 'Registered update was not reported as installed.' }
    } else {
        if (-not $failure -or $text -match '(?m)^Installed:') { throw ('Failure was misreported: ' + $scenario) }
    }
    Write-Output ('PASS: installer registration state: ' + $scenario)
}
