# Copyright (c) 2026 metyatech. All rights reserved.

<##
.SYNOPSIS
Safely records an authoritative Fab listing UUID in FabListingFields.json.

.EXAMPLE
pwsh .\Set-FabListingId.ps1 -PluginPath ..\MyPlugin `
  -ListingId 42e5c3b5-36c3-4a91-ba59-8101812e62c3
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [Parameter(Mandatory)]
    [string]$ListingId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabSubmissionCommon.ps1')
[void]$PluginPath
[void]$ListingId

function Invoke-FabListingIdCommand {
    $root = Assert-FabSubmissionPluginRoot -PluginPath $PluginPath
    if ($ListingId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'ListingId must be a lowercase UUID obtained from Fab.'
    }
    $listingPath = Join-Path $root 'FabListingFields.json'
    Assert-FabSubmissionSchema -Path $listingPath `
        -SchemaPath (Join-Path $PSScriptRoot 'FabListingFields.schema.json') `
        -Description 'Listing fields'
    $listing = Read-FabSubmissionJson -Path $listingPath
    $existing = $listing.PSObject.Properties['listing_id']
    if ($null -ne $existing) {
        if ([string]$existing.Value -cne $ListingId) {
            throw 'Existing listing_id conflicts with the requested authoritative Fab listing ID.'
        }
        Write-Output 'LISTING_ID=UNCHANGED'
        Write-Output 'ACTION=NOOP'
        return [pscustomobject]@{ Path = $listingPath; Action = 'NOOP'; ListingId = $ListingId }
    }
    Add-Member -InputObject $listing -NotePropertyName listing_id -NotePropertyValue $ListingId
    Write-FabSubmissionAtomicText -Path $listingPath `
        -Text (ConvertTo-FabSubmissionJsonText -Value $listing)
    Write-Output 'LISTING_ID=UPDATED'
    Write-Output 'ACTION=WRITTEN'
    return [pscustomobject]@{ Path = $listingPath; Action = 'WRITTEN'; ListingId = $ListingId }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $output = @(Invoke-FabListingIdCommand)
        $output | Where-Object { $_ -is [string] } | Write-Output
        exit 0
    }
    catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        Write-Output 'LISTING_ID=FAIL'
        exit 1
    }
}
