# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab submission preparation contracts' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\FabSubmissionCommon.ps1')

        function Write-TestMedia {
            param(
                [Parameter(Mandatory)] [string]$Path,
                [int]$Width = 1920,
                [int]$Height = 1080,
                [System.Drawing.Imaging.ImageFormat]$Format = [System.Drawing.Imaging.ImageFormat]::Jpeg
            )
            Add-Type -AssemblyName System.Drawing
            $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                $isSecondImage = [System.IO.Path]::GetFileNameWithoutExtension($Path) -eq '02'
                $color = if ($isSecondImage) { [System.Drawing.Color]::DarkSlateBlue } else { [System.Drawing.Color]::SteelBlue }
                try { $graphics.Clear($color) }
                finally { $graphics.Dispose() }
                $bitmap.SetPixel(0, 0, [System.Drawing.Color]::White)
                if ($isSecondImage) {
                    $bitmap.SetPixel(1, 1, [System.Drawing.Color]::OrangeRed)
                    $bitmap.SetPixel(2, 2, [System.Drawing.Color]::LimeGreen)
                }
                $bitmap.Save($Path, $Format)
            }
            finally { $bitmap.Dispose() }
        }

        function New-MediaFixture {
            [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
            param()
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            if (-not $PSCmdlet.ShouldProcess($root, 'Create media fixture')) { return }
            $mediaRoot = Join-Path $root 'Marketing\Fab'
            [System.IO.Directory]::CreateDirectory($mediaRoot) | Out-Null
            $media = @('Marketing/Fab/01.jpg', 'Marketing/Fab/02.jpg')
            Write-TestMedia -Path (Join-Path $root 'Marketing\Fab\01.jpg')
            Write-TestMedia -Path (Join-Path $root 'Marketing\Fab\02.jpg')
            $listing = [ordered]@{
                schema_version = 1; product = 'Fixture Product'; version = '1.0.0'; title = 'Fixture Product';
                short_description = 'Short'; long_description = 'Long'; product_type = 'Tools & Plugins';
                category = 'Engine Tools'; subcategory = @(); tags_ordered = @('Testing'); included_format = 'Unreal Engine';
                engine_versions = @('5.8'); platforms = @('Win64'); license = 'Fab Standard License';
                personal_price_usd = 0; professional_price_usd = 0; mature_content = $false;
                generated_with_ai = $false; allows_usage_with_ai = $false; promotional_content = $false;
                forum_post = $false; activation = 'Manual'; documentation_url = 'https://example.invalid/docs';
                support_url = 'https://example.invalid/support'; source_repository_url = 'https://github.com/metyatech/fixture';
                media_order = $media
            }
            Write-FabSubmissionAtomicText -Path (Join-Path $root 'FabListingFields.json') `
                -Text (ConvertTo-FabSubmissionJsonText -Value $listing)
            return $root
        }
    }

    It 'creates a hash-bound standalone review without approval' {
        $root = New-MediaFixture
        $review = New-FabMediaReviewArtifact -PluginPath $root -Confirm:$false
        $review.MediaCount | Should -Be 2
        $review.Approved | Should -BeFalse
        $review.ReviewId | Should -Match '^[0-9a-f-]{36}$'
        $review.ManifestPath | Should -Exist
        $review.HtmlPath | Should -Exist
        (Get-Content -Raw -LiteralPath $review.HtmlPath) | Should -Match 'NOT approved'
        (Get-Content -Raw -LiteralPath $review.HtmlPath) | Should -Match 'media/001_01.jpg'
        $manifest = Read-FabSubmissionJson -Path $review.ManifestPath
        @($manifest.media) | Should -HaveCount 2
        $manifest.media[0].role | Should -BeExactly 'thumbnail'
        $manifest.media[1].role | Should -BeExactly 'gallery'
        (Join-Path $root 'FabMediaApproval.json') | Should -Not -Exist
    }

    It 'rejects media below the central dimensions' {
        $root = New-MediaFixture
        Write-TestMedia -Path (Join-Path $root 'Marketing\Fab\01.jpg') -Width 1919
        { New-FabMediaReviewArtifact -PluginPath $root -Confirm:$false } |
            Should -Throw '*at least 1920x1080*'
    }

    It 'writes approval only after explicit confirmation and rejects changed bytes' {
        $root = New-MediaFixture
        $review = New-FabMediaReviewArtifact -PluginPath $root -Confirm:$false
        . (Join-Path $PSScriptRoot '..\Approve-FabMedia.ps1') `
            -PluginPath $root -ReviewManifestPath $review.ManifestPath -ConfirmHumanApproval
        Invoke-FabMediaApprovalCommand | Out-Null
        $approvalPath = Join-Path $root 'FabMediaApproval.json'
        $approvalPath | Should -Exist
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'Marketing\Fab\01.jpg'))
        [System.IO.File]::WriteAllBytes((Join-Path $root 'Marketing\Fab\01.jpg'), $bytes + [byte]0)
        $status = Get-FabMediaApprovalStatus -PluginPath $root `
            -CurrentMedia @(Get-FabMediaTechnicalManifest -PluginPath $root `
                -MediaOrder @((Read-FabSubmissionJson -Path (Join-Path $root 'FabListingFields.json')).media_order))
        $status.Valid | Should -BeFalse
    }

    It 'synchronizes only an authoritative lowercase listing ID' {
        $root = New-MediaFixture
        $script = Join-Path $PSScriptRoot '..\Set-FabListingId.ps1'
        & pwsh -NoProfile -NonInteractive -File $script -PluginPath $root `
            -ListingId '42e5c3b5-36c3-4a91-ba59-8101812e62c3' | Out-Null
        $listing = Read-FabSubmissionJson -Path (Join-Path $root 'FabListingFields.json')
        $listing.listing_id | Should -BeExactly '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
    }

    It 'assembles normal-RHI capture arguments without forbidden render switches' {
        . (Join-Path $PSScriptRoot '..\Invoke-FabUnrealEditorCapture.ps1') `
            -PluginPath $TestDrive -EngineVersion 5.8 -ScenarioSource scenario.cpp `
            -AutomationTestName Fab.Fixture.Capture -SkipExecution
        $arguments = @(Get-FabCaptureCommandArgument -ProjectPath 'C:\temp\Host.uproject' `
            -AutomationTestName 'Fab.Fixture.Capture')
        [string]::Join(' ', $arguments) | Should -Not -Match '(?i)NullRHI|RenderOffscreen'
        [string]::Join(' ', $arguments) | Should -Match 'Automation RunTests Fab.Fixture.Capture'
    }
}
