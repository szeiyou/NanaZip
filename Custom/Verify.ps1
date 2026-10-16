#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DistributionDirectory)
. (Join-Path $PSScriptRoot 'Common.ps1')
$directory = (Resolve-Path -LiteralPath $DistributionDirectory).Path
$python = Get-Command python.exe -ErrorAction Stop | Select-Object -First 1
Invoke-CustomNative $python.Source @((Join-Path $PSScriptRoot 'VerifyPackage.py'), $directory)
$info = Get-Content -LiteralPath (Join-Path $directory 'build-info.json') -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Security
if (-not ('CustomAppxSignature' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'AppxSignature.cs') }
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $directory 'NanaZip-ZipPerformance-Test.cer'))
function Assert-CustomWindowsSignature {
    param([string]$Path)
    $result = [CustomAppxSignature]::Verify($Path)
    # Only the expected untrusted self-signed root is allowed. Hash/SIP errors,
    # expiry and all other policy errors are fatal. CMS signer is checked below.
    if ($result -ne 0 -and $result -ne [Convert]::ToUInt32('800B0109',16)) {
        throw ('Windows package signature verification failed: 0x' + $result.ToString('X8'))
    }
}
function Assert-CustomSignature {
    param([IO.Compression.ZipArchive]$Archive)
    $stream = $Archive.GetEntry('AppxSignature.p7x').Open()
    $buffer = [IO.MemoryStream]::new()
    try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() }
    finally { $stream.Dispose(); $buffer.Dispose() }
    if ([Text.Encoding]::ASCII.GetString($bytes,0,4) -ne 'PKCX') { throw 'Invalid signature prefix.' }
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
    $cms.Decode([byte[]]$bytes[4..($bytes.Length-1)])
    $cms.CheckSignature($true)
    if ($cms.SignerInfos.Count -ne 1 -or $cms.SignerInfos[0].Certificate.Thumbprint -ne $info.CertificateThumbprint) {
        throw 'Unexpected package signer.'
    }
}
try {
    if ($certificate.Thumbprint -ne $info.CertificateThumbprint -or $certificate.Subject -ne $info.Publisher) {
        throw 'Public certificate does not match build information.'
    }
    Assert-CustomWindowsSignature (Join-Path $directory $info.PackageName)
    $bundle = [IO.Compression.ZipFile]::OpenRead((Join-Path $directory $info.PackageName))
    try {
        Assert-CustomSignature $bundle
        $entry = @($bundle.Entries | Where-Object FullName -Like '*.msix')
        if ($entry.Count -ne 1) { throw 'Expected one x64 application package.' }
        $stream = $entry[0].Open()
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory); $memory.Position=0
            $inner = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                Assert-CustomSignature $inner
                $temporaryRoot = Join-Path $script:CustomRepoRoot ('Output\Custom\Tests\sip-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
                $temporaryPath = Join-Path $temporaryRoot 'inner.msix'
                try {
                    [IO.File]::WriteAllBytes($temporaryPath, $memory.ToArray())
                    Assert-CustomWindowsSignature $temporaryPath
                } finally {
                    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
                    Remove-Item -LiteralPath $temporaryRoot
                }
            } finally { $inner.Dispose() }
        } finally { $stream.Dispose(); $memory.Dispose() }
    } finally { $bundle.Dispose() }
} finally { $certificate.Dispose() }
Write-Host 'PASS: Windows SIP content verification, bundle/inner CMS signatures and expected certificate (system trust is separate).'
