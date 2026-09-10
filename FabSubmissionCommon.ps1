# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FabMediaMaximumFileBytes = 3000000L
$script:FabMediaMaximumTotalBytes = 25000000L

function ConvertTo-FabSubmissionJsonText {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    return (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
}

function Write-FabSubmissionAtomicText {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Text
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Cannot determine output directory: $resolvedPath"
    }
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporaryPath = "$resolvedPath.__tmp_$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($resolvedPath)) {
            $backupPath = "$resolvedPath.__bak_$([guid]::NewGuid().ToString('N'))"
            try {
                [System.IO.File]::Replace($temporaryPath, $resolvedPath, $backupPath)
            }
            finally {
                if ([System.IO.File]::Exists($backupPath)) {
                    [System.IO.File]::SetAttributes($backupPath, [System.IO.FileAttributes]::Normal)
                    [System.IO.File]::Delete($backupPath)
                }
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $resolvedPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::SetAttributes($temporaryPath, [System.IO.FileAttributes]::Normal)
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Assert-FabSubmissionPluginRoot {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath
    )

    $resolved = [System.IO.Path]::GetFullPath($PluginPath).TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($resolved)) {
        throw "PluginPath is not a directory: $resolved"
    }
    $current = $resolved
    while ($true) {
        if (([System.IO.File]::GetAttributes($current) -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "PluginPath path chain contains a reparse point: $current"
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            break
        }
        $current = $parent.FullName.TrimEnd('\', '/')
        if ($current.Equals([System.IO.Path]::GetPathRoot($resolved).TrimEnd('\', '/'),
                [System.StringComparison]::OrdinalIgnoreCase)) {
            if (([System.IO.File]::GetAttributes($current) -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "PluginPath path chain contains a reparse point: $current"
            }
            break
        }
    }
    return $resolved
}

function Assert-FabSubmissionRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [switch]$RequireFile
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Path must be relative and must not contain '..': $RelativePath"
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $candidate.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($rootPath + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the plugin root: $RelativePath"
    }
    $relative = [System.IO.Path]::GetRelativePath($rootPath, $candidate)
    $current = $rootPath
    foreach ($segment in @($relative.Split([char[]]@('\', '/'),
                [System.StringSplitOptions]::RemoveEmptyEntries))) {
        $current = Join-Path $current $segment
        if (-not ([System.IO.File]::Exists($current) -or [System.IO.Directory]::Exists($current))) {
            throw "Path does not exist: $RelativePath"
        }
        if (([System.IO.File]::GetAttributes($current) -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Path passes through a reparse point: $RelativePath"
        }
    }
    if ($RequireFile -and -not [System.IO.File]::Exists($candidate)) {
        throw "File is missing: $RelativePath"
    }
    return $candidate
}

function Get-FabImageDimension {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not $IsWindows) {
        throw 'Fab media validation requires Windows System.Drawing support.'
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bitmap = [System.Drawing.Bitmap]::new($Path)
        try {
            return [pscustomobject]@{ Width = $bitmap.Width; Height = $bitmap.Height }
        }
        finally {
            $bitmap.Dispose()
        }
    }
    catch {
        throw "Unable to decode image '$Path': $($_.Exception.Message)"
    }
}

function Get-FabMediaTechnicalManifest {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath,

        [Parameter(Mandatory)]
        [object[]]$MediaOrder
    )

    $root = Assert-FabSubmissionPluginRoot -PluginPath $PluginPath
    if ($MediaOrder.Count -lt 2) {
        throw 'media_order must contain at least one thumbnail and one gallery image.'
    }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $seenHashes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $items = [System.Collections.Generic.List[object]]::new()
    [long]$totalBytes = 0
    $order = 1
    foreach ($entryValue in $MediaOrder) {
        if ($entryValue -isnot [string]) {
            throw 'media_order must contain only strings.'
        }
        $relative = ([string]$entryValue).Replace('\', '/')
        if (-not $seenPaths.Add($relative)) {
            throw "media_order contains a duplicate entry: $entryValue"
        }
        $sourcePath = Assert-FabSubmissionRelativePath -Root $root -RelativePath $relative -RequireFile
        $extension = [System.IO.Path]::GetExtension($sourcePath).ToLowerInvariant()
        if ($extension -notin @('.jpg', '.jpeg', '.png')) {
            throw "Unsupported media format: $relative"
        }
        $file = [System.IO.FileInfo]::new($sourcePath)
        if ($file.Length -ge $script:FabMediaMaximumFileBytes) {
            throw "Media file must be strictly less than 3,000,000 bytes: $relative"
        }
        $totalBytes += $file.Length
        if ($totalBytes -ge $script:FabMediaMaximumTotalBytes) {
            throw 'All 2D media combined must be strictly less than 25,000,000 bytes.'
        }
        $dimensions = Get-FabImageDimension -Path $sourcePath
        if ($dimensions.Width -lt 1920 -or $dimensions.Height -lt 1080) {
            throw "Media dimensions must be at least 1920x1080: $relative ($($dimensions.Width)x$($dimensions.Height))"
        }
        $hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $seenHashes.Add($hash)) {
            throw "media_order contains duplicate image bytes: $relative"
        }
        $items.Add([pscustomobject][ordered]@{
                RelativePath = $relative
                Role         = if ($order -eq 1) { 'thumbnail' } else { 'gallery' }
                Order        = $order
                FileName     = [System.IO.Path]::GetFileName($relative)
                Extension    = $extension
                Width        = [int]$dimensions.Width
                Height       = [int]$dimensions.Height
                SizeBytes    = [long]$file.Length
                Sha256       = $hash
                SourcePath   = $sourcePath
            })
        $order++
    }
    return $items.ToArray()
}

function Read-FabSubmissionJson {
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

function Assert-FabSubmissionSchema {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SchemaPath,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $json = [System.IO.File]::ReadAllText($Path)
    try {
        if (-not ($json | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) {
            throw 'Schema validation returned false.'
        }
    }
    catch {
        throw "$Description does not conform to ${SchemaPath}: $($_.Exception.Message)"
    }
}

function Get-FabSubmissionListingData {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath,

        [string]$ListingFieldsPath
    )

    $root = Assert-FabSubmissionPluginRoot -PluginPath $PluginPath
    $path = if ([string]::IsNullOrWhiteSpace($ListingFieldsPath)) {
        Join-Path $root 'FabListingFields.json'
    }
    else {
        [System.IO.Path]::GetFullPath($ListingFieldsPath)
    }
    Assert-FabSubmissionSchema -Path $path `
        -SchemaPath (Join-Path $PSScriptRoot 'FabListingFields.schema.json') `
        -Description 'Listing fields'
    $listing = Read-FabSubmissionJson -Path $path
    if ($null -eq $listing.PSObject.Properties['media_order'] -or
        $listing.media_order -isnot [System.Array]) {
        throw 'Listing media_order must be a JSON array.'
    }
    $media = @(Get-FabMediaTechnicalManifest -PluginPath $root -MediaOrder @($listing.media_order))
    return [pscustomobject]@{
        Root    = $root
        Path    = $path
        Listing = $listing
        Media   = $media
    }
}

function New-FabMediaReviewArtifact {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath,

        [string]$ListingFieldsPath,

        [string]$OutputDirectory
    )

    $data = Get-FabSubmissionListingData -PluginPath $PluginPath -ListingFieldsPath $ListingFieldsPath
    $reviewId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $base = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Join-Path ([System.IO.Path]::GetTempPath()) "FabMediaReview\$([System.IO.Path]::GetFileName($data.Root))"
    }
    else {
        [System.IO.Path]::GetFullPath($OutputDirectory)
    }
    if ($base.TrimEnd('\', '/').Equals($data.Root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $base.StartsWith($data.Root + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputDirectory must not be the product repository or a child of it.'
    }
    $reviewRoot = Join-Path $base $reviewId
    if (-not $PSCmdlet.ShouldProcess($reviewRoot, 'Create Fab media review')) {
        return
    }
    [System.IO.Directory]::CreateDirectory((Join-Path $reviewRoot 'media')) | Out-Null
    $reviewMedia = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $data.Media) {
        $reviewName = '{0:D3}_{1}' -f $item.Order, $item.FileName
        $destination = Join-Path (Join-Path $reviewRoot 'media') $reviewName
        [System.IO.File]::Copy($item.SourcePath, $destination, $false)
        $copiedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($copiedHash -cne $item.Sha256 -or ([System.IO.FileInfo]::new($destination)).Length -ne $item.SizeBytes) {
            throw "Review copy integrity check failed: $($item.RelativePath)"
        }
        $reviewMedia.Add([ordered]@{
                order        = [int]$item.Order
                role         = [string]$item.Role
                relativePath = [string]$item.RelativePath
                fileName     = [string]$item.FileName
                width        = [int]$item.Width
                height       = [int]$item.Height
                sizeBytes    = [long]$item.SizeBytes
                sha256       = [string]$item.Sha256
                reviewPath   = "media/$reviewName"
            })
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        reviewId      = $reviewId
        product       = [string]$data.Listing.product
        version       = [string]$data.Listing.version
        createdAtUtc  = [DateTimeOffset]::UtcNow.ToString('O')
        media         = $reviewMedia.ToArray()
    }
    $manifestPath = Join-Path $reviewRoot 'FabMediaReview.json'
    Write-FabSubmissionAtomicText -Path $manifestPath `
        -Text (ConvertTo-FabSubmissionJsonText -Value $manifest)

    $htmlParts = [System.Collections.Generic.List[string]]::new()
    $htmlParts.Add('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Fab Media Review</title>')
    $htmlParts.Add('<style>body{font-family:system-ui,sans-serif;margin:2rem;background:#f6f7f9;color:#18202a}main{max-width:1200px;margin:auto}article{background:white;padding:1rem;margin:1rem 0;border:1px solid #ccd2da;border-radius:8px}img{display:block;max-width:100%;height:auto}a{display:block}code{overflow-wrap:anywhere}.warning{padding:1rem;border:2px solid #8b1e1e;background:#fff3f3;font-weight:700}</style></head><body><main>')
    $htmlParts.Add('<h1>Fab Media Review</h1><div class="warning">These images are technically valid but NOT approved. Only the human reviewer can approve them. Any media byte change invalidates approval.</div>')
    $htmlParts.Add("<p>Product: $([System.Net.WebUtility]::HtmlEncode([string]$data.Listing.product)) &middot; Version: $([System.Net.WebUtility]::HtmlEncode([string]$data.Listing.version))</p>")
    foreach ($item in $reviewMedia) {
        $safeName = [System.Net.WebUtility]::HtmlEncode([string]$item.fileName)
        $safeReviewPath = [System.Net.WebUtility]::HtmlEncode([string]$item.reviewPath)
        $role = [System.Net.WebUtility]::HtmlEncode([string]$item.role)
        $htmlParts.Add(('<article><h2>Order {0} &mdash; {1}</h2><p><strong>{2}</strong><br>{3}x{4} &middot; {5} bytes<br><code>{6}</code></p><a href="{7}"><img src="{7}" alt="Order {0} {2}"></a><p>Click the image to open the original-size review copy.</p></article>' -f $item.order, $role, $safeName, $item.width, $item.height, $item.sizeBytes, $item.sha256, $safeReviewPath))
    }
    $htmlParts.Add('</main></body></html>')
    $htmlPath = Join-Path $reviewRoot 'index.html'
    Write-FabSubmissionAtomicText -Path $htmlPath -Text ([string]::Join("`n", $htmlParts))
    return [pscustomobject]@{
        ReviewId       = $reviewId
        ReviewRoot     = $reviewRoot
        ManifestPath   = $manifestPath
        HtmlPath       = $htmlPath
        MediaCount     = $data.Media.Count
        Media          = $data.Media
        Product        = [string]$data.Listing.product
        Version        = [string]$data.Listing.version
        Approved       = $false
    }
}

function Compare-FabSubmissionMedia {
    param(
        [Parameter(Mandatory)]
        [object[]]$Expected,

        [Parameter(Mandatory)]
        [object[]]$Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw 'Media order/count differs from the reviewed manifest.'
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        $expectedItem = $Expected[$index]
        $actualItem = $Actual[$index]
        foreach ($property in @('order', 'role', 'relativePath', 'width', 'height', 'sizeBytes', 'sha256')) {
            if ([string]$expectedItem.$property -cne [string]$actualItem.$property) {
                throw "Media $($index + 1) differs in $property."
            }
        }
    }
}

function Get-FabMediaApprovalStatus {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath,

        [Parameter(Mandatory)]
        [object[]]$CurrentMedia,

        [string]$ApprovalPath
    )

    $root = Assert-FabSubmissionPluginRoot -PluginPath $PluginPath
    $path = if ([string]::IsNullOrWhiteSpace($ApprovalPath)) {
        Join-Path $root 'FabMediaApproval.json'
    }
    else {
        [System.IO.Path]::GetFullPath($ApprovalPath)
    }
    if (-not [System.IO.File]::Exists($path)) {
        return [pscustomobject]@{ Status = 'pending'; Valid = $false; ReviewId = $null; Path = $path }
    }
    Assert-FabSubmissionSchema -Path $path `
        -SchemaPath (Join-Path $PSScriptRoot 'FabMediaApproval.schema.json') `
        -Description 'FabMediaApproval'
    $approval = Read-FabSubmissionJson -Path $path
    if ($approval.product -isnot [string] -or $approval.version -isnot [string]) {
        throw 'FabMediaApproval product/version are invalid.'
    }
    $listingPath = Join-Path $root 'FabListingFields.json'
    $listing = Read-FabSubmissionJson -Path $listingPath
    if ([string]$approval.product -cne [string]$listing.product -or
        [string]$approval.version -cne [string]$listing.version) {
        throw 'FabMediaApproval product/version does not match the current listing.'
    }
    $current = @($CurrentMedia | ForEach-Object {
            [pscustomobject]@{
                order        = [int]$_.Order
                role         = [string]$_.Role
                relativePath = [string]$_.RelativePath
                width        = [int]$_.Width
                height       = [int]$_.Height
                sizeBytes    = [long]$_.SizeBytes
                sha256       = [string]$_.Sha256
            }
        })
    try {
        Compare-FabSubmissionMedia -Expected @($approval.media) -Actual $current
    }
    catch {
        return [pscustomobject]@{
            Status   = 'stale'
            Valid    = $false
            ReviewId = [string]$approval.reviewId
            Path     = $path
        }
    }
    return [pscustomobject]@{
        Status   = 'approved'
        Valid    = $true
        ReviewId = [string]$approval.reviewId
        Path     = $path
    }
}

function Assert-FabProjectFilePublishingConfiguration {
    param(
        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $property = $Configuration.PSObject.Properties['projectFilePublishing']
    if ($null -eq $property -or $null -eq $property.Value) {
        throw 'PROJECT_FILE_PUBLISHING_NOT_CONFIGURED'
    }
    $publishing = $property.Value
    if ([string]$publishing.provider -cne 'CloudflareR2') {
        throw 'projectFilePublishing.provider must be exactly CloudflareR2.'
    }
    $r2 = $publishing.cloudflareR2
    if ($null -eq $r2 -or [string]::IsNullOrWhiteSpace([string]$r2.bucket)) {
        throw 'projectFilePublishing.cloudflareR2.bucket must be non-blank.'
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$r2.publicBaseUrl, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        throw 'projectFilePublishing.cloudflareR2.publicBaseUrl must be an absolute HTTPS URL.'
    }
    $prefix = [string]$r2.objectPrefix
    if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix.StartsWith('/') -or
        $prefix.EndsWith('/') -or $prefix.Contains('\') -or
        $prefix -match '(^|/)\.\.(/|$)' -or $prefix -match '^[A-Za-z]:') {
        throw 'projectFilePublishing.cloudflareR2.objectPrefix must be a relative POSIX-style key prefix.'
    }
    return [pscustomobject]@{
        Provider      = 'CloudflareR2'
        Bucket        = [string]$r2.bucket
        PublicBaseUrl = ([string]$r2.publicBaseUrl).TrimEnd('/')
        ObjectPrefix  = $prefix.TrimEnd('/')
    }
}
