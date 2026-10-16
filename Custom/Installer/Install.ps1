$ErrorActionPreference = 'Stop'
function Stop-IdleNanaZipShellHosts {
    param($InstalledPackage)
    if (-not $InstalledPackage) { return }
    if (@(Get-Process -Name 'NanaZip.Modern.FileManager','NanaZip.Universal.Windows','NanaZip.Universal.Console' -ErrorAction SilentlyContinue).Count) {
        Write-Host 'NanaZip jobs/windows are running; leave shell hosts untouched and defer the update.'
        return
    }
    $session = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    $expectedExecutable = Join-Path $env:windir 'System32\dllhost.exe'
    $expectedModule = Join-Path $InstalledPackage.InstallLocation 'NanaZip.ShellExtension.dll'
    try {
        $hosts = @(Get-CimInstance Win32_Process -Filter "Name='dllhost.exe'" -ErrorAction Stop)
    } catch {
        Write-Host 'Could not inspect NanaZip shell hosts; use deferred registration.'
        return
    }
    foreach ($candidate in $hosts) {
        # The shell COM class is shared with the package manifest. Match the
        # whole command, session, executable and loaded package module, not a PID.
        if ($candidate.CommandLine -notmatch '(?i)^"?[^"\r\n]*\\dllhost\.exe"?\s+/Processid:\{469D94E9-6AF4-4395-B396-99B1308F8CE5\}\s*$') { continue }
        try {
            $process = Get-Process -Id $candidate.ProcessId -ErrorAction Stop
            if ($process.SessionId -ne $session -or $process.Path -ne $expectedExecutable) { continue }
            if (-not @($process.Modules | Where-Object FileName -EQ $expectedModule).Count) { continue }
            # Recheck active jobs immediately before releasing the idle COM host.
            if (@(Get-Process -Name 'NanaZip.Modern.FileManager','NanaZip.Universal.Windows','NanaZip.Universal.Console' -ErrorAction SilentlyContinue).Count) { return }
            $null = $process.Handle
            Write-Host ('Releasing idle NanaZip context-menu host: ' + $process.Id)
            Stop-Process -InputObject $process -Force -ErrorAction Stop
            if (-not $process.WaitForExit(5000)) { Write-Host 'Shell host did not exit yet; update may remain pending.' }
        } catch {
            Write-Host ('Could not release NanaZip shell host ' + $candidate.ProcessId + '; update may remain pending. ' + $_.Exception.Message)
        }
    }
}
$logPath = Join-Path $PSScriptRoot ('Install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Start-Transcript -LiteralPath $logPath -Force | Out-Null
try {
    $info = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-info.json') -Raw | ConvertFrom-Json
    $packagePath = Join-Path $PSScriptRoot $info.PackageName
    $certificatePath = Join-Path $PSScriptRoot 'NanaZip-ZipPerformance-Test.cer'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Please right-click Install.cmd and select Run as administrator.'
    }
    if ((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash -ne $info.PackageSHA256) {
        throw 'Package hash mismatch. Installation cancelled.'
    }
    # A Store bundle cannot be updated by a standalone MSIX (0x80073CF3).
    if ([IO.Path]::GetExtension($packagePath) -ne '.msixbundle') {
        throw 'This update must be an MSIXBundle. Do not use the earlier standalone MSIX.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        $entry = $archive.GetEntry('AppxMetadata/AppxBundleManifest.xml')
        if (-not $entry) { throw 'Bundle manifest is missing.' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { $manifest = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($manifest.Bundle.Identity.Name -ne $info.PackageIdentity -or
            $manifest.Bundle.Identity.Version -ne $info.Version) {
            throw 'Unexpected bundle identity or version.'
        }
    } finally { $archive.Dispose() }
    $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($certificatePath)
    try {
        if ($certificate.Thumbprint -ne $info.CertificateThumbprint -or
            $certificate.Subject -ne [string]$manifest.Bundle.Identity.Publisher) {
            throw 'Unexpected signing certificate. Installation cancelled.'
        }
    } finally { $certificate.Dispose() }
    if (Get-Process -Name 'NanaZip.Modern.FileManager','NanaZip.Universal.Windows','NanaZip.Universal.Console' -ErrorAction SilentlyContinue) {
        Write-Host 'NanaZip is running. The update will wait until its current tasks and windows have closed.'
    }
    $current = Get-AppxPackage -Name $info.PackageIdentity | Select-Object -First 1
    if ($current -and [version]$current.Version -gt [version]$info.Version) {
        throw 'A newer NanaZip is installed. This installer will not downgrade it.'
    }
    Write-Host 'Installing the bundle signing certificate into LocalMachine/TrustedPeople.'
    Import-Certificate -FilePath $certificatePath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
    Write-Host ('Updating NanaZip with MSIXBundle ' + $info.Version + ' ...')
    if ($current -and [version]$current.Version -lt [version]$info.Version) { Stop-IdleNanaZipShellHosts $current }
    Add-AppxPackage -Path $packagePath -DeferRegistrationWhenPackagesAreInUse -ErrorAction Stop
    $installed = Get-AppxPackage -Name $info.PackageIdentity | Select-Object -First 1
    $bundle = Get-AppxPackage -Name $info.PackageIdentity -PackageTypeFilter Bundle | Select-Object -First 1
    if ($installed -and $bundle -and [string]$installed.Version -eq $info.Version -and
        [string]$bundle.Version -eq $info.Version) {
        Write-Host ('Installed: ' + $installed.PackageFullName) -ForegroundColor Green
        Write-Host 'The modern interface and Explorer integration are preserved.'
    } elseif ($installed -and $bundle -and [version]$installed.Version -le [version]$info.Version -and
        [version]$bundle.Version -le [version]$info.Version) {
        Write-Host 'Update accepted; registration is pending (deferred while NanaZip resources are in use).' -ForegroundColor Yellow
        Write-Host ('Currently registered: ' + $installed.PackageFullName)
        Write-Host 'Finish current archive jobs, close NanaZip, then open it again to apply the update.'
        Write-Host 'If background resources remain in use, sign out and sign in, or restart Windows when convenient.'
        Write-Host ('Do not uninstall NanaZip. Run this installer again afterwards to confirm version ' + $info.Version + '.')
    } else {
        throw 'The expected application and bundle versions were not registered. Keep this installation log.'
    }
} catch {
    $failure = $_
    Write-Host ('Installation failed: ' + $failure.ToString()) -ForegroundColor Red
    $detailText = [string]$failure.ErrorDetails.Message
    if ($detailText) { Write-Host $detailText }
    $activity = [regex]::Match($detailText + ' ' + $failure.ToString(),
        '(?i)ActivityI[dD][^0-9a-f]*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if ($activity.Success) {
        try {
            Get-AppPackageLog -ActivityID $activity.Groups[1].Value -ErrorAction Stop |
                ForEach-Object { $_.ToXml() } | Out-File -LiteralPath ($logPath + '.events.xml') -Encoding utf8
            Write-Host ('Deployment event details: ' + $logPath + '.events.xml')
        } catch { Write-Host ('Could not export deployment events: ' + $_.Exception.Message) }
    }
    Write-Host ('Keep this log: ' + $logPath)
    throw $failure
} finally { Stop-Transcript | Out-Null }
