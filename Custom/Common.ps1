# Shared helpers for Windows PowerShell 5.1 and PowerShell 7 on Windows.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$script:CustomRepoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-CustomNative {
    param([string]$FilePath, [string[]]$Arguments)
    & $FilePath @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw ([IO.Path]::GetFileName($FilePath) + ' failed with exit code ' + $LASTEXITCODE) }
}

function Get-CustomTools {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio C++ Build Tools (vswhere.exe not found).' }
    $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsRoot) { throw 'No Visual Studio installation with x64 C++ tools was found.' }
    $msbuild = Join-Path $vsRoot 'MSBuild\Current\Bin\MSBuild.exe'
    $vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
    $kits = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
    $sdk = Get-ChildItem -LiteralPath (Join-Path $kits 'bin') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and
            [version]$_.Name -ge [version]'10.0.26100.0' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\makeappx.exe')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'x64\signtool.exe')) } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $sdk) { throw 'Install Windows SDK 10.0.26100.0 or newer, including MakeAppx and SignTool.' }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) { throw 'Python 3.9+ is required on PATH.' }
    Invoke-CustomNative $python.Source @('-c', 'import sys; assert sys.version_info >= (3,9), "Python 3.9+ is required"')
    foreach ($path in @($msbuild, $vcvars)) {
        if (-not (Test-Path -LiteralPath $path)) { throw ('Required tool was not found: ' + $path) }
    }
    [pscustomobject]@{ MSBuild = $msbuild; VcVars = $vcvars; Python = $python.Source
        MakeAppx = Join-Path $sdk.FullName 'x64\makeappx.exe'
        SignTool = Join-Path $sdk.FullName 'x64\signtool.exe' }
}

function Get-CustomNextVersion {
    param([version[]]$ExistingVersions, [version]$RequestedVersion)
    $highest = @(@([version]'7.0.1870.0') + $ExistingVersions | Sort-Object -Descending)[0]
    if ($RequestedVersion) {
        if ($RequestedVersion.ToString().Split('.').Count -ne 4 -or
            @($RequestedVersion.Major,$RequestedVersion.Minor,$RequestedVersion.Build,$RequestedVersion.Revision |
                Where-Object { $_ -lt 0 -or $_ -gt 65535 }).Count) { throw 'Version requires four integers in the range 0..65535.' }
        if ($RequestedVersion -le $highest) { throw ('Version must be newer than ' + $highest) }
        return $RequestedVersion
    }
    if ($highest.Revision -lt 65535) {
        return [version]::new($highest.Major, $highest.Minor, $highest.Build, $highest.Revision + 1)
    }
    if ($highest.Build -lt 65535) { return [version]::new($highest.Major, $highest.Minor, $highest.Build + 1, 0) }
    throw 'Version range exhausted. Choose a new major/minor version explicitly.'
}

function Get-CustomSourceState {
    $commit = & git -C $script:CustomRepoRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source commit.' }
    $branch = & git -C $script:CustomRepoRoot branch --show-current
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source branch.' }
    $changes = @(& git -C $script:CustomRepoRoot status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source changes.' }
    $diff = @(& git -C $script:CustomRepoRoot diff HEAD --binary)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot fingerprint tracked source changes.' }
    $untracked = @(& git -C $script:CustomRepoRoot -c core.quotepath=false ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot fingerprint new source files.' }
    $parts = @([string]$commit, ($diff -join "`n"))
    foreach ($relative in $untracked) {
        $parts += $relative + ':' + (Get-FileHash -LiteralPath (Join-Path $script:CustomRepoRoot $relative) -Algorithm SHA256).Hash
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace('-','') }
    finally { $hash.Dispose() }
    [pscustomobject]@{ Commit=[string]$commit; Branch=[string]$branch; Dirty=($changes.Count -ne 0); Fingerprint=$fingerprint }
}

function Get-CustomRuntimeHashes {
    param([string]$BinaryDirectory)
    $result = [ordered]@{}
    foreach ($name in @('NanaZip.Core.dll','NanaZip.Codecs.dll','NanaZip.ZS.Codecs.dll')) {
        $result[$name] = (Get-FileHash -LiteralPath (Join-Path $BinaryDirectory $name) -Algorithm SHA256).Hash
    }
    return $result
}

function Assert-CustomRuntimeRecord {
    param([string]$RecordPath, [string]$BinaryDirectory, [string]$SourceFingerprint)
    if (-not (Test-Path -LiteralPath $RecordPath)) { throw 'Runtime compile record missing. Run Custom/Build.ps1 first.' }
    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    if ($record.SourceFingerprint -ne $SourceFingerprint) { throw 'Source changed since compilation. Run Custom/Build.ps1 again.' }
    $actual = Get-CustomRuntimeHashes $BinaryDirectory
    foreach ($name in $actual.Keys) {
        if ($record.RuntimeSHA256.$name -ne $actual[$name]) { throw ('Runtime changed since compilation: ' + $name) }
    }
    return $record
}

function Get-CustomSigningMaterial {
    param([string]$Publisher, [string]$Identity)
    $directory = Join-Path $script:CustomRepoRoot ('.custom-local\Signing\' + $Identity)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $pfxPath = Join-Path $directory 'SigningKey.pfx'
    $passwordPath = Join-Path $directory 'Password.clixml'
    $certPath = Join-Path $directory 'SigningCertificate.cer'
    if ((Test-Path -LiteralPath $pfxPath) -or (Test-Path -LiteralPath $passwordPath)) {
        if (-not ((Test-Path -LiteralPath $pfxPath) -and (Test-Path -LiteralPath $passwordPath) -and
            (Test-Path -LiteralPath $certPath))) { throw 'Incomplete local signing files. Restore the complete signing directory.' }
        $password = Import-Clixml -LiteralPath $passwordPath
    } else {
        $rsa = [Security.Cryptography.RSACng]::new(3072)
        $cert = $null
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $random = New-Object byte[] 32
            $rng.GetBytes($random)
            $plain = [Convert]::ToBase64String($random)
            $password = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new($Publisher, $rsa,
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
            $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
            $eku = [Security.Cryptography.OidCollection]::new()
            $eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3')) | Out-Null
            $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku, $true))
            $cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(2))
            [IO.File]::WriteAllBytes($certPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            $password | Export-Clixml -LiteralPath $passwordPath
            [IO.File]::WriteAllBytes($pfxPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $plain))
        } finally { $plain = $null; $rng.Dispose(); if ($cert) { $cert.Dispose() }; $rsa.Dispose() }
    }
    $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certPath)
    try {
        if ($public.Subject -ne $Publisher) { throw 'Local signing publisher does not match the package.' }
        if ($public.NotAfter -le (Get-Date).AddDays(1)) { throw 'Local signing certificate expires soon. Back up and replace the signing directory.' }
        [pscustomobject]@{ PfxPath=$pfxPath; Password=$password; CertificatePath=$certPath; Thumbprint=$public.Thumbprint }
    } finally { $public.Dispose() }
}
