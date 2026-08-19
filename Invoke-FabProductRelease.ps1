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

    [switch]$KeepWorkingDirectory,

    [switch]$PublishProjectFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FabPluginReleaseTools.psd1') -Force

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

function Import-FabProductListingJson {
    param(
        [Parameter(Mandatory)]
        [string]$ListingPath
    )

    $json = [System.IO.File]::ReadAllText($ListingPath)
    try {
        if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot 'FabListingFields.schema.json') `
                    -ErrorAction Stop)) {
            throw 'Schema validation returned false.'
        }
    }
    catch {
        throw "Listing fields do not conform to FabListingFields.schema.json: $ListingPath. $($_.Exception.Message)"
    }
    return Read-FabProductJson -Path $ListingPath
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

function Assert-FabProductListingNumber {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [ValueType] -or
        $property.Value -is [bool] -or $property.Value -is [char] -or
        $property.Value -isnot [decimal] -and $property.Value -isnot [double] -and
        $property.Value -isnot [single] -and $property.Value -isnot [int] -and
        $property.Value -isnot [long]) {
        throw "Listing field '$Name' must be a JSON number."
    }
    $number = [decimal]$property.Value
    if ($number -lt 0) {
        throw "Listing field '$Name' must be non-negative."
    }
    return $number
}

function Assert-FabProductListingBoolean {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [bool]) {
        throw "Listing field '$Name' must be a JSON boolean."
    }
    return [bool]$property.Value
}

function ConvertTo-FabProductEngineVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ($Value -match '^Unreal Engine (?<version>5\.[0-9]+)$') {
        return $Matches.version
    }
    return $Value
}

function Get-FabProductPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
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
    if ($entries.Count -lt 2) {
        throw 'media_order must contain at least one thumbnail and one gallery image.'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $validated = [System.Collections.Generic.List[object]]::new()
    $order = 1
    foreach ($entry in $entries) {
        $normalized = $entry.Replace('\', '/')
        if (-not $seen.Add($normalized)) {
            throw "media_order contains a duplicate entry (case-insensitive): $entry"
        }
        $fullPath = Assert-FabProductMediaPath -PluginRoot $PluginRoot -RelativePath $entry
        $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
        if ($extension -notin @('.png', '.jpg', '.jpeg')) {
            throw "Unsupported media format for browser automation: $entry"
        }
        $validated.Add([pscustomobject]@{
                Order          = $order
                Role           = if ($order -eq 1) { 'thumbnail' } else { 'gallery' }
                SourcePath     = $fullPath
                SourceRelative = $normalized
                FileName       = [System.IO.Path]::GetFileName($normalized)
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

    $listing = Import-FabProductListingJson -ListingPath $ListingPath
    foreach ($name in @(
            'product', 'version', 'title', 'short_description', 'long_description',
            'product_type', 'category', 'included_format', 'license', 'activation',
            'documentation_url', 'support_url', 'source_repository_url')) {
        [void](Assert-FabProductText -Object $listing -Name $name)
    }
    foreach ($name in @('personal_price_usd', 'professional_price_usd')) {
        [void](Assert-FabProductListingNumber -Object $listing -Name $name)
    }
    foreach ($name in @(
            'mature_content', 'generated_with_ai', 'allows_usage_with_ai',
            'promotional_content', 'forum_post')) {
        [void](Assert-FabProductListingBoolean -Object $listing -Name $name)
    }
    $subcategory = @(ConvertTo-FabProductStringArray -Object $listing -Name 'subcategory')
    $tags = @(ConvertTo-FabProductStringArray -Object $listing -Name 'tags_ordered')
    $tagSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tag in $tags) {
        if (-not $tagSet.Add($tag)) {
            throw 'tags_ordered must contain unique strings case-insensitively.'
        }
    }
    $title = Assert-FabProductText -Object $listing -Name 'title'
    $shortDescription = Assert-FabProductText -Object $listing -Name 'short_description'
    $longDescription = Assert-FabProductText -Object $listing -Name 'long_description'
    $listingVersionLabels = @(ConvertTo-FabProductStringArray -Object $listing -Name 'engine_versions')
    $listingVersions = @($listingVersionLabels | ForEach-Object {
            ConvertTo-FabProductEngineVersion -Value $_
        })
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

    $listingIdProperty = $listing.PSObject.Properties['listing_id']
    $configurationListingId = if ($null -eq $Configuration.listingId) {
        $null
    }
    else {
        [string]$Configuration.listingId
    }
    $listingId = $null
    if ($null -ne $listingIdProperty) {
        if ($listingIdProperty.Value -isnot [string] -or
            [string]$listingIdProperty.Value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            throw 'listing_id must be a lowercase UUID.'
        }
        $listingId = [string]$listingIdProperty.Value
        if ($null -ne $configurationListingId -and $listingId -cne $configurationListingId) {
            throw 'ListingFields.json listing_id conflicts with FabPluginRelease.json listingId.'
        }
    }
    else {
        $listingId = $configurationListingId
    }

    $publicReleaseSha256Property = $listing.PSObject.Properties['public_release_sha256']
    $publicReleaseSha256 = $null
    if ($null -ne $publicReleaseSha256Property) {
        if ($publicReleaseSha256Property.Value -isnot [string] -or
            [string]$publicReleaseSha256Property.Value -cnotmatch '^[0-9a-fA-F]{64}$') {
            throw 'public_release_sha256 must be a 64-character SHA-256 hexadecimal value.'
        }
        $publicReleaseSha256 = ([string]$publicReleaseSha256Property.Value).ToLowerInvariant()
    }

    $projectFileLinks = [ordered]@{}
    $usesLegacyProjectFileLink = $false
    $projectFileLinksValue = Get-FabProductPropertyValue -Object $listing -Name 'project_file_links'
    if ($null -ne $projectFileLinksValue) {
        if ($projectFileLinksValue -isnot [pscustomobject]) {
            throw 'project_file_links must be a JSON object.'
        }
        foreach ($property in $projectFileLinksValue.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw "project_file_links contains a blank URL for '$($property.Name)'."
            }
            $projectFileLinks[[string]$property.Name] = [string]$property.Value
        }
    }
    $legacyProjectFileLink = Get-FabProductPropertyValue -Object $listing -Name 'project_file_link'
    if ($null -ne $legacyProjectFileLink -and [string]::IsNullOrWhiteSpace([string]$legacyProjectFileLink)) {
        throw 'project_file_link must not be blank.'
    }
    if ($projectFileLinks.Count -eq 0 -and $null -ne $legacyProjectFileLink -and $configuredVersions.Count -eq 1) {
        $projectFileLinks[$configuredVersions[0]] = [string]$legacyProjectFileLink
        $usesLegacyProjectFileLink = $true
    }
    if ($projectFileLinks.Count -gt 0) {
        if ($projectFileLinks.Count -ne $configuredVersions.Count -or
            @($configuredVersions | Where-Object { -not $projectFileLinks.Contains($_) }).Count -gt 0 -or
            @($projectFileLinks.Keys | Where-Object { $configuredVersions -cnotcontains $_ }).Count -gt 0) {
            throw 'project_file_links must contain exactly one link for every configured engine version.'
        }
    }

    return [pscustomobject]@{
        Product                 = [string]$listing.product
        ProductVersion          = [string]$listing.version
        ListingId               = $listingId
        Title                   = $title
        ShortDescription        = $shortDescription
        LongDescription         = $longDescription
        ProductType             = [string]$listing.product_type
        Category                = [string]$listing.category
        Subcategory             = $subcategory
        Tags                    = $tags
        IncludedFormat          = [string]$listing.included_format
        EngineVersions          = $listingVersions
        Platforms               = $listingPlatforms
        License                 = [string]$listing.license
        PersonalPriceUsd        = [decimal]$listing.personal_price_usd
        ProfessionalPriceUsd    = [decimal]$listing.professional_price_usd
        MatureContent           = [bool]$listing.mature_content
        GeneratedWithAi         = [bool]$listing.generated_with_ai
        AllowsUsageWithAi       = [bool]$listing.allows_usage_with_ai
        PromotionalContent      = [bool]$listing.promotional_content
        ForumPost               = [bool]$listing.forum_post
        Activation              = [string]$listing.activation
        DocumentationUrl        = $documentationUrl
        SupportUrl              = $supportUrl
        SourceRepositoryUrl     = [string]$listing.source_repository_url
        ProjectFileLinks        = $projectFileLinks
        PublicReleaseSha256     = $publicReleaseSha256
        UsesLegacyProjectFileLink = $usesLegacyProjectFileLink
        Media                   = $media
        Raw                     = $listing
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

function Invoke-FabProductNativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
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
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output   = $output
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-FabProductGhPath {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'gh CLI is required when -PublishProjectFiles is specified.'
    }
    return $command.Source
}

function Invoke-FabProductGhCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = Invoke-FabProductNativeCommand -FileName (Get-FabProductGhPath) `
        -Arguments $Arguments -WorkingDirectory (Get-Location).Path
    if ($result.ExitCode -ne 0) {
        throw "gh command failed: $($result.Output)"
    }
    return $result.Output
}

