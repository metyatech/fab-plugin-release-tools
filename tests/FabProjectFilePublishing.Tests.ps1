# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab project file publishing' {
    BeforeAll {
        $publishScript = Join-Path $PSScriptRoot '..\Publish-FabProjectFiles.ps1'
        . $publishScript -PluginPath $PSScriptRoot

        $script:publishing = [pscustomobject]@{
            ObjectPrefix = 'test-product'
        }
        $script:shaA = 'A' * 64
        $script:shaB = 'B' * 64

        function Get-TestListing {
            param(
                [string]$UrlA = 'https://old.example/UE5.5.zip',
                [string]$UrlB = 'https://old.example/UE5.8.zip'
            )

            return [pscustomobject]@{
                title = 'Fixture'
                project_file_links = [pscustomobject]@{
                    '5.5' = $UrlA
                    '5.8' = $UrlB
                }
            }
        }
    }

    It 'builds a lowercase SHA-addressed object key' {
        Get-FabR2ObjectKey -Publishing $script:publishing -ProductVersion '0.1.0' `
            -EngineVersion '5.8' -FileName 'Product.zip' -Sha256 $script:shaA |
            Should -BeExactly 'test-product/0.1.0/UE5.8/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Product.zip'
    }

    It 'changes the object key when only the SHA changes' {
        $keyA = Get-FabR2ObjectKey -Publishing $script:publishing -ProductVersion '0.1.0' `
            -EngineVersion '5.8' -FileName 'Product.zip' -Sha256 $script:shaA
        $keyB = Get-FabR2ObjectKey -Publishing $script:publishing -ProductVersion '0.1.0' `
            -EngineVersion '5.8' -FileName 'Product.zip' -Sha256 $script:shaB
        $keyA | Should -Not -BeExactly $keyB
    }

    It 'normalizes uppercase SHA input in the object key' {
        $key = Get-FabR2ObjectKey -Publishing $script:publishing -ProductVersion '0.1.0' `
            -EngineVersion '5.8' -FileName 'Product.zip' -Sha256 $script:shaA
        $key | Should -Match '/a{64}/'
    }

    It 'rejects an invalid SHA for the object key' {
        { Get-FabR2ObjectKey -Publishing $script:publishing -ProductVersion '0.1.0' `
                -EngineVersion '5.8' -FileName 'Product.zip' -Sha256 'not-a-sha' } |
            Should -Throw '*Invalid SHA-256*'
    }

    It 'falls back to the text bucket listing when Wrangler lacks JSON output' {
        Mock Get-FabR2Wrangler { 'wrangler' }
        Mock Invoke-FabR2Wrangler {
            param(
                [string]$WranglerPath,
                [string[]]$Arguments
            )
            [void]$WranglerPath
            if ($Arguments -contains '--json') {
                throw 'Wrangler failed with exit code 1: Unknown argument: json'
            }
            [pscustomobject]@{
                Output = "name:           metyatech-fab-project-files`ncreation_date:  2026-09-03T12:10:48.770Z"
                Error  = ''
            }
        }

        Assert-FabR2BucketAccess -Publishing ([pscustomobject]@{
                Bucket = 'metyatech-fab-project-files'
            }) | Should -BeExactly 'wrangler'
        Should -Invoke Invoke-FabR2Wrangler -Times 2 -Exactly
    }

    It 'omits existing project file links from the publication listing copy' {
        $source = [pscustomobject]@{
            title = 'Fixture'
            project_file_links = [pscustomobject]@{ '5.8' = 'https://old.example/UE5.8.zip' }
            project_file_link = 'https://old.example/legacy.zip'
        }
        $path = Join-Path $TestDrive 'PublicationListing.json'
        New-FabR2PublicationListingFile -Listing $source -Path $path | Should -BeExactly $path
        $readback = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $readback.title | Should -BeExactly 'Fixture'
        $readback.PSObject.Properties['project_file_links'] | Should -BeNullOrEmpty
        $readback.PSObject.Properties['project_file_link'] | Should -BeNullOrEmpty
    }

    It 'writes project_file_links when no existing set is present' {
        $path = Join-Path $TestDrive 'WriteListing.json'
        $listing = [pscustomobject]@{ title = 'Fixture' }
        $links = [ordered]@{
            '5.5' = 'https://new.example/UE5.5.zip'
            '5.8' = 'https://new.example/UE5.8.zip'
        }
        Update-FabR2ListingLinkSet -ListingPath $path -Listing $listing -Links $links `
            -EngineVersions @('5.5', '5.8') | Should -BeExactly 'WRITTEN'
        $readback = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $readback.project_file_links.'5.5' | Should -BeExactly $links['5.5']
        $readback.project_file_links.'5.8' | Should -BeExactly $links['5.8']
    }

    It 'returns NOOP for a complete matching project_file_links set' {
        $path = Join-Path $TestDrive 'NoopListing.json'
        $listing = Get-TestListing
        $links = [ordered]@{
            '5.5' = $listing.project_file_links.'5.5'
            '5.8' = $listing.project_file_links.'5.8'
        }
        Update-FabR2ListingLinkSet -ListingPath $path -Listing $listing -Links $links `
            -EngineVersions @('5.5', '5.8') | Should -BeExactly 'NOOP'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'returns UPDATED when the engine set matches but URLs differ' {
        $path = Join-Path $TestDrive 'UpdatedListing.json'
        $listing = Get-TestListing
        $links = [ordered]@{
            '5.5' = 'https://new.example/UE5.5.zip'
            '5.8' = 'https://new.example/UE5.8.zip'
        }
        Update-FabR2ListingLinkSet -ListingPath $path -Listing $listing -Links $links `
            -EngineVersions @('5.5', '5.8') | Should -BeExactly 'UPDATED'
        $readback = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        @($readback.project_file_links.PSObject.Properties.Name) | Should -BeExactly @('5.5', '5.8')
        $readback.project_file_links.'5.5' | Should -BeExactly $links['5.5']
        $readback.project_file_links.'5.8' | Should -BeExactly $links['5.8']
    }

    It 'rejects an engine set mismatch without writing a partial link set' {
        $path = Join-Path $TestDrive 'MismatchedListing.json'
        $listing = Get-TestListing
        $links = [ordered]@{ '5.5' = 'https://new.example/UE5.5.zip' }
        { Update-FabR2ListingLinkSet -ListingPath $path -Listing $listing -Links $links `
                -EngineVersions @('5.5') } | Should -Throw '*exactly the generated engine set*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}
