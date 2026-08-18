# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab product release orchestration' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Invoke-FabProductRelease.ps1'
        . $scriptPath -PluginPath $PSScriptRoot

        function Write-ProductFixtureJson {
            param(
                [Parameter(Mandatory)]
                [object]$Value,

                [Parameter(Mandatory)]
                [string]$Path
            )

            [System.IO.File]::WriteAllText(
                $Path,
                ($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false))
        }

        function Initialize-ProductFixture {
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [string[]]$EngineVersions = @('5.10', '5.9'),

                [string[]]$Platforms = @('Win64'),

                [string[]]$MediaOrder = @('Media\First.png', 'Media\Second.png')
            )

            [System.IO.Directory]::CreateDirectory((Join-Path $Root 'Media')) | Out-Null
            foreach ($mediaPath in @('Media\First.png', 'Media\Second.png')) {
                [System.IO.File]::WriteAllText((Join-Path $Root $mediaPath), $mediaPath)
            }
            $configuration = [ordered]@{
                schemaVersion             = 1
                pluginName                = 'TestPlugin'
                descriptorFile            = 'TestPlugin.uplugin'
                engineVersions            = @($EngineVersions)
                platforms                 = @($Platforms)
                distributionModules       = @('TestPlugin')
                enabledPluginDependencies = @()
                publisher                 = [ordered]@{
                    name            = 'metyatech'
                    url             = 'https://github.com/metyatech'
                    copyrightNotice = '// Copyright (c) 2026 metyatech. All rights reserved.'
                }
                listingId                 = $null
                documentationUrl          = 'https://docs.example.invalid/test-plugin'
                supportUrl                = 'https://support.example.invalid/test-plugin'
                content                   = [ordered]@{ mode = 'none' }
                includeDirectories       = @('Media')
                includeFiles             = @('TestPlugin.uplugin')
                requiredPackageFiles     = @('TestPlugin.uplugin')
                customDistributionPaths   = @()
                thirdPartyLicenseSets     = @()
                forbiddenPackagePatterns  = @()
                buildLogFailPatterns     = @()
            }
            Write-ProductFixtureJson -Value $configuration `
                -Path (Join-Path $Root 'FabPluginRelease.json')
            $listing = [ordered]@{
                title             = 'Test Plugin'
                short_description = 'Short description.'
                long_description  = 'Long description.'
                engine_versions   = @($EngineVersions)
                platforms         = @($Platforms)
                documentation_url = $configuration.documentationUrl
                support_url       = $configuration.supportUrl
                media_order       = @($MediaOrder)
            }
            Write-ProductFixtureJson -Value $listing `
                -Path (Join-Path $Root 'FabListingFields.json')
            return [pscustomobject]@{
                Configuration = $configuration
                Listing       = $listing
            }
        }

        function Write-ProductReleaseArtifact {
            [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
            param(
                [Parameter(Mandatory)]
                [string]$OutputPath,

                [Parameter(Mandatory)]
                [string]$EngineVersion
            )

            if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Write product release fixture')) {
                return
            }
            [System.IO.Directory]::CreateDirectory($OutputPath) | Out-Null
            $zipPath = Join-Path $OutputPath "TestPlugin_1.0.0_UE${EngineVersion}_Win64.zip"
            [System.IO.File]::WriteAllText($zipPath, "package-$EngineVersion")
            $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            [System.IO.File]::WriteAllText("$zipPath.sha256", "$hash  $(Split-Path -Leaf $zipPath)`n")
            [System.IO.File]::WriteAllText("$zipPath.report.json", '{"status":"PASS"}')
            [System.IO.File]::WriteAllText("$zipPath.log", "release-$EngineVersion`n")
        }

        function Invoke-ProductCoreForTest {
            param(
                [Parameter(Mandatory)]
                [string]$PluginRoot,

                [Parameter(Mandatory)]
                [string]$OutputRoot
            )

            return Invoke-FabProductReleaseCore -PluginPath $PluginRoot -OutputDirectory $OutputRoot
        }
    }

    BeforeEach {
        $script:ProductReleaseInvocations = [System.Collections.Generic.List[string]]::new()
        $script:ProductSubmissionInvocations = [System.Collections.Generic.List[string]]::new()
        $script:ProductReleaseFailureVersion = $null
        $script:ProductSubmissionFailureVersion = $null
        Mock -CommandName Invoke-FabProductVersionRelease -MockWith {
            param(
                [string]$EngineVersion,
                [string]$OutputPath
            )
            $script:ProductReleaseInvocations.Add($EngineVersion)
            if ($EngineVersion -ceq $script:ProductReleaseFailureVersion) {
                throw "intentional release failure for UE$EngineVersion"
            }
            Write-ProductReleaseArtifact -OutputPath $OutputPath -EngineVersion $EngineVersion -Confirm:$false
        }
        Mock -CommandName Invoke-FabProductSubmissionValidation -MockWith {
            param(
                [string]$PackageZipPath,
                [string]$OutputPath
            )
            $version = [regex]::Match($PackageZipPath, '_UE(?<version>5\.[0-9]+)_').Groups['version'].Value
            $script:ProductSubmissionInvocations.Add($version)
            if ($version -ceq $script:ProductSubmissionFailureVersion) {
                throw "intentional submission failure for UE$version"
            }
            [System.IO.Directory]::CreateDirectory($OutputPath) | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $OutputPath 'FabTechnicalInformation.txt'),
                "Product: Test Plugin`n")
            return [pscustomobject]@{ OutputPath = $OutputPath; Output = 'FAB SUBMISSION CHECK: PASS' }
        }
    }

    It 'invokes every configured engine version exactly once' {
        $root = Join-Path $TestDrive 'EveryVersion'
        $outputRoot = Join-Path $TestDrive 'EveryVersionArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.10', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        @($script:ProductReleaseInvocations) | Should -HaveCount 3
        @($script:ProductReleaseInvocations | Sort-Object) | Should -Be @('5.10', '5.8', '5.9')
    }

    It 'orders Unreal minor versions numerically, including 5.9 before 5.10' {
        $root = Join-Path $TestDrive 'NumericOrder'
        $outputRoot = Join-Path $TestDrive 'NumericOrderArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.10', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        @($script:ProductReleaseInvocations) | Should -BeExactly @('5.9', '5.10')
    }

    It 'stops immediately when the first engine version fails' {
        $root = Join-Path $TestDrive 'FirstFailure'
        $outputRoot = Join-Path $TestDrive 'FirstFailureArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        $script:ProductReleaseFailureVersion = '5.8'
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } | Should -Throw '*UE5.8 release failed*'
        @($script:ProductReleaseInvocations) | Should -BeExactly @('5.8')
    }

    It 'does not publish PASS or FabSubmission when submission validation fails' {
        $root = Join-Path $TestDrive 'SubmissionFailure'
        $outputRoot = Join-Path $TestDrive 'SubmissionFailureArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        $script:ProductSubmissionFailureVersion = '5.9'
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*intentional submission failure*'
        (Join-Path $outputRoot 'TestPlugin\FabSubmission') | Should -Not -Exist
    }

    It 'rejects listing/configuration mismatches' -ForEach @(
        @{ Name = 'version'; Property = 'engine_versions'; Value = @('5.8') },
        @{ Name = 'platform'; Property = 'platforms'; Value = @('Linux') },
        @{ Name = 'documentation URL'; Property = 'documentation_url'; Value = 'https://docs.example.invalid/other' },
        @{ Name = 'support URL'; Property = 'support_url'; Value = 'https://support.example.invalid/other' }) {
        $root = Join-Path $TestDrive "Mismatch-$Name"
        $outputRoot = Join-Path $TestDrive "MismatchArtifacts-$Name"
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing.$Property = $Value
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } | Should -Throw
        @($script:ProductReleaseInvocations) | Should -HaveCount 0
    }

    It 'rejects missing media' {
        $root = Join-Path $TestDrive 'MissingMedia'
        $outputRoot = Join-Path $TestDrive 'MissingMediaArtifacts'
        Initialize-ProductFixture -Root $root -MediaOrder @('Media\Missing.png') | Out-Null
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } | Should -Throw '*Media file is missing*'
    }

    It 'rejects media path traversal' {
        $root = Join-Path $TestDrive 'MediaTraversal'
        $outputRoot = Join-Path $TestDrive 'MediaTraversalArtifacts'
        Initialize-ProductFixture -Root $root -MediaOrder @('..\outside.png') | Out-Null
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*relative path without*'
    }

    It 'rejects case-insensitive duplicate media entries' {
        $root = Join-Path $TestDrive 'DuplicateMedia'
        $outputRoot = Join-Path $TestDrive 'DuplicateMediaArtifacts'
        Initialize-ProductFixture -Root $root -MediaOrder @('Media\First.png', 'media\FIRST.png') | Out-Null
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*duplicate entry*'
    }

    It 'writes deterministic ordered manifest data without absolute paths' {
        $root = Join-Path $TestDrive 'ManifestData'
        $outputRoot = Join-Path $TestDrive 'ManifestArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.10', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifestPath = Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json'
        $manifestText = Get-Content -Raw -LiteralPath $manifestPath
        $manifestText | Should -Not -Match ([regex]::Escape($root))
        $manifest = $manifestText | ConvertFrom-Json
        @($manifest.engineVersions) | Should -BeExactly @('5.9', '5.10')
        @($manifest.packages.engineVersion) | Should -BeExactly @('5.9', '5.10')
        @($manifest.media.order) | Should -BeExactly @(1, 2)
        @($manifest.media.sourceRelativePath) | Should -BeExactly @('Media/First.png', 'Media/Second.png')
        @($manifest.media.bundleRelativePath) | Should -BeExactly @('media/001_First.png', 'media/002_Second.png')
        @($manifest.packages.bundleRelativePath) | Should -BeExactly @(
            'packages/UE5.9/TestPlugin_1.0.0_UE5.9_Win64.zip',
            'packages/UE5.10/TestPlugin_1.0.0_UE5.10_Win64.zip')
        $manifest.technicalInformationFile | Should -BeExactly 'submission/FabTechnicalInformation.txt'
    }

    It 'publishes all expected package, media, and submission outputs after every gate passes' {
        $root = Join-Path $TestDrive 'SuccessfulBundle'
        $outputRoot = Join-Path $TestDrive 'SuccessfulBundleArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $bundleRoot = Join-Path $outputRoot 'TestPlugin\FabSubmission'
        $bundleRoot | Should -Exist
        (Join-Path $bundleRoot 'submission\FabTechnicalInformation.txt') | Should -Exist
        (Join-Path $bundleRoot 'FabPortalSubmission.json') | Should -Exist
        (Join-Path $bundleRoot 'SubmissionChecklist.txt') | Should -Exist
        foreach ($version in @('5.8', '5.9')) {
            $packageRoot = Join-Path $bundleRoot "packages\UE$version"
            $packageRoot | Should -Exist
            @(Get-ChildItem -LiteralPath $packageRoot -File -Filter '*.zip') | Should -HaveCount 1
            @(Get-ChildItem -LiteralPath $packageRoot -File -Filter '*.sha256') | Should -HaveCount 1
            @(Get-ChildItem -LiteralPath $packageRoot -File -Filter '*.report.json') | Should -HaveCount 1
            @(Get-ChildItem -LiteralPath $packageRoot -File -Filter '*.log') | Should -HaveCount 1
        }
        (Join-Path $bundleRoot 'media\001_First.png') | Should -Exist
        (Join-Path $bundleRoot 'media\002_Second.png') | Should -Exist
        $checklist = Get-Content -Raw -LiteralPath (Join-Path $bundleRoot 'SubmissionChecklist.txt')
        $checklist | Should -Match 'PASS - UE5.8 built'
        $checklist | Should -Match 'PASS - UE5.9 package validated'
        $checklist | Should -Match 'PASS - bundle manifest generation'
        $checklist | Should -Match 'Future browser automation / Fab human review:'
    }
}
