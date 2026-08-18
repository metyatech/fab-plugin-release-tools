# Copyright (c) 2026 metyatech. All rights reserved.

<#
.SYNOPSIS
Builds every configured Unreal Engine version and assembles one Fab submission bundle.

.EXAMPLE
pwsh .\Invoke-FabProductRelease.ps1 `
  -PluginPath ..\ServerManageToolPlugin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [string]$EngineRoot,

    [string]$ListingFieldsPath,

    [string]$OutputDirectory,

    [switch]$KeepWorkingDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-FabProductJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Required JSON file is missing: $Path"
    }
    try {
        return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "JSON file is invalid: $Path. $($_.Exception.Message)"
    }
}

function Import-FabProductConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $json = [System.IO.File]::ReadAllText($ConfigPath)
    try {
        if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot 'FabPluginRelease.schema.json') `
                    -ErrorAction Stop)) {
            throw 'Schema validation returned false.'
        }
    }
    catch {
        throw "Configuration does not conform to FabPluginRelease.schema.json: $ConfigPath. $($_.Exception.Message)"
    }
    return Read-FabProductJson -Path $ConfigPath
}

function Assert-FabProductText {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Listing field '$Name' must contain non-blank text."
    }
    return [string]$property.Value
}

function ConvertTo-FabProductStringArray {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or
        $property.Value -isnot [System.Array]) {
        throw "Listing field '$Name' must be an array."
    }
    $values = @($property.Value | ForEach-Object { [string]$_ })
    if ($values.Count -eq 0 -or @($values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "Listing field '$Name' must contain non-blank values."
    }
    return $values
}