function Invoke-FabProductGitCommand {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = Invoke-FabProductNativeCommand -FileName 'git.exe' `
        -Arguments $Arguments -WorkingDirectory $PluginRoot
    if ($result.ExitCode -ne 0) {
        throw "git command failed: $($result.Output)"
    }
    return $result.Output
}

function Get-FabProductDescriptor {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $descriptor = Read-FabProductJson -Path (Join-Path $PluginRoot $Configuration.descriptorFile)
    $versionName = Get-FabProductPropertyValue -Object $descriptor -Name 'VersionName'
    if ($versionName -isnot [string] -or [string]::IsNullOrWhiteSpace($versionName)) {
        throw 'The plugin descriptor VersionName must contain non-blank text.'
    }
    return [pscustomobject]@{
        VersionName = [string]$versionName
        Descriptor  = $descriptor
    }
}

function Get-FabProductRepositoryKey {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryUrl
    )

    if ($RepositoryUrl -match '^git@github\.com:(?<owner>[^/]+)/(?<repo>[^/]+)$') {
        $repo = $Matches.repo
        if ($repo.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
            $repo = $repo.Substring(0, $repo.Length - 4)
        }
        return "$($Matches.owner)/$repo"
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate($RepositoryUrl, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "source_repository_url must be an absolute HTTPS repository URL: $RepositoryUrl"
    }
    $segments = @($uri.AbsolutePath.Trim('/').Split('/') | Where-Object { $_ -ne '' })
    if ($uri.Host -ine 'github.com' -or $segments.Count -ne 2) {
        throw 'source_repository_url must point to a github.com repository.'
    }
    $repo = $segments[1]
    if ($repo.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $repo = $repo.Substring(0, $repo.Length - 4)
    }
    if ([string]::IsNullOrWhiteSpace($segments[0]) -or [string]::IsNullOrWhiteSpace($repo)) {
        throw "source_repository_url is not a repository URL: $RepositoryUrl"
    }
    return "$($segments[0])/$repo"
}

function Get-FabProductLocalRepositoryInfo {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot
    )

    $remote = Invoke-FabProductGitCommand -PluginRoot $PluginRoot -Arguments @('remote', 'get-url', 'origin')
    $branch = Invoke-FabProductGitCommand -PluginRoot $PluginRoot -Arguments @('branch', '--show-current')
    $head = (Invoke-FabProductGitCommand -PluginRoot $PluginRoot -Arguments @('rev-parse', 'HEAD')).Trim()
    if ($head -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'The local product Git repository HEAD must be a full 40-character commit SHA.'
    }
    $status = Invoke-FabProductGitCommand -PluginRoot $PluginRoot -Arguments @('status', '--porcelain', '--untracked-files=all')
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'The local product Git repository must be clean before publishing project files.'
    }
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'The local product Git repository must have a named current branch before publishing project files.'
    }
    $remoteHead = Invoke-FabProductGitCommand -PluginRoot $PluginRoot `
        -Arguments @('ls-remote', 'origin', "refs/heads/$branch")
    $remoteHash = ([regex]::Match($remoteHead, '^(?<hash>[0-9a-fA-F]{40})\s')).Groups['hash'].Value
    if ([string]::IsNullOrWhiteSpace($remoteHash) -or $remoteHash -cne $head) {
        throw 'HEAD must be pushed to the origin branch before publishing project files.'
    }
    return [pscustomobject]@{
        Remote = $remote
        Branch = $branch
        Head   = $head
    }
}

