[CmdletBinding()]
param(
    [string]$Amd64Image = 'aosc-os_wsl_20261017_amd64.wsl',
    [string]$Arm64Image = 'aosc-os_wsl_20261017_arm64.wsl',
    [string]$ExpectedVersion = '14.0.0',
    [string]$OutputRoot = 'artifacts\release',
    [switch]$SkipClean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root = $PSScriptRoot
$ManifestPath = Join-Path $Root 'AOSCOSLauncher-Appx\AOSCOS.appxmanifest'
$TimestampUrl = 'http://timestamp.acs.microsoft.com'
$GitHubAssetLimit = 2GB

function Resolve-ReleasePath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Get-Sha256Hash {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw "Visual Studio locator not found: $vswhere"
    }

    $msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild Microsoft.VisualStudio.Workload.NativeDesktop -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    if (-not $msbuild) {
        throw 'MSBuild with the Native Desktop workload was not found.'
    }

    return $msbuild
}

function Find-SdkTools {
    $sdkBinRoots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

    foreach ($sdkBin in $sdkBinRoots) {
        $versions = Get-ChildItem -LiteralPath $sdkBin -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending

        foreach ($version in $versions) {
            $toolDirectory = Join-Path $version.FullName 'x64'
            $makeAppx = Join-Path $toolDirectory 'makeappx.exe'
            $signTool = Join-Path $toolDirectory 'signtool.exe'
            if ((Test-Path -LiteralPath $makeAppx -PathType Leaf) -and (Test-Path -LiteralPath $signTool -PathType Leaf)) {
                return [pscustomobject]@{
                    Version = $version.Name
                    MakeAppx = $makeAppx
                    SignTool = $signTool
                }
            }
        }
    }

    throw 'makeappx.exe and signtool.exe were not found in an installed Windows SDK.'
}

function Get-RootfsVersion {
    param(
        [string]$TarPath,
        [string]$ImagePath
    )

    $osRelease = & $TarPath -xOf $ImagePath './etc/os-release' 2>$null
    if ($LASTEXITCODE -ne 0) {
        $osRelease = & $TarPath -xOf $ImagePath 'etc/os-release' 2>$null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read /etc/os-release from $ImagePath."
    }

    $match = [regex]::Match(($osRelease -join "`n"), '(?m)^VERSION_ID="?([^"\r\n]+)"?$')
    if (-not $match.Success) {
        throw "VERSION_ID was not found in /etc/os-release in $ImagePath."
    }

    return $match.Groups[1].Value.Trim()
}

function Test-ReleaseImage {
    param(
        [string]$ImagePath,
        [string]$TarPath
    )

    $image = Resolve-ReleasePath $ImagePath
    $checksumPath = "$image.sha256sum"
    if (-not (Test-Path -LiteralPath $image -PathType Leaf)) {
        throw "WSL image not found: $image"
    }
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw "Checksum file not found: $checksumPath"
    }

    $checksumLine = Get-Content -LiteralPath $checksumPath |
        Where-Object { $_ -match '\S' } |
        Select-Object -First 1
    $checksumMatch = [regex]::Match($checksumLine, '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$')
    if (-not $checksumMatch.Success) {
        throw "Invalid SHA-256 checksum file: $checksumPath"
    }

    $expectedHash = $checksumMatch.Groups[1].Value.ToLowerInvariant()
    $actualHash = Get-Sha256Hash -Path $image
    if ($actualHash -cne $expectedHash) {
        throw "SHA-256 mismatch for $image. Expected $expectedHash but got $actualHash."
    }

    $version = Get-RootfsVersion -TarPath $TarPath -ImagePath $image
    Write-Host "Verified $image (SHA-256, VERSION_ID $version)"

    return [pscustomobject]@{
        Path = $image
        Hash = $expectedHash
        Length = (Get-Item -LiteralPath $image).Length
        Version = $version
    }
}