function Test-FabProductDescendantPath {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Candidate
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidatePath = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    return $candidatePath.StartsWith($rootPath + [System.IO.Path]::DirectorySeparatorChar, `
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-FabProductMediaPath {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Media path must be a relative path without '..': $RelativePath"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $PluginRoot $RelativePath))
    if (-not (Test-FabProductDescendantPath -Root $PluginRoot -Candidate $candidate)) {
        throw "Media path must stay inside PluginPath: $RelativePath"
    }
    if (-not [System.IO.File]::Exists($candidate)) {
        throw "Media file is missing: $RelativePath"
    }
    $attributes = [System.IO.File]::GetAttributes($candidate)
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Media path must not pass through a reparse point: $RelativePath"
    }

    $current = $candidate
    $rootPath = [System.IO.Path]::GetFullPath($PluginRoot).TrimEnd('\', '/')
    while ($true) {
        $currentAttributes = [System.IO.File]::GetAttributes($current)
        if (($currentAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Media path must not pass through a reparse point: $RelativePath"
        }
        if ($current.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Could not resolve media path parent: $RelativePath"
        }
        $current = $parent.FullName.TrimEnd('\', '/')
    }
    return $candidate
}

function Test-FabProductMediaEntry {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Listing
    )

    $entries = ConvertTo-FabProductStringArray -Object $Listing -Name 'media_order'
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $validated = [System.Collections.Generic.List[object]]::new()
    $order = 1
    foreach ($entry in $entries) {
        $normalized = $entry.Replace('\', '/')
        if (-not $seen.Add($normalized)) {
            throw "media_order contains a duplicate entry (case-insensitive): $entry"
        }
        $fullPath = Assert-FabProductMediaPath -PluginRoot $PluginRoot -RelativePath $entry
        $validated.Add([pscustomobject]@{
                Order          = $order
                SourcePath     = $fullPath
                SourceRelative = $normalized
            })
        $order++
    }
    return $validated.ToArray()
}

function Import-FabProductListing {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string]$ListingPath
    )

    $listing = Read-FabProductJson -Path $ListingPath
    $title = Assert-FabProductText -Object $listing -Name 'title'
    $shortDescription = Assert-FabProductText -Object $listing -Name 'short_description'
    $longDescription = Assert-FabProductText -Object $listing -Name 'long_description'
    $listingVersions = @(ConvertTo-FabProductStringArray -Object $listing -Name 'engine_versions')
    $listingPlatforms = @(ConvertTo-FabProductStringArray -Object $listing -Name 'platforms')
    $documentationUrl = Assert-FabProductText -Object $listing -Name 'documentation_url'
    $supportUrl = Assert-FabProductText -Object $listing -Name 'support_url'
    $media = @(Test-FabProductMediaEntry -PluginRoot $PluginRoot -Listing $listing)

    $configuredVersions = @($Configuration.engineVersions | ForEach-Object { [string]$_ })
    if ($listingVersions.Count -ne $configuredVersions.Count -or
        @($configuredVersions | Where-Object { $listingVersions -cnotcontains $_ }).Count -gt 0 -or
        @($listingVersions | Where-Object { $configuredVersions -cnotcontains $_ }).Count -gt 0) {
        throw 'listing engine_versions must exactly match FabPluginRelease.json.engineVersions.'
    }
    $configuredPlatforms = @($Configuration.platforms | ForEach-Object { [string]$_ })
    if ($listingPlatforms.Count -ne $configuredPlatforms.Count -or
        [string]::Join("`n", $listingPlatforms) -cne [string]::Join("`n", $configuredPlatforms)) {
        throw 'listing platforms must exactly match FabPluginRelease.json.platforms.'
    }
    if ($documentationUrl -cne [string]$Configuration.documentationUrl) {
        throw 'listing documentation_url must exactly match FabPluginRelease.json.documentationUrl.'
    }
    if ($supportUrl -cne [string]$Configuration.supportUrl) {
        throw 'listing support_url must exactly match FabPluginRelease.json.supportUrl.'
    }

    return [pscustomobject]@{
        Title             = $title
        ShortDescription  = $shortDescription
        LongDescription   = $longDescription
        EngineVersions    = $listingVersions
        Platforms         = $listingPlatforms
        DocumentationUrl  = $documentationUrl
        SupportUrl        = $supportUrl
        Media             = $media
    }
}

function Invoke-FabProductVersionRelease {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string]$EngineVersion,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string]$EngineRoot,

        [switch]$KeepWorkingDirectory
    )

    $arguments = @{
        PluginPath           = $PluginRoot
        EngineVersion        = $EngineVersion
        OutputDirectory      = $OutputPath
        KeepWorkingDirectory = $KeepWorkingDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($EngineRoot)) {
        $arguments.EngineRoot = $EngineRoot
    }
    Invoke-FabPluginRelease @arguments
}

function Invoke-FabProductSubmissionValidation {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string]$PackageZipPath,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $scriptPath = Join-Path $PSScriptRoot 'Test-FabPluginSubmission.ps1'
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoProfile', '-NonInteractive', '-File', $scriptPath,
            '-PluginPath', $PluginRoot,
            '-PackageZipPath', $PackageZipPath,
            '-OutputDirectory', $OutputPath)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        $output = [string]::Join("`n", @($stdoutTask.Result, $stderrTask.Result)).Trim()
        if ($process.ExitCode -ne 0) {
            throw "Submission validation failed for $PackageZipPath. $output"
        }
        return [pscustomobject]@{
            OutputPath = $OutputPath
            Output     = $output
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-FabProductReleaseArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$EngineVersion
    )

    $zipFiles = @(Get-ChildItem -LiteralPath $OutputPath -File -Filter '*.zip')
    if ($zipFiles.Count -ne 1) {
        throw "Expected exactly one generated ZIP for UE$EngineVersion in $OutputPath. Found $($zipFiles.Count)."
    }
    $zip = $zipFiles[0]
    $hashPath = "$($zip.FullName).sha256"
    $reportPath = "$($zip.FullName).report.json"
    $logPath = "$($zip.FullName).log"
    foreach ($path in @($hashPath, $reportPath, $logPath)) {
        if (-not [System.IO.File]::Exists($path)) {
            throw "Release artifact is missing for UE${EngineVersion}: $path"
        }
    }
    $hash = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashText = [System.IO.File]::ReadAllText($hashPath).Trim()
    if ($hashText -notmatch '^(?<hash>[0-9a-fA-F]{64})\s+') {
        throw "Release checksum file is invalid: $hashPath"
    }
    if ($Matches.hash.ToLowerInvariant() -cne $hash) {
        throw "Release checksum does not match generated ZIP: $zip.FullName"
    }
    return [pscustomobject]@{
        EngineVersion = $EngineVersion
        ZipPath       = $zip.FullName
        HashPath      = $hashPath
        ReportPath    = $reportPath
        LogPath        = $logPath
        Sha256        = $hash
    }
}

function Remove-FabProductDirectory {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Directory]::Exists($Path) -and $PSCmdlet.ShouldProcess($Path, 'Remove directory')) {
        [System.IO.Directory]::Delete($Path, $true)
    }
}

