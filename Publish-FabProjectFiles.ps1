# Copyright (c) 2026 metyatech. All rights reserved.

<##
.SYNOPSIS
Publishes canonical product ZIPs to an already configured Cloudflare R2 bucket.

.EXAMPLE
pwsh .\Publish-FabProjectFiles.ps1 -PluginPath ..\MyPlugin -UpdateListingFields
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [string]$EngineRoot,

    [string]$ListingFieldsPath,

    [string]$OutputDirectory,

    [switch]$UpdateListingFields
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabSubmissionCommon.ps1')
[void]$PluginPath
[void]$EngineRoot
[void]$ListingFieldsPath
[void]$OutputDirectory
[void]$UpdateListingFields
. (Join-Path $PSScriptRoot 'Invoke-FabProductRelease.ps1') `
    -PluginPath $PluginPath -EngineRoot $EngineRoot -ListingFieldsPath $ListingFieldsPath `
    -OutputDirectory $OutputDirectory -KeepWorkingDirectory:$false

function Get-FabR2Wrangler {
    $command = Get-Command wrangler -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command wrangler.cmd -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($null -eq $command) {
        throw 'WRANGLER_NOT_AVAILABLE'
    }
    return $command.Source
}

function Invoke-FabR2Wrangler {
    param(
        [Parameter(Mandatory)]
        [string]$WranglerPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $WranglerPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start Wrangler.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))
        if ($process.ExitCode -ne 0) {
            throw "Wrangler failed with exit code $($process.ExitCode): $($stderr.Result.Trim())"
        }
        return [pscustomobject]@{ Output = [string]$stdout.Result; Error = [string]$stderr.Result }
    }
    finally { $process.Dispose() }
}

function Get-FabR2RemoteObject {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    $response = $null
    try {
        $response = $client.Send($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if ([int]$response.StatusCode -eq 404) {
            return [pscustomobject]@{ StatusCode = 404; Bytes = 0L; Sha256 = $null }
        }
        if (-not $response.IsSuccessStatusCode) {
            return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Bytes = 0L; Sha256 = $null }
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $buffer = [byte[]]::new(1048576)
        [long]$bytes = 0
        $stream = $response.Content.ReadAsStream()
        try {
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $sha.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
                $bytes += $read
            }
            $sha.TransformFinalBlock([byte[]]::new(0), 0, 0) | Out-Null
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Bytes      = $bytes
                Sha256     = [System.Convert]::ToHexString($sha.Hash).ToLowerInvariant()
            }
        }
        finally { $stream.Dispose(); $sha.Dispose() }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose(); $client.Dispose()
    }
}

function Assert-FabR2BucketAccess {
    param(
        [Parameter(Mandatory)]
        [object]$Publishing
    )

    $wrangler = Get-FabR2Wrangler
    try {
        $result = Invoke-FabR2Wrangler -WranglerPath $wrangler -Arguments @('r2', 'bucket', 'list', '--json')
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)unknown argument:\s*json') {
            throw "CLOUDFLARE_AUTH_REQUIRED: $($_.Exception.Message)"
        }
        try {
            $result = Invoke-FabR2Wrangler -WranglerPath $wrangler -Arguments @('r2', 'bucket', 'list')
        }
        catch {
            throw "CLOUDFLARE_AUTH_REQUIRED: $($_.Exception.Message)"
        }
        $bucketNames = @(
            [regex]::Matches(
                $result.Output,
                '(?im)^\s*name:\s*(\S+)\s*$') |
                ForEach-Object { $_.Groups[1].Value }
        )
        if ($bucketNames.Count -ne 1 -or $bucketNames[0] -cne [string]$Publishing.Bucket) {
            throw "CLOUDFLARE_BUCKET_MISMATCH: configured bucket '$($Publishing.Bucket)' was not found."
        }
        return $wrangler
    }
    try { $buckets = @($result.Output | ConvertFrom-Json -Depth 20) }
    catch { throw 'CLOUDFLARE_AUTH_REQUIRED: Wrangler bucket list was not valid JSON.' }
    if (@($buckets | Where-Object { [string]$_.name -ceq $Publishing.Bucket }).Count -ne 1) {
        throw "CLOUDFLARE_BUCKET_MISMATCH: configured bucket '$($Publishing.Bucket)' was not found."
    }
    return $wrangler
}