function Set-ManifestVersion {
    param([string]$Version)

    $manifest = [System.IO.File]::ReadAllText($ManifestPath)
    $pattern = '(<Identity\b[^>]*\bVersion=")[^"]+(")'
    if (-not [regex]::IsMatch($manifest, $pattern)) {
        throw "Could not locate the package identity version in $ManifestPath."
    }

    $replacement = '${1}' + $Version + '${2}'
    $updated = [regex]::Replace($manifest, $pattern, $replacement, 1)
    [System.IO.File]::WriteAllText($ManifestPath, $updated, (New-Object System.Text.UTF8Encoding($true)))
}

function Copy-StagedImage {
    param(
        [pscustomobject]$Image,
        [string]$Platform
    )

    $platformDirectory = Join-Path $Root $Platform
    $destination = Join-Path $platformDirectory 'install.tar.gz'
    New-Item -ItemType Directory -Path $platformDirectory -Force | Out-Null
    Copy-Item -LiteralPath $Image.Path -Destination $destination -Force

    $stagedHash = Get-Sha256Hash -Path $destination
    if ($stagedHash -cne $Image.Hash) {
        throw "Staged image hash mismatch: $destination"
    }
}

function Build-ArchitecturePackage {
    param(
        [string]$Platform,
        [string]$BuildRoot,
        [string]$MSBuild,
        [string]$SdkVersion
    )

    $packageDirectory = Join-Path $BuildRoot $Platform
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null

    $commonArguments = @(
        '/t:Build',
        '/m',
        '/nr:true',
        '/p:Configuration=Release',
        "/p:Platform=$Platform",
        "/p:WindowsTargetPlatformVersion=$SdkVersion",
        "/p:SolutionDir=$Root\\"
    )

    Write-Host "Building Release|$Platform launcher"
    Invoke-Native -FilePath $MSBuild -Arguments (@((Join-Path $Root 'AOSCOSLauncher\AOSCOSLauncher.vcxproj')) + $commonArguments)

    Write-Host "Packaging Release|$Platform"
    $appxArguments = $commonArguments + @(
        '/p:AppxBundle=Never',
        '/p:AppxPackageSigningEnabled=False',
        '/p:BuildAppxUploadPackageForUap=False',
        '/p:GenerateTemporaryStoreCertificate=False',
        '/p:GenerateTestArtifacts=False',
        "/p:AppxPackageDir=$packageDirectory"
    )
    Invoke-Native -FilePath $MSBuild -Arguments (@((Join-Path $Root 'AOSCOSLauncher-Appx\AOSCOSLauncher-Appx.vcxproj')) + $appxArguments)

    $packages = @(Get-ChildItem -LiteralPath $packageDirectory -Filter '*.appx' -File -Recurse)
    if ($packages.Count -ne 1) {
        throw "Expected one $Platform .appx in $packageDirectory, found $($packages.Count)."
    }

    return $packages[0].FullName
}

