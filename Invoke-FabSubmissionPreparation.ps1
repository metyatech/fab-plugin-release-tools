# Copyright (c) 2026 metyatech. All rights reserved.

<##
.SYNOPSIS
Advances a product through the guarded Fab submission-preparation state machine.

.EXAMPLE
pwsh .\Invoke-FabSubmissionPreparation.ps1 -PluginPath ..\MyPlugin
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [string]$EngineRoot,

    [string]$ListingFieldsPath,

    [string]$OutputDirectory,

    [switch]$NoOpenMediaReview,

    [switch]$KeepWorkingDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabSubmissionCommon.ps1')
. (Join-Path $PSScriptRoot 'Invoke-FabProductRelease.ps1') `
    -PluginPath $PluginPath -EngineRoot $EngineRoot -ListingFieldsPath $ListingFieldsPath `
    -OutputDirectory $OutputDirectory -KeepWorkingDirectory:$KeepWorkingDirectory
[void]$EngineRoot
[void]$ListingFieldsPath
[void]$OutputDirectory
[void]$NoOpenMediaReview
[void]$KeepWorkingDirectory

function Invoke-FabPreparationGitStatus {
    param([Parameter(Mandatory)] [string]$Root)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command git -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $Root, 'status', '--short', '--untracked-files=all')) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start Git.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))
        if ($process.ExitCode -ne 0) { throw "Git status failed: $($stderr.Result.Trim())" }
        return [string]$stdout.Result
    }
    finally { $process.Dispose() }
}

function Get-FabPreparationReportPath {
    param([string]$Base, [string]$PluginName)

    $root = if ([string]::IsNullOrWhiteSpace($Base)) {
        Join-Path ([System.IO.Path]::GetTempPath()) 'FabSubmissionPreparation'
    }
    else { [System.IO.Path]::GetFullPath($Base) }
    $path = Join-Path $root "$PluginName\$([guid]::NewGuid().ToString('D'))"
    [System.IO.Directory]::CreateDirectory($path) | Out-Null
    return Join-Path $path 'FabSubmissionPreparation.json'
}