function Assert-FabProductGitHubPublicationPrerequisite {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string]$SourceRepositoryUrl
    )

    [void](Get-FabProductGhPath)
    [void](Invoke-FabProductGhCommand -Arguments @('auth', 'status'))
    $repositoryKey = Get-FabProductRepositoryKey -RepositoryUrl $SourceRepositoryUrl
    $local = Get-FabProductLocalRepositoryInfo -PluginRoot $PluginRoot
    $localKey = Get-FabProductRepositoryKey -RepositoryUrl $local.Remote
    if ($localKey -ine $repositoryKey) {
        throw "source_repository_url does not match the local origin repository: $repositoryKey versus $localKey"
    }
    $repositoryJson = Invoke-FabProductGhCommand -Arguments @(
        'repo', 'view', $repositoryKey, '--json', 'nameWithOwner,isPrivate')
    $repository = $repositoryJson | ConvertFrom-Json -Depth 20
    if ([bool]$repository.isPrivate) {
        throw "The source repository must be public: $repositoryKey"
    }
    if ([string]$repository.nameWithOwner -ine $repositoryKey) {
        throw "The source repository does not match the GitHub repository: $repositoryKey"
    }
    return [pscustomobject]@{
        RepositoryKey = $repositoryKey
        Local          = $local
    }
}

function Assert-FabProductReleaseTag {
    param(
        [Parameter(Mandatory)]
        [string]$VersionName
    )

    if ($VersionName -notmatch '^[0-9A-Za-z][0-9A-Za-z._+-]*$' -or
        $VersionName -match '\.\.' -or $VersionName.EndsWith('.') -or
        $VersionName.EndsWith('-') -or $VersionName.EndsWith('+') -or
        $VersionName -match '@\{' -or $VersionName -match '[\x00-\x20]') {
        throw "VersionName cannot safely form the Fab hosting release tag: $VersionName"
    }
    return "fab-v$VersionName"
}

function Get-FabProductReleaseInfo {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [string]$Tag
    )

    try {
        $json = Invoke-FabProductGhCommand -Arguments @(
            'release', 'view', $Tag, '--repo', $RepositoryKey,
            '--json', 'tagName,isDraft,body,assets,targetCommitish')
        return ($json | ConvertFrom-Json -Depth 50)
    }
    catch {
        if ($_.Exception.Message -match '(?i)(release not found|not found|HTTP 404)') {
            return $null
        }
        throw
    }
}

function Get-FabProductGitHubObjectCommit {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [object]$GitObject
    )

    $current = $GitObject
    $visited = @{}
    for ($depth = 0; $depth -lt 8; $depth++) {
        $objectProperty = $current.PSObject.Properties['object']
        $object = if ($null -eq $objectProperty) { $current } else { $objectProperty.Value }
        $sha = [string]$object.sha
        $type = [string]$object.type
        if ($sha -notmatch '^[0-9a-fA-F]{40}$') {
            throw "GitHub returned an invalid Git object SHA for $RepositoryKey."
        }
        if ($type -ceq 'commit') {
            return $sha
        }
        if ($type -cne 'tag') {
            throw "GitHub release target for $RepositoryKey resolved to unsupported Git object type '$type'."
        }
        if ($visited.ContainsKey($sha.ToLowerInvariant())) {
            throw "GitHub release target for $RepositoryKey contains a cyclic annotated tag."
        }
        $visited[$sha.ToLowerInvariant()] = $true
        $tagJson = Invoke-FabProductGhCommand -Arguments @(
            'api', "repos/$RepositoryKey/git/tags/$sha")
        try {
            $current = $tagJson | ConvertFrom-Json -Depth 20
        }
        catch {
            throw "GitHub returned invalid Git tag metadata for $RepositoryKey. $($_.Exception.Message)"
        }
    }
    throw "GitHub release target for $RepositoryKey has too many annotated tag layers."
}