function Test-AppxPackage {
    param(
        [string]$PackagePath,
        [string]$Architecture,
        [string]$Version,
        [pscustomobject]$Image
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        foreach ($requiredEntry in @('AppxManifest.xml', 'aoscos.exe', 'install.tar.gz')) {
            if ($null -eq $archive.GetEntry($requiredEntry)) {
                throw "$PackagePath does not contain $requiredEntry."
            }
        }

        $manifestEntry = $archive.GetEntry('AppxManifest.xml')
        $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
        try {
            [xml]$manifest = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if ($manifest.Package.Identity.Version -cne $Version) {
            throw "$PackagePath has version $($manifest.Package.Identity.Version), expected $Version."
        }
        if ($manifest.Package.Identity.ProcessorArchitecture -ine $Architecture) {
            throw "$PackagePath has architecture $($manifest.Package.Identity.ProcessorArchitecture), expected $Architecture."
        }

        $installEntry = $archive.GetEntry('install.tar.gz')
        if ($installEntry.Length -ne $Image.Length) {
            throw "$PackagePath install.tar.gz length differs from the verified WSL image."
        }

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $installStream = $installEntry.Open()
        try {
            $installHash = [System.BitConverter]::ToString($sha256.ComputeHash($installStream)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $installStream.Dispose()
            $sha256.Dispose()
        }
        if ($installHash -cne $Image.Hash) {
            throw "$PackagePath install.tar.gz hash differs from the verified WSL image."
        }
    }
    finally {
        $archive.Dispose()
    }

    Write-Host "Verified package contents: $PackagePath"
}

function Test-Bundle {
    param(
        [string]$BundlePath,
        [string]$Version,
        [string[]]$Architectures,
        [switch]$GitHubAsset
    )

    if ($GitHubAsset -and (Get-Item -LiteralPath $BundlePath).Length -ge $GitHubAssetLimit) {
        throw "$BundlePath is not strictly smaller than 2 GiB."
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
    try {
        $bundleManifestEntry = $archive.GetEntry('AppxMetadata/AppxBundleManifest.xml')
        if ($null -eq $bundleManifestEntry) {
            throw "$BundlePath has no AppxBundleManifest.xml."
        }
        if ($null -eq $archive.GetEntry('AppxSignature.p7x')) {
            throw "$BundlePath has no AppxSignature.p7x."
        }

        $reader = New-Object System.IO.StreamReader($bundleManifestEntry.Open())
        try {
            [xml]$manifest = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $packages = @($manifest.SelectNodes("//*[local-name()='Package']") | Where-Object { $_.Type -eq 'Application' })
        $actualArchitectures = @($packages | ForEach-Object { $_.Architecture.ToLowerInvariant() } | Sort-Object)
        $expectedArchitectures = @($Architectures | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        if (($actualArchitectures -join ',') -cne ($expectedArchitectures -join ',')) {
            throw "$BundlePath architectures are $($actualArchitectures -join ','), expected $($expectedArchitectures -join ',')."
        }

        foreach ($package in $packages) {
            if ($package.Version -cne $Version) {
                throw "$BundlePath contains package version $($package.Version), expected $Version."
            }
            if ($null -eq $archive.GetEntry($package.FileName)) {
                throw "$BundlePath does not contain $($package.FileName)."
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    Write-Host "Verified bundle structure: $BundlePath"
}

function Get-PublisherCertificate {
    param([string]$Publisher)

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
    $store.Open('ReadOnly')
    try {
        $now = Get-Date
        return @($store.Certificates |
            Where-Object { $_.Subject -ceq $Publisher -and $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -ge $now } |
            Sort-Object NotBefore -Descending |
            Select-Object -First 1)
    }
    finally {
        $store.Close()
    }
}

function Initialize-StoreAssociation {
    param(
        [string]$MSBuild,
        [string]$SdkVersion
    )

    [xml]$manifest = [System.IO.File]::ReadAllText($ManifestPath)
    $publisher = $manifest.Package.Identity.Publisher
    $identityName = $manifest.Package.Identity.Name
    $publisherDisplayName = $manifest.Package.Properties.PublisherDisplayName
    $displayName = $manifest.Package.Properties.DisplayName
    $associationPath = Join-Path $Root 'AOSCOSLauncher-Appx\Package.StoreAssociation.xml'

    if (-not (Test-Path -LiteralPath $associationPath -PathType Leaf)) {
        $escapedPublisher = [System.Security.SecurityElement]::Escape($publisher)
        $escapedPublisherDisplayName = [System.Security.SecurityElement]::Escape($publisherDisplayName)
        $escapedIdentityName = [System.Security.SecurityElement]::Escape($identityName)
        $escapedDisplayName = [System.Security.SecurityElement]::Escape($displayName)
        $association = @"
<?xml version="1.0" encoding="utf-8"?>
<StoreAssociation xmlns="http://schemas.microsoft.com/appx/2010/storeassociation">
  <Publisher>$escapedPublisher</Publisher>
  <PublisherDisplayName>$escapedPublisherDisplayName</PublisherDisplayName>
  <GeneratePackageHash>http://www.w3.org/2001/04/xmlenc#sha256</GeneratePackageHash>
  <SupportedLocales>
    <Language Code="en" InMinimumRequirementSet="true" />
    <Language Code="en-us" InMinimumRequirementSet="true" />
    <Language Code="zh" InMinimumRequirementSet="true" />
    <Language Code="zh-cn" InMinimumRequirementSet="true" />
  </SupportedLocales>
  <ProductReservedInfo>
    <MainPackageIdentityName>$escapedIdentityName</MainPackageIdentityName>
    <ReservedNames>
      <ReservedName>$escapedDisplayName</ReservedName>
    </ReservedNames>
  </ProductReservedInfo>
  <AccountPackageIdentityNames>
    <MainPackageIdentityName>$escapedIdentityName</MainPackageIdentityName>
  </AccountPackageIdentityNames>
  <PackageInfoList LandingUrl="https://dev.windows.com/dashboard/Application?appId=9NMDF21NV65Z" />
</StoreAssociation>
"@
        [System.IO.File]::WriteAllText($associationPath, $association, (New-Object System.Text.UTF8Encoding($false)))
    }

    $certificate = Get-PublisherCertificate -Publisher $publisher
    if ($null -eq $certificate) {
        Write-Host "Generating a publisher-matching signing certificate for $publisher"
        $arguments = @(
            (Join-Path $Root 'AOSCOSLauncher-Appx\AOSCOSLauncher-Appx.vcxproj'),
            '/t:_ValidateSigningCertificate',
            '/p:Configuration=Release',
            '/p:Platform=x64',
            "/p:WindowsTargetPlatformVersion=$SdkVersion",
            "/p:SolutionDir=$Root\\",
            '/p:AppxPackage=true',
            '/p:BuildAppxUploadPackageForUap=true',
            '/p:GenerateTemporaryStoreCertificate=true',
            '/p:AppxPackageSigningEnabled=true'
        )
        Invoke-Native -FilePath $MSBuild -Arguments $arguments
        $certificate = Get-PublisherCertificate -Publisher $publisher
    }

    if ($null -eq $certificate) {
        throw "No usable private-key certificate was found for $publisher."
    }

    Write-Host "Using signing certificate $($certificate.Thumbprint) for $publisher"
    return $certificate.Thumbprint
}

function Test-PackageSignature {
    param(
        [string]$PackagePath,
        [string]$SignTool,
        [string]$Thumbprint
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $SignTool verify /pa /sha1 $Thumbprint $PackagePath 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -eq 0) {
        Write-Host "Verified trusted signature: $PackagePath"
        return
    }

    $expectedTrustFailure = $output.Contains('A certificate chain processed, but terminated in a root') -and
        $output.Contains('certificate which is not trusted by the trust provider') -and
        $output.Contains('Number of errors: 1')
    $integrityFailure = $output -match '(?i)(file hash|hash mismatch|invalid signature|signature is not valid)'
    if (-not $expectedTrustFailure -or $integrityFailure) {
        $output | Out-Host
        throw "Signature verification failed for $PackagePath."
    }

    Write-Host "Verified signature integrity and signer; the self-signed root is not system-trusted: $PackagePath"
}

function New-SignedBundle {
    param(
        [string]$Name,
        [string[]]$Packages,
        [string[]]$Architectures,
        [string]$Version,
        [string]$BundleDirectory,
        [string]$MakeAppx,
        [string]$SignTool,
        [switch]$GitHubAsset
    )

    $inputDirectory = Join-Path $BundleDirectory "input\$Name"
    New-Item -ItemType Directory -Path $inputDirectory -Force | Out-Null
    foreach ($package in $Packages) {
        $destination = Join-Path $inputDirectory ([System.IO.Path]::GetFileName($package))
        try {
            New-Item -ItemType HardLink -Path $destination -Target $package -ErrorAction Stop | Out-Null
        }
        catch {
            Copy-Item -LiteralPath $package -Destination $destination -Force
        }
    }

    $bundlePath = Join-Path $BundleDirectory "$Name.appxbundle"
    Invoke-Native -FilePath $MakeAppx -Arguments @('bundle', '/d', $inputDirectory, '/p', $bundlePath, '/o')
    Invoke-Native -FilePath $SignTool -Arguments @('sign', '/fd', 'SHA256', '/sha1', $CertificateThumbprint, '/tr', $TimestampUrl, '/td', 'SHA512', $bundlePath)
    Test-PackageSignature -PackagePath $bundlePath -SignTool $SignTool -Thumbprint $CertificateThumbprint
    Test-Bundle -BundlePath $bundlePath -Version $Version -Architectures $Architectures -GitHubAsset:$GitHubAsset

    return $bundlePath
}

$msbuild = Find-MSBuild
$sdk = Find-SdkTools
$systemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (Test-Path -LiteralPath $systemTar -PathType Leaf) {
    $tar = $systemTar
}
else {
    $tar = (Get-Command tar.exe -ErrorAction Stop).Source
}
Write-Host "Using MSBuild: $msbuild"
Write-Host "Using Windows SDK: $($sdk.Version)"

$amd64 = Test-ReleaseImage -ImagePath $Amd64Image -TarPath $tar
$arm64 = Test-ReleaseImage -ImagePath $Arm64Image -TarPath $tar
if ($amd64.Version -cne $ExpectedVersion -or $arm64.Version -cne $ExpectedVersion) {
    throw "Both rootfs VERSION_ID values must be $ExpectedVersion; found $($amd64.Version) and $($arm64.Version)."
}
if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "ExpectedVersion must contain exactly three numeric components, not $ExpectedVersion."
}

$packageVersion = "$ExpectedVersion.0"
$outputDirectory = Join-Path (Resolve-ReleasePath $OutputRoot) $packageVersion
if ((Test-Path -LiteralPath $outputDirectory) -and -not $SkipClean) {
    Remove-Item -LiteralPath $outputDirectory -Recurse -Force
}
if (-not $SkipClean) {
    foreach ($platform in @('x64', 'ARM64')) {
        $releaseDirectory = Join-Path $Root "$platform\Release"
        if (Test-Path -LiteralPath $releaseDirectory) {
            Remove-Item -LiteralPath $releaseDirectory -Recurse -Force
        }
    }
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Set-ManifestVersion -Version $packageVersion
$CertificateThumbprint = Initialize-StoreAssociation -MSBuild $msbuild -SdkVersion $sdk.Version
Copy-StagedImage -Image $amd64 -Platform 'x64'
Copy-StagedImage -Image $arm64 -Platform 'ARM64'

$buildRoot = Join-Path $outputDirectory 'build'
$x64Package = Build-ArchitecturePackage -Platform 'x64' -BuildRoot $buildRoot -MSBuild $msbuild -SdkVersion $sdk.Version
$arm64Package = Build-ArchitecturePackage -Platform 'ARM64' -BuildRoot $buildRoot -MSBuild $msbuild -SdkVersion $sdk.Version

Test-AppxPackage -PackagePath $x64Package -Architecture 'x64' -Version $packageVersion -Image $amd64
Test-AppxPackage -PackagePath $arm64Package -Architecture 'arm64' -Version $packageVersion -Image $arm64

$storeBundle = New-SignedBundle -Name "AOSCOS_${packageVersion}_Store_x64_ARM64" -Packages @($x64Package, $arm64Package) -Architectures @('x64', 'arm64') -Version $packageVersion -BundleDirectory $outputDirectory -MakeAppx $sdk.MakeAppx -SignTool $sdk.SignTool
$x64Bundle = New-SignedBundle -Name "AOSCOS_${packageVersion}_x64" -Packages @($x64Package) -Architectures @('x64') -Version $packageVersion -BundleDirectory $outputDirectory -MakeAppx $sdk.MakeAppx -SignTool $sdk.SignTool -GitHubAsset
$arm64Bundle = New-SignedBundle -Name "AOSCOS_${packageVersion}_ARM64" -Packages @($arm64Package) -Architectures @('arm64') -Version $packageVersion -BundleDirectory $outputDirectory -MakeAppx $sdk.MakeAppx -SignTool $sdk.SignTool -GitHubAsset

$checksumLines = @($x64Bundle, $arm64Bundle) | ForEach-Object {
    $hash = Get-Sha256Hash -Path $_
    "$hash *$([System.IO.Path]::GetFileName($_))"
}
$checksumPath = Join-Path $outputDirectory 'SHA256SUMS'
[System.IO.File]::WriteAllText($checksumPath, ($checksumLines -join "`n") + "`n", [System.Text.Encoding]::ASCII)

Write-Host "Release artifacts: $outputDirectory"
Get-Item -LiteralPath $storeBundle, $x64Bundle, $arm64Bundle, $checksumPath |
    Select-Object Name, Length, FullName
