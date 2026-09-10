# Copyright (c) 2026 metyatech. All rights reserved.

<##
.SYNOPSIS
Creates a local, technically validated Fab marketing-media review.

.EXAMPLE
pwsh .\New-FabMediaReview.ps1 -PluginPath ..\MyPlugin
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [string]$ListingFieldsPath,

    [string]$OutputDirectory,

    [switch]$NoOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabSubmissionCommon.ps1')
[void]$PluginPath
[void]$ListingFieldsPath
[void]$OutputDirectory
[void]$NoOpen

function Invoke-FabMediaReviewCommand {
    $review = New-FabMediaReviewArtifact -PluginPath $PluginPath `
        -ListingFieldsPath $ListingFieldsPath -OutputDirectory $OutputDirectory
    if (-not $NoOpen) {
        Start-Process -FilePath $review.HtmlPath | Out-Null
    }
    Write-Output "MEDIA_REVIEW=PASS"
    Write-Output "MEDIA_TECHNICAL=PASS"
    Write-Output "MEDIA_APPROVAL=PENDING"
    Write-Output "APPROVED=false"
    Write-Output "REVIEW_ID=$($review.ReviewId)"
    Write-Output "REVIEW_MANIFEST=$($review.ManifestPath)"
    Write-Output "REVIEW_HTML=$($review.HtmlPath)"
    Write-Output "MEDIA_COUNT=$($review.MediaCount)"
    return $review
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $output = @(Invoke-FabMediaReviewCommand)
        $output | Where-Object { $_ -is [string] } | Write-Output
        exit 0
    }
    catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        Write-Output 'MEDIA_REVIEW=FAIL'
        exit 1
    }
}