function Get-FabProductGitHubRefCommit {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [ValidateSet('heads', 'tags')]
        [string]$RefKind,

        [Parameter(Mandatory)]
        [string]$RefName
    )

    if ([string]::IsNullOrWhiteSpace($RefName)) {
        throw "GitHub $RefKind ref name must not be blank."
    }
    $encodedRefName = [System.Uri]::EscapeDataString($RefName)
    $json = Invoke-FabProductGhCommand -Arguments @(
        'api', "repos/$RepositoryKey/git/ref/$RefKind/$encodedRefName")
    try {
        $ref = $json | ConvertFrom-Json -Depth 20
    }
    catch {
        throw "GitHub returned invalid $RefKind ref metadata for $RepositoryKey. $($_.Exception.Message)"
    }
    return Get-FabProductGitHubObjectCommit -RepositoryKey $RepositoryKey -GitObject $ref
}

function Get-FabProductReleaseTargetCommit {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [string]$TargetCommitish
    )

    $target = $TargetCommitish.Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        throw "GitHub release targetCommitish is missing for $RepositoryKey."
    }
    if ($target -match '^[0-9a-fA-F]{40}$') {
        return $target
    }
    if ($target -match '^refs/(?<kind>heads|tags)/(?<name>.+)$') {
        return Get-FabProductGitHubRefCommit -RepositoryKey $RepositoryKey `
            -RefKind $Matches.kind -RefName $Matches.name
    }
    if ($target -match '^(?<kind>heads|tags)/(?<name>.+)$') {
        return Get-FabProductGitHubRefCommit -RepositoryKey $RepositoryKey `
            -RefKind $Matches.kind -RefName $Matches.name
    }
    try {
        return Get-FabProductGitHubRefCommit -RepositoryKey $RepositoryKey `
            -RefKind 'heads' -RefName $target
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)(not found|HTTP 404)') {
            throw
        }
    }
    return Get-FabProductGitHubRefCommit -RepositoryKey $RepositoryKey `
        -RefKind 'tags' -RefName $target
}

function Get-FabProductReleaseTagCommit {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [string]$Tag
    )

    return Get-FabProductGitHubRefCommit -RepositoryKey $RepositoryKey `
        -RefKind 'tags' -RefName $Tag
}

function Assert-FabProductReleaseSourceCommit {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [string]$Tag,

        [Parameter(Mandatory)]
        [string]$TargetCommitish,

        [Parameter(Mandatory)]
        [string]$ExpectedSourceCommit
    )

    if ($ExpectedSourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'The validated local source HEAD must be a full 40-character commit SHA.'
    }
    $targetCommit = Get-FabProductReleaseTargetCommit -RepositoryKey $RepositoryKey `
        -TargetCommitish $TargetCommitish
    if ([string]::Compare($targetCommit, $ExpectedSourceCommit, [System.StringComparison]::OrdinalIgnoreCase) -ne 0) {
        throw "Existing GitHub Release $Tag targetCommitish '$TargetCommitish' resolves to source commit '$targetCommit', not validated local HEAD '$ExpectedSourceCommit'."
    }
    $tagCommit = Get-FabProductReleaseTagCommit -RepositoryKey $RepositoryKey -Tag $Tag
    if ([string]::Compare($tagCommit, $ExpectedSourceCommit, [System.StringComparison]::OrdinalIgnoreCase) -ne 0) {
        throw "Existing GitHub Release $Tag tag resolves to source commit '$tagCommit', not validated local HEAD '$ExpectedSourceCommit'."
    }
}

function Assert-FabProductReleaseOwnership {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [string]$Tag,

        [Parameter(Mandatory)]
        [object]$ReleaseInfo,

        [Parameter(Mandatory)]
        [string]$Marker,

        [Parameter(Mandatory)]
        [string]$ExpectedSourceCommit
    )

    if ([string]$ReleaseInfo.tagName -cne $Tag -or
        -not ([string]$ReleaseInfo.body).Contains($Marker)) {
        throw "Existing GitHub Release $Tag has conflicting target or source metadata (ownership marker mismatch)."
    }
    Assert-FabProductReleaseSourceCommit -RepositoryKey $RepositoryKey -Tag $Tag `
        -TargetCommitish ([string]$ReleaseInfo.targetCommitish) `
        -ExpectedSourceCommit $ExpectedSourceCommit
}

function Get-FabProductReleaseMarker {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryKey,

        [Parameter(Mandatory)]
        [string]$PluginName,

        [Parameter(Mandatory)]
        [string]$ProductVersion,

        [Parameter(Mandatory)]
        [string[]]$EngineVersions,

        [Parameter(Mandatory)]
        [string]$SourceCommit
    )

    if ($SourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'sourceCommit must be a full 40-character commit SHA.'
    }
    return "fab-plugin-release-tools`nrepository=$RepositoryKey`npluginName=$PluginName`nproductVersion=$ProductVersion`nengineVersions=$([string]::Join(',', $EngineVersions))`nsourceCommit=$SourceCommit"
}