function Get-FabR2ObjectKey {
    param(
        [Parameter(Mandatory)]
        [object]$Publishing,

        [Parameter(Mandatory)]
        [string]$ProductVersion,

        [Parameter(Mandatory)]
        [string]$EngineVersion,

        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string]$Sha256
    )

    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Invalid SHA-256 for R2 object key: $Sha256"
    }
    return "$($Publishing.ObjectPrefix)/$ProductVersion/UE$EngineVersion/$($Sha256.ToLowerInvariant())/$FileName"
}

function New-FabR2PublicationListingFile {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [object]$Listing,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $publicationListing = [ordered]@{}
    foreach ($property in $Listing.PSObject.Properties) {
        if ($property.Name -cne 'project_file_links' -and
            $property.Name -cne 'project_file_link') {
            $publicationListing[$property.Name] = $property.Value
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write publication listing copy')) {
        return $Path
    }
    Write-FabSubmissionAtomicText -Path $Path `
        -Text (ConvertTo-FabSubmissionJsonText -Value ([pscustomobject]$publicationListing))
    return $Path
}

function Update-FabR2ListingLinkSet {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [string]$ListingPath,

        [Parameter(Mandatory)]
        [object]$Listing,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Links,

        [Parameter(Mandatory)]
        [string[]]$EngineVersions
    )

    $existing = $Listing.PSObject.Properties['project_file_links']
    if ($null -ne $existing) {
        $existingNames = if ($null -eq $existing.Value) { @() } else { @($existing.Value.PSObject.Properties.Name) }
        if ($existingNames.Count -ne $EngineVersions.Count -or
            @($EngineVersions | Where-Object { $existingNames -cnotcontains $_ }).Count -gt 0) {
            throw 'Existing project_file_links do not contain exactly the generated engine set.'
        }
        $linksMatch = $true
        foreach ($version in $EngineVersions) {
            if ([string]$existing.Value.$version -cne [string]$Links[$version]) {
                $linksMatch = $false
                break
            }
        }
        if ($linksMatch) { return 'NOOP' }
    }
    if (-not $PSCmdlet.ShouldProcess($ListingPath, 'Write verified R2 project file links')) {
        return 'SKIPPED'
    }
    $ordered = [ordered]@{}
    foreach ($version in $EngineVersions) { $ordered[$version] = [string]$Links[$version] }
    if ($null -eq $existing) {
        Add-Member -InputObject $Listing -NotePropertyName project_file_links -NotePropertyValue $ordered
    }
    else {
        $Listing.project_file_links = $ordered
    }
    Write-FabSubmissionAtomicText -Path $ListingPath `
        -Text (ConvertTo-FabSubmissionJsonText -Value $Listing)
    if ($null -eq $existing) { return 'WRITTEN' }
    return 'UPDATED'
}

function Invoke-FabProjectFilePublication {
    $root = Assert-FabSubmissionPluginRoot -PluginPath $PluginPath
    $configPath = Join-Path $root 'FabPluginRelease.json'
    Assert-FabSubmissionSchema -Path $configPath `
        -SchemaPath (Join-Path $PSScriptRoot 'FabPluginRelease.schema.json') `
        -Description 'Configuration'
    $configuration = Read-FabSubmissionJson -Path $configPath
    $publishing = Assert-FabProjectFilePublishingConfiguration -Configuration $configuration
    $listingData = Get-FabSubmissionListingData -PluginPath $root -ListingFieldsPath $ListingFieldsPath
    $engineVersions = @($configuration.engineVersions | ForEach-Object { [string]$_ } |
        Sort-Object { [version]$_ })
    $sessionBase = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Join-Path ([System.IO.Path]::GetTempPath()) 'FabProjectFilePublication'
    }
    else { [System.IO.Path]::GetFullPath($OutputDirectory) }
    $sessionRoot = Join-Path $sessionBase "$([System.IO.Path]::GetFileName($root))\$([guid]::NewGuid().ToString('D'))"
    $buildRoot = Join-Path $sessionRoot 'canonical-release'
    [System.IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
    try {
        $releaseListingPath = Join-Path $sessionRoot 'FabListingFields.ForPublication.json'
        [void](New-FabR2PublicationListingFile -Listing $listingData.Listing -Path $releaseListingPath)
        $releaseArguments = @{
            PluginPath        = $root
            ListingFieldsPath = $releaseListingPath
            OutputDirectory   = $buildRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($EngineRoot)) { $releaseArguments.EngineRoot = $EngineRoot }
        $releaseResult = Invoke-FabProductReleaseCore @releaseArguments
        $manifest = $releaseResult.Manifest
        $wrangler = Assert-FabR2BucketAccess -Publishing $publishing
        $published = [System.Collections.Generic.List[object]]::new()
        $links = [ordered]@{}
        foreach ($package in @($manifest.packages)) {
            $engineVersion = [string]$package.engineVersion
            if ($engineVersions -cnotcontains $engineVersion) { throw "Unexpected engine version in release manifest: $engineVersion" }
            $relative = [string]$package.bundleRelativePath
            if ($relative -notmatch '^packages/UE5\.[0-9]+/[^/]+\.zip$') {
                throw "Release manifest package path is not canonical: $relative"
            }
            $zipPath = Join-Path $releaseResult.BundlePath ($relative.Replace('/', '\'))
            if (-not [System.IO.File]::Exists($zipPath)) { throw "Manifest package file is missing: $relative" }
            $localFile = [System.IO.FileInfo]::new($zipPath)
            $localHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($localHash -cne ([string]$package.sha256).ToLowerInvariant()) { throw "Manifest package hash mismatch: $relative" }
            $fileName = [System.IO.Path]::GetFileName($zipPath)
            $objectKey = Get-FabR2ObjectKey -Publishing $publishing `
                -ProductVersion ([string]$manifest.productVersion) -EngineVersion $engineVersion `
                -FileName $fileName -Sha256 $localHash
            $url = "$($publishing.PublicBaseUrl)/$objectKey"
            $remote = Get-FabR2RemoteObject -Url $url
            $action = $null
            if ($remote.StatusCode -eq 404) {
                [void](Invoke-FabR2Wrangler -WranglerPath $wrangler -Arguments @(
                        'r2', 'object', 'put', "$($publishing.Bucket)/$objectKey", '--file', $zipPath,
                        '--remote', '--content-type', 'application/zip'))
                $action = 'UPLOADED'
                $remote = Get-FabR2RemoteObject -Url $url
            }
            elseif ($remote.StatusCode -eq 200) {
                if ($remote.Bytes -ne $localFile.Length -or $remote.Sha256 -cne $localHash) {
                    throw "R2 object exists with different bytes: $objectKey"
                }
                $action = 'REUSED'
            }
            else { throw "R2 object preflight returned HTTP $($remote.StatusCode): $objectKey" }
            if ($remote.StatusCode -ne 200 -or $remote.Bytes -ne $localFile.Length -or
                $remote.Sha256 -cne $localHash) {
                throw "R2 object verification failed after publication: $objectKey"
            }
            $links[$engineVersion] = $url
            $published.Add([ordered]@{
                    engineVersion = $engineVersion
                    sha256        = $localHash
                    sizeBytes     = [long]$localFile.Length
                    objectKey     = $objectKey
                    url           = $url
                    action        = $action
                })
        }
        if ($published.Count -ne $engineVersions.Count) { throw 'R2 publication did not cover every engine version.' }
        $report = [ordered]@{
            schemaVersion = 1
            product       = [string]$manifest.pluginName
            version       = [string]$manifest.productVersion
            provider      = 'CloudflareR2'
            publicBaseUrl = $publishing.PublicBaseUrl
            packages      = $published.ToArray()
        }
        $reportPath = Join-Path $sessionRoot 'FabProjectFilePublication.json'
        Write-FabSubmissionAtomicText -Path $reportPath `
            -Text (ConvertTo-FabSubmissionJsonText -Value $report)
        $listingAction = 'SKIPPED'
        if ($UpdateListingFields) {
            $listingAction = Update-FabR2ListingLinkSet -ListingPath $listingData.Path `
                -Listing $listingData.Listing -Links $links -EngineVersions $engineVersions
        }
        Write-Output 'R2_PUBLICATION=PASS'
        Write-Output "R2_REPORT=$reportPath"
        Write-Output "LISTING_ACTION=$listingAction"
        return [pscustomobject]@{ ReportPath = $reportPath; Report = $report; ListingAction = $listingAction }
    }
    finally {
        if ([System.IO.Directory]::Exists($buildRoot)) {
            [System.IO.Directory]::Delete($buildRoot, $true)
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $output = @(Invoke-FabProjectFilePublication)
        $output | Where-Object { $_ -is [string] } | Write-Output
        exit 0
    }
    catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        Write-Output 'R2_PUBLICATION=FAIL'
        exit 1
    }
}
