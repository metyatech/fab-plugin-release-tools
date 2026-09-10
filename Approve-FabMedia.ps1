# Copyright (c) 2026 metyatech. All rights reserved.

<##
.SYNOPSIS
Records explicit human approval for the exact reviewed media bytes.

.EXAMPLE
pwsh .\Approve-FabMedia.ps1 -PluginPath ..\MyPlugin `
  -ReviewManifestPath <review>\FabMediaReview.json -ConfirmHumanApproval
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [Parameter(Mandatory)]
    [string]$ReviewManifestPath,

    [switch]$ConfirmHumanApproval
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabSubmissionCommon.ps1')
[void]$PluginPath
[void]$ReviewManifestPath
[void]$ConfirmHumanApproval

function Invoke-FabMediaApprovalCommand {
    if (-not $ConfirmHumanApproval) {
        throw 'Explicit human approval is required. Re-run only after the human reviewer has inspected the review.'
    }
    $manifestPath = [System.IO.Path]::GetFullPath($ReviewManifestPath)
    Assert-FabSubmissionSchema -Path $manifestPath `
        -SchemaPath (Join-Path $PSScriptRoot 'FabMediaReview.schema.json') `
        -Description 'FabMediaReview'
    $review = Read-FabSubmissionJson -Path $manifestPath
    $data = Get-FabSubmissionListingData -PluginPath $PluginPath
    if ([string]$review.product -cne [string]$data.Listing.product -or
        [string]$review.version -cne [string]$data.Listing.version) {
        throw 'Review product/version does not match the current listing.'
    }
    $current = @($data.Media | ForEach-Object {
            [ordered]@{
                order        = [int]$_.Order
                role         = [string]$_.Role
                relativePath = [string]$_.RelativePath
                width        = [int]$_.Width
                height       = [int]$_.Height
                sizeBytes    = [long]$_.SizeBytes
                sha256       = [string]$_.Sha256
            }
        })
    Compare-FabSubmissionMedia -Expected @($review.media) -Actual $current
    $approvalPath = Join-Path $data.Root 'FabMediaApproval.json'
    if ([System.IO.File]::Exists($approvalPath)) {
        Assert-FabSubmissionSchema -Path $approvalPath `
            -SchemaPath (Join-Path $PSScriptRoot 'FabMediaApproval.schema.json') `
            -Description 'FabMediaApproval'
        $existing = Read-FabSubmissionJson -Path $approvalPath
        try {
            Compare-FabSubmissionMedia -Expected @($existing.media) -Actual $current
            if ([string]$existing.product -ceq [string]$data.Listing.product -and
                [string]$existing.version -ceq [string]$data.Listing.version) {
                Write-Output 'MEDIA_APPROVAL=APPROVED'
                Write-Output 'ACTION=NOOP'
                return [pscustomobject]@{ ApprovalPath = $approvalPath; Action = 'NOOP' }
            }
        }
        catch {
            Write-Verbose 'Existing approval differs; explicit confirmation allows replacement after a new review.'
        }
    }
    $approval = [ordered]@{
        schemaVersion = 1
        product       = [string]$data.Listing.product
        version       = [string]$data.Listing.version
        reviewId      = [string]$review.reviewId
        approvedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        media         = $current
    }
    Write-FabSubmissionAtomicText -Path $approvalPath `
        -Text (ConvertTo-FabSubmissionJsonText -Value $approval)
    Write-Output 'MEDIA_APPROVAL=APPROVED'
    Write-Output 'ACTION=WRITTEN'
    return [pscustomobject]@{ ApprovalPath = $approvalPath; Action = 'WRITTEN' }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $output = @(Invoke-FabMediaApprovalCommand)
        $output | Where-Object { $_ -is [string] } | Write-Output
        exit 0
    }
    catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        Write-Output 'MEDIA_APPROVAL=FAIL'
        exit 1
    }
}