function Test-FabProductPublicUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [switch]$ThrowOnFailure
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 10 -TimeoutSec 30 `
            -SkipHttpErrorCheck
        $valid = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -le 399
        if (-not $valid -and [int]$response.StatusCode -eq 405) {
            $response = Invoke-WebRequest -Uri $Url -Method Get -MaximumRedirection 10 -TimeoutSec 30 `
                -SkipHttpErrorCheck
            $valid = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -le 399
        }
    }
    catch {
        $valid = $false
    }
    if (-not $valid -and $ThrowOnFailure) {
        throw "Public Project File Link is not reachable without authentication: $Url"
    }
    return $valid
}

$script:FabProductMaximumRemotePackageBytes = 15L * 1024L * 1024L * 1024L
$script:FabProductMaximumRemoteRedirects = 10

function ConvertTo-FabProductSafeUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return '<invalid-url>'
    }
    try {
        $builder = [System.UriBuilder]::new($uri)
        $builder.UserName = ''
        $builder.Password = ''
        $builder.Query = ''
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }
    catch {
        return '<invalid-url>'
    }
}

function Get-FabProductStreamSha256 {
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [long]$MaximumBytes = $script:FabProductMaximumRemotePackageBytes
    )

    if ($MaximumBytes -le 0) {
        throw 'MaximumBytes must be positive.'
    }
    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    $buffer = [byte[]]::new(1024 * 1024)
    $totalBytes = 0L
    try {
        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $totalBytes += $read
            if ($totalBytes -gt $MaximumBytes) {
                throw 'Remote Project File Link exceeds the package size limit.'
            }
            [void]$hashAlgorithm.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$hashAlgorithm.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return [pscustomobject]@{
            Sha256 = [System.Convert]::ToHexString($hashAlgorithm.Hash).ToLowerInvariant()
            Bytes  = $totalBytes
        }
    }
    finally {
        $hashAlgorithm.Dispose()
    }
}

function Get-FabProductHttpClient {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds(30)
    return $client
}

function Get-FabProductRemoteZipHash {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$ExpectedSha256,

        [System.Net.Http.HttpClient]$HttpClient
    )

    if ($ExpectedSha256 -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'ExpectedSha256 must be a 64-character SHA-256 hexadecimal value.'
    }
    $safeUrl = ConvertTo-FabProductSafeUrl -Url $Url
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "Public Project File Link must be an absolute HTTPS URL: $safeUrl"
    }

    $ownsClient = $null -eq $HttpClient
    if ($ownsClient) {
        $HttpClient = Get-FabProductHttpClient
    }
    $currentUri = $uri
    $redirectCount = 0
    try {
        while ($true) {
            $request = [System.Net.Http.HttpRequestMessage]::new(
                [System.Net.Http.HttpMethod]::Get, $currentUri)
            $response = $null
            try {
                try {
                    $response = $HttpClient.SendAsync(
                        $request,
                        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                    ).GetAwaiter().GetResult()
                }
                catch {
                    throw "Public Project File Link request failed for $safeUrl."
                }

                $statusCode = [int]$response.StatusCode
                if ($statusCode -ge 300 -and $statusCode -le 399) {
                    if ($redirectCount -ge $script:FabProductMaximumRemoteRedirects -or
                        $null -eq $response.Headers.Location) {
                        throw "Public Project File Link redirect limit failed for $safeUrl."
                    }
                    $nextUri = if ($response.Headers.Location.IsAbsoluteUri) {
                        $response.Headers.Location
                    }
                    else {
                        [System.Uri]::new($currentUri, $response.Headers.Location)
                    }
                    if ($nextUri.Scheme -cne 'https' -or
                        [string]::IsNullOrWhiteSpace($nextUri.Host)) {
                        throw "Public Project File Link redirect must remain HTTPS for $safeUrl."
                    }
                    $currentUri = $nextUri
                    $redirectCount++
                    continue
                }
                if ($statusCode -lt 200 -or $statusCode -gt 299) {
                    throw "Public Project File Link returned HTTP $statusCode for $safeUrl."
                }
                if ($null -eq $response.Content) {
                    throw "Public Project File Link returned no content for $safeUrl."
                }
                $contentLength = $response.Content.Headers.ContentLength
                if ($null -ne $contentLength -and
                    $contentLength -gt $script:FabProductMaximumRemotePackageBytes) {
                    throw "Public Project File Link exceeds the package size limit for $safeUrl."
                }
                $remoteStream = $null
                try {
                    $remoteStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $streamResult = Get-FabProductStreamSha256 -Stream $remoteStream
                }
                catch {
                    throw "Public Project File Link transfer failed for $safeUrl."
                }
                finally {
                    if ($null -ne $remoteStream) {
                        $remoteStream.Dispose()
                    }
                }
                if ($null -ne $contentLength -and $streamResult.Bytes -ne $contentLength) {
                    throw "Public Project File Link transfer was truncated for $safeUrl."
                }
                $actualSha256 = [string]$streamResult.Sha256
                if ($actualSha256 -cne $ExpectedSha256.ToLowerInvariant()) {
                    throw "Public Project File Link SHA-256 mismatch for $safeUrl."
                }
                return [pscustomobject]@{
                    Url           = $safeUrl
                    Sha256        = $actualSha256
                    Bytes         = [long]$streamResult.Bytes
                    RedirectCount = $redirectCount
                }
            }
            finally {
                if ($null -ne $response) {
                    $response.Dispose()
                }
                $request.Dispose()
            }
        }
    }
    finally {
        if ($ownsClient) {
            $HttpClient.Dispose()
        }
    }
}