function Copy-FabProductMedia {
    param(
        [Parameter(Mandatory)]
        [object[]]$Media,

        [Parameter(Mandatory)]
        [string]$BundleRoot
    )

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($mediaItem in $Media) {
        $fileName = [System.IO.Path]::GetFileName($mediaItem.SourceRelative)
        $bundleRelative = ('media/{0:D3}_{1}' -f $mediaItem.Order, $fileName)
        $destination = Join-Path $BundleRoot ($bundleRelative.Replace('/', '\'))
        [System.IO.File]::Copy($mediaItem.SourcePath, $destination, $false)
        $sourceHash = (Get-FileHash -LiteralPath $mediaItem.SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $bundleHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceHash -cne $bundleHash) {
            throw "Media integrity check failed: $($mediaItem.SourceRelative)"
        }
        $items.Add([ordered]@{
                order              = [int]$mediaItem.Order
                sourceRelativePath = $mediaItem.SourceRelative
                bundleRelativePath = $bundleRelative
                sha256             = $sourceHash
            })
    }
    return $items.ToArray()
}

function Copy-FabProductPackage {
    param(
        [Parameter(Mandatory)]
        [object[]]$Releases,

        [Parameter(Mandatory)]
        [string]$BundleRoot
    )

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($release in $Releases) {
        $directoryName = "UE$($release.EngineVersion)"
        $packageDirectory = Join-Path $BundleRoot "packages\$directoryName"
        [System.IO.Directory]::CreateDirectory($packageDirectory) | Out-Null
        foreach ($sourcePath in @($release.ZipPath, $release.HashPath, $release.ReportPath, $release.LogPath)) {
            [System.IO.File]::Copy($sourcePath, (Join-Path $packageDirectory ([System.IO.Path]::GetFileName($sourcePath))), $false)
        }
        $bundleRelative = "packages/$directoryName/$([System.IO.Path]::GetFileName($release.ZipPath))"
        $items.Add([ordered]@{
                engineVersion       = $release.EngineVersion
                bundleRelativePath  = $bundleRelative
                sha256              = $release.Sha256
            })
    }
    return $items.ToArray()
}

function Write-FabProductTextFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Write-FabProductChecklist {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$EngineVersions,

        [Parameter(Mandatory)]
        [object[]]$Media
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Fab Product Release Checklist')
    $lines.Add('')
    foreach ($version in $EngineVersions) { $lines.Add("PASS - UE$version built") }
    foreach ($version in $EngineVersions) { $lines.Add("PASS - UE$version package validated") }
    $lines.Add('PASS - submission metadata validation')
    $lines.Add('PASS - listing/config consistency')
    $lines.Add("PASS - media existence/integrity ($($Media.Count) ordered file(s))")
    $lines.Add('PASS - bundle manifest generation')
    $lines.Add('')
    $lines.Add('Future browser automation / Fab human review:')
    $lines.Add('- Upload the generated packages to the Fab Portal.')
    $lines.Add('- Enter or confirm listing content, pricing, availability, and portal declarations.')
    $lines.Add('- Complete Fab human review and publish the listing.')
    Write-FabProductTextFile -Path $Path -Text (([string]::Join("`n", $lines)) + "`n")
}

function Invoke-FabProductReleaseCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath,

        [string]$EngineRoot,

        [string]$ListingFieldsPath,

        [string]$OutputDirectory,

        [switch]$KeepWorkingDirectory
    )

    $resolvedPluginPath = [System.IO.Path]::GetFullPath($PluginPath).TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($resolvedPluginPath)) {
        throw "PluginPath is not a directory: $resolvedPluginPath"
    }
    $configPath = Join-Path $resolvedPluginPath 'FabPluginRelease.json'
    $configuration = Import-FabProductConfiguration -ConfigPath $configPath
    $listingPath = if ([string]::IsNullOrWhiteSpace($ListingFieldsPath)) {
        Join-Path $resolvedPluginPath 'FabListingFields.json'
    }
    else {
        [System.IO.Path]::GetFullPath($ListingFieldsPath)
    }
    $listing = Import-FabProductListing -PluginRoot $resolvedPluginPath `
        -Configuration $configuration -ListingPath $listingPath
    $engineVersions = @($configuration.engineVersions | ForEach-Object { [string]$_ }) |
        Sort-Object { [version]$_ }
    $artifactRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'artifacts'))
    }
    else {
        [System.IO.Path]::GetFullPath($OutputDirectory)
    }
    if ($artifactRoot.TrimEnd('\', '/').Equals($resolvedPluginPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Test-FabProductDescendantPath -Root $resolvedPluginPath -Candidate $artifactRoot)) {
        throw 'OutputDirectory must not be the plugin root or any directory below it.'
    }
    $productRoot = Join-Path $artifactRoot ([string]$configuration.pluginName)
    $sessionRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
        "fab-plugin-product-release-tools\$([guid]::NewGuid().ToString('D'))"
    $stagingRoot = Join-Path $sessionRoot 'FabSubmission'
    $publicBundle = Join-Path $productRoot 'FabSubmission'
    [System.IO.Directory]::CreateDirectory($productRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    $releaseResults = [System.Collections.Generic.List[object]]::new()
    $submissionOutputs = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($engineVersion in $engineVersions) {
            $versionOutput = Join-Path $productRoot "product\UE$engineVersion"
            try {
                Invoke-FabProductVersionRelease -PluginRoot $resolvedPluginPath `
                    -EngineVersion $engineVersion -OutputPath $versionOutput `
                    -EngineRoot $EngineRoot -KeepWorkingDirectory:$KeepWorkingDirectory
            }
            catch {
                throw "UE$engineVersion release failed: $($_.Exception.Message)"
            }
            $release = Get-FabProductReleaseArtifact -OutputPath $versionOutput `
                -EngineVersion $engineVersion
            $releaseResults.Add($release)
            $validationOutput = Join-Path $sessionRoot "submission-validation\UE$engineVersion"
            [System.IO.Directory]::CreateDirectory($validationOutput) | Out-Null
            [void](Invoke-FabProductSubmissionValidation -PluginRoot $resolvedPluginPath `
                -PackageZipPath $release.ZipPath -OutputPath $validationOutput
            )
            $technicalPath = Join-Path $validationOutput 'FabTechnicalInformation.txt'
            if (-not [System.IO.File]::Exists($technicalPath)) {
                throw "Submission validation did not produce FabTechnicalInformation.txt for UE$engineVersion."
            }
            $submissionOutputs.Add($technicalPath)
        }

        $submissionRoot = Join-Path $stagingRoot 'submission'
        $packagesRoot = Join-Path $stagingRoot 'packages'
        $mediaRoot = Join-Path $stagingRoot 'media'
        [System.IO.Directory]::CreateDirectory($submissionRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($packagesRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($mediaRoot) | Out-Null
        $technicalText = [System.IO.File]::ReadAllText($submissionOutputs[0])
        foreach ($technicalPath in $submissionOutputs) {
            if ([System.IO.File]::ReadAllText($technicalPath) -cne $technicalText) {
                throw 'Submission technical information differs between engine versions.'
            }
        }
        Write-FabProductTextFile -Path (Join-Path $submissionRoot 'FabTechnicalInformation.txt') -Text $technicalText
        $mediaManifest = @(Copy-FabProductMedia -Media @($listing.Media) -BundleRoot $stagingRoot)
        $packageManifest = @(Copy-FabProductPackage -Releases $releaseResults.ToArray() -BundleRoot $stagingRoot)
        $manifest = [ordered]@{
            schemaVersion             = 1
            pluginName                = [string]$configuration.pluginName
            listingId                 = if ($null -eq $configuration.listingId) { $null } else { [string]$configuration.listingId }
            title                     = $listing.Title
            shortDescription          = $listing.ShortDescription
            longDescription           = $listing.LongDescription
            engineVersions            = @($engineVersions)
            platforms                 = @($listing.Platforms)
            documentationUrl          = $listing.DocumentationUrl
            supportUrl                = $listing.SupportUrl
            technicalInformationFile  = 'submission/FabTechnicalInformation.txt'
            media                     = @($mediaManifest)
            packages                  = @($packageManifest)
            generatedAtUtc            = [DateTimeOffset]::UtcNow.ToString('O')
        }
        $manifestPath = Join-Path $stagingRoot 'FabPortalSubmission.json'
        Write-FabProductTextFile -Path $manifestPath `
            -Text (($manifest | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
        Write-FabProductChecklist -Path (Join-Path $stagingRoot 'SubmissionChecklist.txt') `
            -EngineVersions $engineVersions -Media @($listing.Media)

        $backupBundle = "$publicBundle.__previous_$([guid]::NewGuid().ToString('N'))"
        $hadPreviousBundle = [System.IO.Directory]::Exists($publicBundle)
        try {
            if ($hadPreviousBundle) {
                [System.IO.Directory]::Move($publicBundle, $backupBundle)
            }
            [System.IO.Directory]::Move($stagingRoot, $publicBundle)
            if ($hadPreviousBundle) {
                Remove-FabProductDirectory -Path $backupBundle -Confirm:$false
            }
        }
        catch {
            if ([System.IO.Directory]::Exists($publicBundle)) {
                Remove-FabProductDirectory -Path $publicBundle -Confirm:$false
            }
            if ($hadPreviousBundle -and [System.IO.Directory]::Exists($backupBundle)) {
                [System.IO.Directory]::Move($backupBundle, $publicBundle)
            }
            throw
        }
        return [pscustomobject]@{
            BundlePath = $publicBundle
            Manifest   = $manifest
        }
    }
    finally {
        if (-not $KeepWorkingDirectory) {
            Remove-FabProductDirectory -Path $sessionRoot -Confirm:$false
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $arguments = @{
            PluginPath           = $PluginPath
            KeepWorkingDirectory = $KeepWorkingDirectory
        }
        foreach ($name in @('EngineRoot', 'ListingFieldsPath', 'OutputDirectory')) {
            if ($PSBoundParameters.ContainsKey($name)) {
                $arguments[$name] = Get-Variable -Name $name -ValueOnly
            }
        }
        [void](Invoke-FabProductReleaseCore @arguments)
        $exitCode = 0
    }
    catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
    }
    finally {
        if ($exitCode -eq 0) {
            Write-Output 'FAB PRODUCT RELEASE: PASS'
        }
        else {
            Write-Output 'FAB PRODUCT RELEASE: FAIL'
        }
    }
    exit $exitCode
}
