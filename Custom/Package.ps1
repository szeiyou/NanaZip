#Requires -Version 5.1
[CmdletBinding()]
param([version]$Version, [string]$InterfaceDirectory, [switch]$SkipTests)
. (Join-Path $PSScriptRoot 'Common.ps1')
$tools = Get-CustomTools
$source = Get-CustomSourceState
$record = Assert-CustomRuntimeRecord -RecordPath (Join-Path $script:CustomRepoRoot 'Output\Custom\runtime-build.json') `
    -BinaryDirectory (Join-Path $script:CustomRepoRoot 'Output\Binaries\Release\x64') -SourceFingerprint $source.Fingerprint
if (-not $SkipTests -and -not $record.FullRegressionTestsPassed) {
    throw 'Full runtime regression tests have not passed. Run Custom/Build.ps1 first.'
}
$installed = Get-AppxPackage -Name '40174MouriNaruto.NanaZipPreview' | Select-Object -First 1
if (-not $InterfaceDirectory) {
    if (-not $installed) { throw 'Install NanaZip Preview or supply -InterfaceDirectory with its unpacked modern package.' }
    $InterfaceDirectory = $installed.InstallLocation
}
$interfaceRoot = (Resolve-Path -LiteralPath $InterfaceDirectory).Path
$manifest = [xml](Get-Content -LiteralPath (Join-Path $interfaceRoot 'AppxManifest.xml') -Raw)
if ($manifest.Package.Identity.Name -ne '40174MouriNaruto.NanaZipPreview' -or
    $manifest.Package.Identity.ProcessorArchitecture -ne 'x64') { throw 'The interface source must be an x64 NanaZip Preview package.' }
$sourceVersion = [string]$manifest.Package.Identity.Version
$outputRoot = Join-Path $script:CustomRepoRoot 'Output\Custom'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$versions = @([version]$sourceVersion)
if ($installed) { $versions += [version]$installed.Version }
Get-ChildItem -LiteralPath $outputRoot -Directory | Where-Object Name -Match '^\d+\.\d+\.\d+\.\d+$' |
    ForEach-Object { $versions += [version]$_.Name }
$Version = Get-CustomNextVersion -ExistingVersions $versions -RequestedVersion $Version
$buildRoot = Join-Path $outputRoot $Version.ToString()
if (Test-Path -LiteralPath $buildRoot) { throw ('Build directory already exists: ' + $buildRoot) }
$payload = Join-Path $buildRoot 'Payload'
$bundleInput = Join-Path $buildRoot 'BundleInput'
$distribution = Join-Path $buildRoot 'Distribution'
foreach ($directory in @($payload, $bundleInput, $distribution)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$excluded = @('AppxBlockMap.xml','AppxSignature.p7x','AppxMetadata','[Content_Types].xml')
Get-ChildItem -LiteralPath $interfaceRoot | Where-Object Name -NotIn $excluded | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $payload -Recurse
}
$runtimeHashes = [ordered]@{}
foreach ($runtime in @('NanaZip.Core.dll','NanaZip.Codecs.dll','NanaZip.ZS.Codecs.dll','NanaZip.ShellExtension.dll')) {
    $built = Join-Path $script:CustomRepoRoot ('Output\Binaries\Release\x64\' + $runtime)
    if (-not (Test-Path -LiteralPath $built)) { throw ('Build first; missing runtime: ' + $built) }
    Copy-Item -LiteralPath $built -Destination (Join-Path $payload $runtime) -Force
    $runtimeHashes[$runtime] = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash
}
$interfaceHashes = [ordered]@{}
$sourceInterfaceHashes = [ordered]@{}
foreach ($file in @('NanaZip.Modern.FileManager.exe','NanaZip.Universal.Windows.exe','NanaZip.Core.Windows.sfx',
    'NanaZip.Modern.dll','NanaZip.Universal.Console.exe','K7Base.dll','K7User.dll','resources.pri')) {
    $path = Join-Path $interfaceRoot $file
    if (-not (Test-Path -LiteralPath $path)) { throw ('Interface source is incomplete: ' + $file) }
    $sourceInterfaceHashes[$file] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($file -notin @('NanaZip.Modern.FileManager.exe','NanaZip.Universal.Windows.exe','NanaZip.Core.Windows.sfx')) {
        $interfaceHashes[$file] = $sourceInterfaceHashes[$file]
    }
}
if (-not $SkipTests) {
    Invoke-CustomNative $tools.Python @((Join-Path $script:CustomRepoRoot 'Tests\IconResourceTests.py'), $interfaceRoot)
}
$brandingHashes = [ordered]@{}
# Preserve PRI resource keys/qualifiers and package identity, replacing their
# image data with the matching official release assets from this checkout.
$assetRoot = Join-Path $script:CustomRepoRoot 'Assets\PackageAssets'
$assetTarget = Join-Path $payload 'Assets'
$releaseAssets = @(Get-ChildItem -LiteralPath $assetRoot -File)
$existingAssets = @(Get-ChildItem -LiteralPath $assetTarget -File)
if (@(Compare-Object ($releaseAssets.Name | Sort-Object) ($existingAssets.Name | Sort-Object)).Count) {
    throw 'Release and interface image asset names differ; review PRI mappings before branding.'
}
foreach ($asset in $releaseAssets) {
    Copy-Item -LiteralPath $asset.FullName -Destination (Join-Path $assetTarget $asset.Name) -Force
    $brandingHashes['Assets/' + $asset.Name] = (Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256).Hash
}
foreach ($file in @('NanaZip.Modern.FileManager.exe','NanaZip.Universal.Windows.exe','NanaZip.Core.Windows.sfx')) {
    $icon = if ($file -like '*.sfx') { 'NanaZipSfx.ico' } else { 'NanaZip.ico' }
    $path = Join-Path $payload $file
    Invoke-CustomNative $tools.Python @((Join-Path $PSScriptRoot 'SetExecutableIcon.py'), $path,
        (Join-Path $script:CustomRepoRoot ('Assets\' + $icon)))
    $brandingHashes[$file] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
$manifest.Package.Identity.Version = $Version.ToString()
$manifest.Package.Properties.DisplayName = 'NanaZip'
foreach ($element in $manifest.SelectNodes('//*[@DisplayName]')) {
    if ($element.GetAttribute('DisplayName') -like 'NanaZip Preview*') { $element.SetAttribute('DisplayName','NanaZip') }
}
$manifest.Save((Join-Path $payload 'AppxManifest.xml'))
# Check the retained official console with the newly compiled runtime before packing.
if (-not $SkipTests) {
    Invoke-CustomNative $tools.Python @((Join-Path $script:CustomRepoRoot 'Tests\ZipParallelTests.py'),
        (Join-Path $payload 'NanaZip.Universal.Console.exe'))
    $binaryRoot = Join-Path $script:CustomRepoRoot 'Output\Binaries\Release\x64'
    Invoke-CustomNative $tools.Python @((Join-Path $script:CustomRepoRoot 'Tests\ArchivePreviewTests.py'),
        (Join-Path $binaryRoot 'ArchivePreviewProbe.exe'),(Join-Path $payload 'NanaZip.Core.dll'),
        (Join-Path $payload 'NanaZip.Universal.Console.exe'),(Join-Path $binaryRoot 'ShellPreviewTests.exe'),
        (Join-Path $payload 'NanaZip.ShellExtension.dll'))
}
$inner = Join-Path $bundleInput ('NanaZip-Custom-' + $Version + '-x64.msix')
$packageName = 'NanaZip-Custom-' + $Version + '-x64.msixbundle'
$packagePath = Join-Path $distribution $packageName
Invoke-CustomNative $tools.MakeAppx @('pack','/d',$payload,'/p',$inner,'/o')
Invoke-CustomNative $tools.MakeAppx @('bundle','/d',$bundleInput,'/p',$packagePath,'/bv',$Version.ToString(),'/o')
$signing = Get-CustomSigningMaterial -Publisher ([string]$manifest.Package.Identity.Publisher) -Identity ([string]$manifest.Package.Identity.Name)
$secret = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($signing.Password)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secret)
    Invoke-CustomNative $tools.SignTool @('sign','/fd','SHA256','/f',$signing.PfxPath,'/p',$plain,
        '/d','NanaZip Custom ZIP - Local Build',$packagePath)
} finally { $plain = $null; [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secret) }
Copy-Item -LiteralPath $signing.CertificatePath -Destination (Join-Path $distribution 'NanaZip-ZipPerformance-Test.cer')
foreach ($name in @('Install.cmd','Install.ps1','ReadMe.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('Installer\' + $name)) -Destination (Join-Path $distribution $name)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CHANGELOG.md') -Destination $distribution
$finalSource = Get-CustomSourceState
if ($source.Fingerprint -ne $finalSource.Fingerprint) { throw 'Source changed during packaging. Rebuild before publishing.' }
$details = [ordered]@{
    PackageName=$packageName; PackageFormat='MSIXBundle'; Version=$Version.ToString()
    PackageSHA256=(Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
    PackageIdentity=[string]$manifest.Package.Identity.Name; Publisher=[string]$manifest.Package.Identity.Publisher
    CertificateThumbprint=$signing.Thumbprint; SourceCommit=$record.SourceCommit; SourceBranch=$record.SourceBranch
    SourceDirty=$record.SourceDirty; SourceFingerprint=$record.SourceFingerprint; BuiltAtUtc=[DateTime]::UtcNow.ToString('o')
    InterfaceSourceVersion=$sourceVersion; InterfaceSource='Existing modern Preview GUI/resources; shell and archive runtime built from source'
    RuntimeSHA256=$runtimeHashes; PreservedInterfaceSHA256=$interfaceHashes
    SourceInterfaceSHA256=$sourceInterfaceHashes; BrandingSHA256=$brandingHashes
    DisplayName='NanaZip'; Branding='Official release PNG/ICO assets; Preview package identity retained for in-place updates'
    OptimizedCoreSHA256=$runtimeHashes['NanaZip.Core.dll']; RegressionTestsRun=((-not $SkipTests) -and $record.FullRegressionTestsPassed)
    ActualInstallationTested=$false
}
$details | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $distribution 'build-info.json') -Encoding utf8
& (Join-Path $PSScriptRoot 'Verify.ps1') -DistributionDirectory $distribution
if (-not $SkipTests) {
    Invoke-CustomNative $tools.Python @((Join-Path $script:CustomRepoRoot 'Tests\PackageIntegrityTests.py'), $distribution)
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = Join-Path $buildRoot ('NanaZip-Custom-' + $Version + '-Windows-x64.zip')
[IO.Compression.ZipFile]::CreateFromDirectory($distribution, $archive)
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    if ($zip.Entries.Count -ne 7 -or @($zip.Entries | Where-Object FullName -Match '\.pfx$|Password\.clixml$').Count) {
        throw 'Unexpected private material or file count in distribution ZIP.'
    }
    foreach ($entry in $zip.Entries) {
        $stream = $entry.Open()
        try { $stream.CopyTo([IO.Stream]::Null) } finally { $stream.Dispose() }
    }
} finally { $zip.Dispose() }
[ordered]@{ Version=$Version.ToString(); DistributionDirectory=$distribution; ArchivePath=$archive
    PackageSHA256=$details.PackageSHA256; SourceCommit=$details.SourceCommit; SourceDirty=$details.SourceDirty } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'latest.json') -Encoding utf8
Write-Host ('Verified installation files: ' + $distribution) -ForegroundColor Green
Write-Host ('Distribution ZIP: ' + $archive)
Write-Host 'Installation was not performed. Run Install.cmd as administrator when ready.'