function Publish-FabProductProjectFile {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [object]$Listing,

        [Parameter(Mandatory)]
        [object[]]$Releases,

        [Parameter(Mandatory)]
        [string[]]$EngineVersions,

        [Parameter(Mandatory)]
        [string]$ProductVersion
    )

    $prerequisites = Assert-FabProductGitHubPublicationPrerequisite `
        -PluginRoot $PluginRoot -SourceRepositoryUrl $Listing.SourceRepositoryUrl
    $tag = Assert-FabProductReleaseTag -VersionName $ProductVersion
    $sourceCommit = [string]$prerequisites.Local.Head
    if ($sourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'The validated local source HEAD must be a full 40-character commit SHA.'
    }
    $marker = Get-FabProductReleaseMarker -RepositoryKey $prerequisites.RepositoryKey `
        -PluginName ([string]$Configuration.pluginName) -ProductVersion $ProductVersion `
        -EngineVersions $EngineVersions -SourceCommit $sourceCommit
    $releaseInfo = Get-FabProductReleaseInfo -RepositoryKey $prerequisites.RepositoryKey -Tag $tag
    if ($null -eq $releaseInfo) {
        [void](Invoke-FabProductGhCommand -Arguments @(
                'release', 'create', $tag, '--repo', $prerequisites.RepositoryKey,
                '--target', $sourceCommit, '--draft', '--title', $tag, '--notes', $marker))
        $releaseInfo = Get-FabProductReleaseInfo -RepositoryKey $prerequisites.RepositoryKey -Tag $tag
        if ($null -eq $releaseInfo) {
            throw "GitHub Release $tag could not be read after creation."
        }
        Assert-FabProductReleaseOwnership -RepositoryKey $prerequisites.RepositoryKey -Tag $tag `
            -ReleaseInfo $releaseInfo -Marker $marker -ExpectedSourceCommit $sourceCommit
    }
    else {
        Assert-FabProductReleaseOwnership -RepositoryKey $prerequisites.RepositoryKey -Tag $tag `
            -ReleaseInfo $releaseInfo -Marker $marker -ExpectedSourceCommit $sourceCommit
    }

    foreach ($release in $Releases) {
        $assetName = [System.IO.Path]::GetFileName($release.ZipPath)
        $matchingAssets = @($releaseInfo.assets | Where-Object { [string]$_.name -ceq $assetName })
        $asset = if ($matchingAssets.Count -gt 0) { $matchingAssets[0] } else { $null }
        if ($null -ne $asset) {
            $digest = [string]$asset.digest
            if ($digest -notmatch '(?i)^sha256:(?<hash>[0-9a-f]{64})$' -or
                $Matches.hash.ToLowerInvariant() -cne $release.Sha256) {
                throw "Existing GitHub Release asset has a conflicting SHA-256: $assetName"
            }
        }
        else {
            if (-not [bool]$releaseInfo.isDraft) {
                throw "Cannot upload a missing asset to the published GitHub Release ${tag}: $assetName"
            }
            [void](Invoke-FabProductGhCommand -Arguments @(
                    'release', 'upload', $tag, $release.ZipPath,
                    '--repo', $prerequisites.RepositoryKey))
        }
        $releaseInfo = Get-FabProductReleaseInfo -RepositoryKey $prerequisites.RepositoryKey -Tag $tag
    }
    if ([bool]$releaseInfo.isDraft) {
        [void](Invoke-FabProductGhCommand -Arguments @(
                'release', 'edit', $tag, '--repo', $prerequisites.RepositoryKey, '--draft=false'))
        $releaseInfo = Get-FabProductReleaseInfo -RepositoryKey $prerequisites.RepositoryKey -Tag $tag
    }

    $links = [ordered]@{}
    foreach ($release in $Releases) {
        $assetName = [System.IO.Path]::GetFileName($release.ZipPath)
        $matchingAssets = @($releaseInfo.assets | Where-Object { [string]$_.name -ceq $assetName })
        $asset = if ($matchingAssets.Count -gt 0) { $matchingAssets[0] } else { $null }
        $digest = [string]$asset.digest
        if ($digest -notmatch '(?i)^sha256:(?<hash>[0-9a-f]{64})$' -or
            $Matches.hash.ToLowerInvariant() -cne $release.Sha256) {
            throw "GitHub Release asset digest verification failed: $assetName"
        }
        $url = [string]$asset.browserDownloadUrl
        if ([string]::IsNullOrWhiteSpace($url)) {
            throw "GitHub Release asset has no public browser_download_url: $assetName"
        }
        [void](Test-FabProductPublicUrl -Url $url -ThrowOnFailure)
        $links[$release.EngineVersion] = $url
    }
    return $links
}

function Resolve-FabProductProjectFileLink {
    param(
        [Parameter(Mandatory)]
        [object]$Listing,

        [Parameter(Mandatory)]
        [string[]]$EngineVersions,

        [switch]$PublishProjectFiles,

        [string]$PluginRoot,

        [object]$Configuration,

        [object[]]$Releases,

        [string]$ProductVersion
    )

    if ($PublishProjectFiles) {
        $publishedLinks = Publish-FabProductProjectFile -PluginRoot $PluginRoot `
            -Configuration $Configuration -Listing $Listing -Releases $Releases `
            -EngineVersions $EngineVersions -ProductVersion $ProductVersion
        return [pscustomobject]@{
            Links    = $publishedLinks
            Verified = $true
            Pending  = @()
        }
    }

    $links = [ordered]@{}
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($engineVersion in $EngineVersions) {
        if (-not $Listing.ProjectFileLinks.Contains($engineVersion)) {
            $pending.Add($engineVersion)
            continue
        }
        $url = [string]$Listing.ProjectFileLinks[$engineVersion]
        $uri = $null
        if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
            throw "Project File Link must be an absolute HTTPS URL for UE${engineVersion}: $(ConvertTo-FabProductSafeUrl -Url $url)"
        }
        $matchingReleases = @($Releases | Where-Object {
                [string]$_.EngineVersion -ceq $engineVersion
            })
        if ($matchingReleases.Count -ne 1) {
            throw "Exactly one generated release is required for UE$engineVersion Project File Link verification."
        }
        $release = $matchingReleases[0]
        $expectedSha256 = [string]$release.Sha256
        if ($expectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Generated UE$engineVersion release has an invalid SHA-256."
        }
        $metadataSha256 = [string]$Listing.PublicReleaseSha256
        $crossCheckMetadata = $EngineVersions.Count -eq 1 -and
            [bool]$Listing.UsesLegacyProjectFileLink -and
            -not [string]::IsNullOrWhiteSpace($metadataSha256)
        if ($crossCheckMetadata -and $metadataSha256 -cne $expectedSha256) {
            throw 'public_release_sha256 does not match the generated release SHA-256.'
        }
        $remote = Get-FabProductRemoteZipHash -Url $url -ExpectedSha256 $expectedSha256
        if ($crossCheckMetadata -and [string]$remote.Sha256 -cne $metadataSha256) {
            throw 'Downloaded Project File Link SHA-256 does not match public_release_sha256.'
        }
        $links[$engineVersion] = $url
    }
    return [pscustomobject]@{
        Links    = $links
        Verified = $pending.Count -eq 0 -and $links.Count -eq $EngineVersions.Count
        Pending  = $pending.ToArray()
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
                role               = $mediaItem.Role
                sourceRelativePath = $mediaItem.SourceRelative
                bundleRelativePath = $bundleRelative
                sha256             = $sourceHash
                fileName           = $mediaItem.FileName
            })
    }
    return $items.ToArray()
}

function Copy-FabProductPackage {
    param(
        [Parameter(Mandatory)]
        [object[]]$Releases,

        [Parameter(Mandatory)]
        [string]$BundleRoot,

        [Parameter(Mandatory)]
        [object]$ProjectFileLinks
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
                projectFileLink     = if ($ProjectFileLinks.Contains($release.EngineVersion)) {
                    [string]$ProjectFileLinks[$release.EngineVersion]
                }
                else {
                    $null
                }
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

function Get-FabProductSessionRoot {
    param(
        [Parameter(Mandatory)]
        [string]$ProductRoot
    )

    return Join-Path $ProductRoot ".sessions\$([guid]::NewGuid().ToString('D'))"
}

function Copy-FabProductFailureDiagnostic {
    param(
        [Parameter(Mandatory)]
        [string]$SessionRoot,

        [Parameter(Mandatory)]
        [string]$FailureRoot,

        [Parameter(Mandatory)]
        [string]$Message
    )

    [System.IO.Directory]::CreateDirectory($FailureRoot) | Out-Null
    $sessionFull = [System.IO.Path]::GetFullPath($SessionRoot).TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $sessionFull -Recurse -File | Where-Object {
                $_.Name.EndsWith('.log', [System.StringComparison]::OrdinalIgnoreCase) -or
                $_.Name.EndsWith('.report.json', [System.StringComparison]::OrdinalIgnoreCase)
            })) {
        $relative = [System.IO.Path]::GetRelativePath($sessionFull, $file.FullName)
        $destination = Join-Path $FailureRoot $relative
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null
        [System.IO.File]::Copy($file.FullName, $destination, $true)
    }
    Write-FabProductTextFile -Path (Join-Path $FailureRoot 'failure.txt') -Text ($Message + "`n")
    return $FailureRoot
}