function Write-FabPreparationResult {
    param(
        [Parameter(Mandatory)] [object]$Result,
        [Parameter(Mandatory)] [string]$ReportPath
    )

    Write-FabSubmissionAtomicText -Path $ReportPath `
        -Text (ConvertTo-FabSubmissionJsonText -Value $Result)
    $consoleProperties = [ordered]@{
        STATE = 'state'
        RESULT = 'result'
        BLOCKER = 'blocker'
        NEXT_ACTION = 'nextAction'
        REPORT_PATH = 'reportPath'
    }
    foreach ($property in $consoleProperties.Keys) {
        $source = $consoleProperties[$property]
        if ($Result -is [System.Collections.IDictionary] -and $Result.Contains($source)) {
            Write-Output "$property=$($Result[$source])"
        }
    }
    return $Result
}

function Invoke-FabSubmissionPreparationCommand {
    $root = Assert-FabSubmissionPluginRoot -PluginPath $PluginPath
    $configPath = Join-Path $root 'FabPluginRelease.json'
    $configuration = Import-FabProductConfiguration -ConfigPath $configPath
    $descriptor = Get-FabProductDescriptor -PluginRoot $root -Configuration $configuration
    $listingPath = if ([string]::IsNullOrWhiteSpace($ListingFieldsPath)) {
        Join-Path $root 'FabListingFields.json'
    }
    else { [System.IO.Path]::GetFullPath($ListingFieldsPath) }
    $listing = Import-FabProductListing -PluginRoot $root `
        -Configuration $configuration -ListingPath $listingPath
    $reportPath = Get-FabPreparationReportPath -Base $OutputDirectory `
        -PluginName ([string]$configuration.pluginName)
    $status = Invoke-FabPreparationGitStatus -Root $root
    $unexpected = @($status -split "`r?`n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_ -notmatch '^\s*M\s+FabListingFields\.json$' -and
            $_ -notmatch '^\s*\?\?\s+FabListingFields\.json$'
        })
    if ($unexpected.Count -gt 0) {
        return Write-FabPreparationResult -ReportPath $reportPath -Result ([ordered]@{
                schemaVersion = 1; result = 'BLOCKED'; state = 'BLOCKED';
                pluginName = [string]$configuration.pluginName; productVersion = [string]$descriptor.VersionName;
                blocker = 'UNEXPECTED_WORKTREE_CHANGES'; nextAction = 'Clean unrelated worktree changes and retry.';
                reportPath = $reportPath
            })
    }
    $mediaApproval = Get-FabProductMediaApproval -PluginRoot $root -Listing $listing
    if (-not $mediaApproval.Valid) {
        $review = New-FabMediaReviewArtifact -PluginPath $root -ListingFieldsPath $listingPath `
            -OutputDirectory (Join-Path ([System.IO.Path]::GetDirectoryName($reportPath)) 'media-review')
        if (-not $NoOpenMediaReview) { Start-Process -FilePath $review.HtmlPath | Out-Null }
        return Write-FabPreparationResult -ReportPath $reportPath -Result ([ordered]@{
                schemaVersion = 1; result = 'PENDING'; state = 'MEDIA_APPROVAL_REQUIRED';
                pluginName = [string]$configuration.pluginName; productVersion = [string]$descriptor.VersionName;
                sourceCommit = $null; mediaApproval = if ($mediaApproval.Status -eq 'stale') { 'STALE' } else { 'PENDING' };
                projectFileLinksVerified = $false; listingIdPresent = $false; portalReady = $false;
                reviewId = $review.ReviewId; reviewManifest = $review.ManifestPath; reviewHtml = $review.HtmlPath;
                blocker = 'MEDIA_HUMAN_APPROVAL_REQUIRED'; nextAction = 'Human must inspect the review and explicitly approve it.';
                reportPath = $reportPath
            })
    }
    $linksPresent = $listing.ProjectFileLinks.Count -eq @($configuration.engineVersions).Count
    if (-not $linksPresent) {
        $publishingProperty = $configuration.PSObject.Properties['projectFilePublishing']
        if ($null -ne $publishingProperty) {
            . (Join-Path $PSScriptRoot 'Publish-FabProjectFiles.ps1') -PluginPath $root
            [void](Invoke-FabProjectFilePublication)
        }
        return Write-FabPreparationResult -ReportPath $reportPath -Result ([ordered]@{
                schemaVersion = 1; result = 'PENDING'; state = 'SOURCE_COMMIT_REQUIRED';
                pluginName = [string]$configuration.pluginName; productVersion = [string]$descriptor.VersionName;
                mediaApproval = 'APPROVED'; projectFileLinksVerified = $false; listingIdPresent = $false; portalReady = $false;
                blocker = 'SOURCE_COMMIT_REQUIRED'; nextAction = 'Review and commit/push the project file links, then retry.';
                reportPath = $reportPath
            })
    }
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        return Write-FabPreparationResult -ReportPath $reportPath -Result ([ordered]@{
                schemaVersion = 1; result = 'PENDING'; state = 'SOURCE_COMMIT_REQUIRED';
                pluginName = [string]$configuration.pluginName; productVersion = [string]$descriptor.VersionName;
                mediaApproval = 'APPROVED'; projectFileLinksVerified = $true; listingIdPresent = $false; portalReady = $false;
                blocker = 'SOURCE_COMMIT_REQUIRED'; nextAction = 'Commit and push the expected listing change, then retry.';
                reportPath = $reportPath
            })
    }
    $releaseArguments = @{ PluginPath = $root; KeepWorkingDirectory = $KeepWorkingDirectory }
    if (-not [string]::IsNullOrWhiteSpace($EngineRoot)) { $releaseArguments.EngineRoot = $EngineRoot }
    if (-not [string]::IsNullOrWhiteSpace($ListingFieldsPath)) { $releaseArguments.ListingFieldsPath = $ListingFieldsPath }
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $releaseArguments.OutputDirectory = Join-Path ([System.IO.Path]::GetDirectoryName($reportPath)) 'release-output'
    }
    $release = Invoke-FabProductReleaseCore @releaseArguments
    $listingIdPresent = -not [string]::IsNullOrWhiteSpace([string]$release.Manifest.listingId)
    $state = if ($listingIdPresent) { 'PORTAL_VERIFY_READY' } else { 'DRAFT_CREATION_REQUIRED' }
    return Write-FabPreparationResult -ReportPath $reportPath -Result ([ordered]@{
            schemaVersion = 1; result = 'PASS'; state = $state; pluginName = [string]$configuration.pluginName;
            productVersion = [string]$descriptor.VersionName; mediaApproval = 'APPROVED';
            projectFileLinksVerified = [bool]$release.Manifest.portalReady; listingIdPresent = $listingIdPresent;
            portalReady = [bool]$release.Manifest.portalReady; bundlePath = $release.BundlePath;
            blocker = 'none'; nextAction = if ($listingIdPresent) { 'Run read-only Fab Portal verification.' } else { 'Create the Fab Draft interactively.' };
            reportPath = $reportPath
        })
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $output = @(Invoke-FabSubmissionPreparationCommand)
        $output | Where-Object { $_ -is [string] } | Write-Output
        exit 0
    }
    catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        Write-Output 'STATE=BLOCKED'
        Write-Output 'RESULT=FAIL'
        exit 1
    }
}