function Write-FabProductChecklist {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$EngineVersions,

        [Parameter(Mandatory)]
        [object[]]$Media,

        [Parameter(Mandatory)]
        [object]$ProjectLinks,

        [Parameter(Mandatory)]
        [bool]$PortalReady
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Fab Product Release Checklist')
    $lines.Add('')
    foreach ($version in $EngineVersions) { $lines.Add("PASS - UE$version built") }
    foreach ($version in $EngineVersions) { $lines.Add("PASS - UE$version package validated") }
    $lines.Add('PASS - listing schema validation')
    $lines.Add('PASS - listing/config consistency')
    $lines.Add('PASS - technical information consistency')
    $lines.Add("PASS - media integrity ($($Media.Count) ordered file(s))")
    $lines.Add('PASS - manifest integrity')
    foreach ($version in $EngineVersions) {
        if ($ProjectLinks.Contains($version)) {
            $lines.Add("PASS - public Project File Link verified for UE$version")
        }
        else {
            $lines.Add("PENDING - Project File Link for UE$version")
        }
    }
    if ($PortalReady) {
        $lines.Add('PASS - portal automation input ready')
    }
    $lines.Add('')
    $lines.Add('Future browser automation / Fab human review:')
    if (-not $PortalReady) {
        $lines.Add('- Resolve the pending Project File Links before starting portal automation.')
    }
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

        [switch]$KeepWorkingDirectory,

        [switch]$PublishProjectFiles
    )

    $resolvedPluginPath = [System.IO.Path]::GetFullPath($PluginPath).TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($resolvedPluginPath)) {
        throw "PluginPath is not a directory: $resolvedPluginPath"
    }
    $configPath = Join-Path $resolvedPluginPath 'FabPluginRelease.json'
    $configuration = Import-FabProductConfiguration -ConfigPath $configPath
    $descriptor = Get-FabProductDescriptor -PluginRoot $resolvedPluginPath -Configuration $configuration
    $listingPath = if ([string]::IsNullOrWhiteSpace($ListingFieldsPath)) {
        Join-Path $resolvedPluginPath 'FabListingFields.json'
    }
    else {
        [System.IO.Path]::GetFullPath($ListingFieldsPath)
    }
    $listing = Import-FabProductListing -PluginRoot $resolvedPluginPath `
        -Configuration $configuration -ListingPath $listingPath
    if ([string]$listing.ProductVersion -cne $descriptor.VersionName) {
        throw 'listing version must exactly match the plugin descriptor VersionName.'
    }
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
    $sessionRoot = Get-FabProductSessionRoot -ProductRoot $productRoot
    $releasesRoot = Join-Path $sessionRoot 'releases'
    $validationRoot = Join-Path $sessionRoot 'submission-validation'
    $stagingRoot = Join-Path $sessionRoot 'FabSubmission'
    $publicBundle = Join-Path $productRoot 'FabSubmission'
    [System.IO.Directory]::CreateDirectory($productRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($releasesRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($validationRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    $releaseResults = [System.Collections.Generic.List[object]]::new()
    $submissionOutputs = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($engineVersion in $engineVersions) {
            $versionOutput = Join-Path $releasesRoot "UE$engineVersion"
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
            $validationOutput = Join-Path $validationRoot "UE$engineVersion"
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

        $projectLinkState = Resolve-FabProductProjectFileLink -Listing $listing `
            -EngineVersions $engineVersions -PublishProjectFiles:$PublishProjectFiles `
            -PluginRoot $resolvedPluginPath -Configuration $configuration `
            -Releases $releaseResults.ToArray() -ProductVersion $descriptor.VersionName
        $projectFileLinks = $projectLinkState.Links

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
        $packageManifest = @(Copy-FabProductPackage -Releases $releaseResults.ToArray() `
            -BundleRoot $stagingRoot -ProjectFileLinks $projectFileLinks)
        $manifest = [ordered]@{
            schemaVersion            = 2
            pluginName               = [string]$configuration.pluginName
            productVersion           = $descriptor.VersionName
            listingId                = $listing.ListingId
            title                    = $listing.Title
            shortDescription         = $listing.ShortDescription
            longDescription          = $listing.LongDescription
            productType              = $listing.ProductType
            category                 = $listing.Category
            subcategory              = @($listing.Subcategory)
            tags                     = @($listing.Tags)
            includedFormat           = $listing.IncludedFormat
            engineVersions           = @($engineVersions)
            platforms                = @($listing.Platforms)
            license                  = $listing.License
            personalPriceUsd         = $listing.PersonalPriceUsd
            professionalPriceUsd     = $listing.ProfessionalPriceUsd
            matureContent            = $listing.MatureContent
            generatedWithAi          = $listing.GeneratedWithAi
            allowsUsageWithAi        = $listing.AllowsUsageWithAi
            promotionalContent       = $listing.PromotionalContent
            forumPost                = $listing.ForumPost
            activation               = $listing.Activation
            documentationUrl         = $listing.DocumentationUrl
            supportUrl               = $listing.SupportUrl
            sourceRepositoryUrl      = $listing.SourceRepositoryUrl
            technicalInformationFile = 'submission/FabTechnicalInformation.txt'
            media                    = @($mediaManifest)
            packages                 = @($packageManifest)
            portalReady              = [bool]$projectLinkState.Verified
            generatedAtUtc           = [DateTimeOffset]::UtcNow.ToString('O')
        }
        $manifestPath = Join-Path $stagingRoot 'FabPortalSubmission.json'
        Write-FabProductTextFile -Path $manifestPath `
            -Text (($manifest | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
        Write-FabProductChecklist -Path (Join-Path $stagingRoot 'SubmissionChecklist.txt') `
            -EngineVersions $engineVersions -Media @($listing.Media) `
            -ProjectLinks $projectFileLinks -PortalReady $projectLinkState.Verified

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
    catch {
        $failureMessage = $_.Exception.Message
        $failureRoot = Join-Path $productRoot "failures\$([guid]::NewGuid().ToString('D'))"
        try {
            [void](Copy-FabProductFailureDiagnostic -SessionRoot $sessionRoot `
                -FailureRoot $failureRoot -Message $failureMessage)
        }
        catch {
            $failureMessage = "$failureMessage`nUnable to copy failure diagnostics: $($_.Exception.Message)"
        }
        throw "$failureMessage`nFailure diagnostics: $failureRoot"
    }
    finally {
        if (-not $KeepWorkingDirectory) {
            Remove-FabProductDirectory -Path $sessionRoot -Confirm:$false
            $sessionsRoot = Join-Path $productRoot '.sessions'
            if ([System.IO.Directory]::Exists($sessionsRoot) -and
                @(Get-ChildItem -LiteralPath $sessionsRoot -Force).Count -eq 0) {
                Remove-FabProductDirectory -Path $sessionsRoot -Confirm:$false
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $arguments = @{
            PluginPath           = $PluginPath
            KeepWorkingDirectory = $KeepWorkingDirectory
            PublishProjectFiles  = $PublishProjectFiles
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
