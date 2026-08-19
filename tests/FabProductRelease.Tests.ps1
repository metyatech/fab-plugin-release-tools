# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab product release orchestration' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Invoke-FabProductRelease.ps1'
        . $scriptPath -PluginPath $PSScriptRoot

        if ($null -eq ('FabProductTestHttpMessageHandler' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class FabProductTestHttpMessageHandler : HttpMessageHandler
{
    private readonly HttpResponseMessage response;

    public FabProductTestHttpMessageHandler(HttpResponseMessage response)
    {
        this.response = response;
    }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return Task.FromResult(response);
    }
}
'@
        }

        function Get-TestSha256 {
            param([Parameter(Mandatory)][byte[]]$Bytes)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                return [System.Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant()
            }
            finally {
                $sha.Dispose()
            }
        }

        function Get-TestRemoteHttpClient {
            param(
                [Parameter(Mandatory)]
                [int]$StatusCode,

                [byte[]]$Bytes
            )
            $response = [System.Net.Http.HttpResponseMessage]::new(
                [System.Net.HttpStatusCode]$StatusCode)
            if ($null -ne $Bytes) {
                $response.Content = [System.Net.Http.ByteArrayContent]::new($Bytes)
            }
            return [System.Net.Http.HttpClient]::new(
                [FabProductTestHttpMessageHandler]::new($response))
        }

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
            Write-ProductFixtureJson -Value ([ordered]@{
                    VersionName = '1.0.0'
                }) -Path (Join-Path $Root 'TestPlugin.uplugin')
            $listing = [ordered]@{
                schema_version          = '1.0'
                product                 = 'Test Plugin'
                version                 = '1.0.0'
                title                   = 'Test Plugin'
                short_description       = 'Short description.'
                long_description        = 'Long description.'
                product_type            = 'Tools & Plugins'
                category                = 'Tools & Plugins'
                subcategory             = @('Testing')
                tags_ordered            = @('Plugin', 'Testing')
                included_format         = 'Unreal Engine'
                engine_versions         = @($EngineVersions)
                platforms               = @($Platforms)
                license                 = 'Fab Standard License'
                personal_price_usd      = 0
                professional_price_usd  = 0
                mature_content          = $false
                generated_with_ai       = $false
                allows_usage_with_ai   = $false
                promotional_content    = $false
                forum_post              = $false
                activation              = 'Manual activation'
                documentation_url      = $configuration.documentationUrl
                support_url             = $configuration.supportUrl
                source_repository_url  = 'https://github.com/metyatech/TestPlugin'
                media_order             = @($MediaOrder)
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
        $script:ProductReleaseOutputPaths = [System.Collections.Generic.List[string]]::new()
        $script:ProductSubmissionInvocations = [System.Collections.Generic.List[string]]::new()
        $script:ProductReleaseFailureVersion = $null
        $script:ProductSubmissionFailureVersion = $null
        Mock -CommandName Invoke-FabProductVersionRelease -MockWith {
            param(
                [string]$EngineVersion,
                [string]$OutputPath
            )
            $script:ProductReleaseInvocations.Add($EngineVersion)
            $script:ProductReleaseOutputPaths.Add($OutputPath)
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

    It 'loads Invoke-FabPluginRelease from this repository module after dot-sourcing' {
        $command = Get-Command Invoke-FabPluginRelease -ErrorAction Stop
        $command.Source | Should -Be 'FabPluginReleaseTools'
        (Get-Module FabPluginReleaseTools).ModuleBase | Should -Be (
            (Join-Path $PSScriptRoot '..' | Resolve-Path).Path)
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

    It 'uses a same-volume private session for every lower-level release' {
        $root = Join-Path $TestDrive 'SameVolume'
        $outputRoot = Join-Path $TestDrive 'SameVolumeArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        foreach ($path in @($script:ProductReleaseOutputPaths)) {
            $path | Should -Match ([regex]::Escape((Join-Path $outputRoot 'TestPlugin\.sessions\')))
            $path | Should -Match '\.sessions\\[^\\]+\\releases\\UE5\.[0-9]+$'
        }
        (Join-Path $outputRoot 'TestPlugin\product') | Should -Not -Exist
        ([System.IO.Path]::GetPathRoot($outputRoot)) | Should -Be ([System.IO.Path]::GetPathRoot(
                (Join-Path $outputRoot 'TestPlugin\FabSubmission')))
    }

    It 'safely replaces the previous bundle on a repeated successful run' {
        $root = Join-Path $TestDrive 'Repeated'
        $outputRoot = Join-Path $TestDrive 'RepeatedArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $bundleRoot = Join-Path $outputRoot 'TestPlugin\FabSubmission'
        [System.IO.File]::WriteAllText((Join-Path $bundleRoot 'stale.txt'), 'stale')
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        (Join-Path $bundleRoot 'stale.txt') | Should -Not -Exist
        @(Get-ChildItem -LiteralPath (Join-Path $bundleRoot 'packages') -Recurse -File -Filter '*.zip') |
            Should -HaveCount 2
        (Join-Path $outputRoot 'TestPlugin\product') | Should -Not -Exist
    }

    It 'preserves the previous known-good bundle and writes failure diagnostics' {
        $root = Join-Path $TestDrive 'RepeatedFailure'
        $outputRoot = Join-Path $TestDrive 'RepeatedFailureArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $bundleRoot = Join-Path $outputRoot 'TestPlugin\FabSubmission'
        $before = Get-Content -Raw -LiteralPath (Join-Path $bundleRoot 'FabPortalSubmission.json')
        $script:ProductReleaseFailureVersion = '5.9'
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*Failure diagnostics:*'
        Get-Content -Raw -LiteralPath (Join-Path $bundleRoot 'FabPortalSubmission.json') | Should -BeExactly $before
        $failureDirectories = @(Get-ChildItem -LiteralPath (Join-Path $outputRoot 'TestPlugin\failures') -Directory)
        $failureDirectories | Should -HaveCount 1
        (Join-Path $failureDirectories[0].FullName 'failure.txt') | Should -Exist
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
        Initialize-ProductFixture -Root $root -MediaOrder @('Media\Missing.png', 'Media\Second.png') | Out-Null
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } | Should -Throw '*Media file is missing*'
    }

    It 'rejects media path traversal' {
        $root = Join-Path $TestDrive 'MediaTraversal'
        $outputRoot = Join-Path $TestDrive 'MediaTraversalArtifacts'
        Initialize-ProductFixture -Root $root -MediaOrder @('..\outside.png', 'Media\Second.png') | Out-Null
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
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName listing_id -NotePropertyValue '11111111-1111-4111-8111-111111111111'
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifestPath = Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json'
        $manifestText = Get-Content -Raw -LiteralPath $manifestPath
        $manifestText | Should -Not -Match ([regex]::Escape($root))
        $manifest = $manifestText | ConvertFrom-Json
        ($manifestText | Test-Json -SchemaFile (Join-Path $PSScriptRoot '..\FabPortalSubmission.schema.json')) | Should -BeTrue
        @($manifest.engineVersions) | Should -BeExactly @('5.9', '5.10')
        @($manifest.packages.engineVersion) | Should -BeExactly @('5.9', '5.10')
        @($manifest.media.order) | Should -BeExactly @(1, 2)
        @($manifest.media.role) | Should -BeExactly @('thumbnail', 'gallery')
        @($manifest.media.sourceRelativePath) | Should -BeExactly @('Media/First.png', 'Media/Second.png')
        @($manifest.media.bundleRelativePath) | Should -BeExactly @('media/001_First.png', 'media/002_Second.png')
        @($manifest.media.fileName) | Should -BeExactly @('First.png', 'Second.png')
        @($manifest.packages.bundleRelativePath) | Should -BeExactly @(
            'packages/UE5.9/TestPlugin_1.0.0_UE5.9_Win64.zip',
            'packages/UE5.10/TestPlugin_1.0.0_UE5.10_Win64.zip')
        $manifest.technicalInformationFile | Should -BeExactly 'submission/FabTechnicalInformation.txt'
        $manifest.schemaVersion | Should -Be 2
        $manifest.productVersion | Should -BeExactly '1.0.0'
        $manifest.portalReady | Should -BeFalse
        @($manifest.packages | Where-Object { $null -ne $_.projectFileLink }) | Should -HaveCount 0
    }

    It 'accepts an explicitly empty subcategory and preserves taxonomy levels in the manifest' {
        $root = Join-Path $TestDrive 'EmptySubcategory'
        $outputRoot = Join-Path $TestDrive 'EmptySubcategoryArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing.product_type = 'Tools & Plugins'
        $listing.category = 'Network & Multiplayer'
        $listing.subcategory = @()
        Write-ProductFixtureJson -Value $listing -Path $listingPath

        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.productType | Should -BeExactly 'Tools & Plugins'
        $manifest.category | Should -BeExactly 'Network & Multiplayer'
        @($manifest.subcategory) | Should -HaveCount 0
    }

    It 'accepts a non-empty subcategory without changing its value' {
        $root = Join-Path $TestDrive 'NonEmptySubcategory'
        $outputRoot = Join-Path $TestDrive 'NonEmptySubcategoryArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        @($manifest.subcategory) | Should -BeExactly @('Testing')
    }

    It 'rejects invalid subcategory arrays while preserving required-array validation' -ForEach @(
        @{ Name = 'blank subcategory item'; Mutate = { param($listing) $listing.subcategory = @('   ') }; Pattern = '*non-blank*' },
        @{ Name = 'missing subcategory'; Mutate = { param($listing) $listing.PSObject.Properties.Remove('subcategory') }; Pattern = '*schema.json*' },
        @{ Name = 'empty tags_ordered'; Mutate = { param($listing) $listing.tags_ordered = @() }; Pattern = '*schema.json*' },
        @{ Name = 'empty engine_versions'; Mutate = { param($listing) $listing.engine_versions = @() }; Pattern = '*schema.json*' },
        @{ Name = 'empty platforms'; Mutate = { param($listing) $listing.platforms = @() }; Pattern = '*schema.json*' }) {
        $root = Join-Path $TestDrive "InvalidEmptyArray-$Name"
        $outputRoot = Join-Path $TestDrive "InvalidEmptyArrayArtifacts-$Name"
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        & $Mutate $listing
        Write-ProductFixtureJson -Value $listing -Path $listingPath

        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw $Pattern
    }

    It 'accepts the existing extended listing metadata without discarding it' {
        $root = Join-Path $TestDrive 'ExtendedListing'
        $outputRoot = Join-Path $TestDrive 'ExtendedListingArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName ai_metadata_note -NotePropertyValue 'Verification metadata.'
        $listing | Add-Member -NotePropertyName character_counts -NotePropertyValue ([ordered]@{ title = 12 })
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.productType | Should -BeExactly 'Tools & Plugins'
        @($manifest.tags) | Should -BeExactly @('Plugin', 'Testing')
    }

    It 'accepts and propagates a listing_id from ListingFields.json' {
        $root = Join-Path $TestDrive 'ListingId'
        $outputRoot = Join-Path $TestDrive 'ListingIdArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName listing_id `
            -NotePropertyValue '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.listingId | Should -BeExactly '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
    }

    It 'falls back to FabPluginRelease.json listingId when listing metadata omits listing_id' {
        $root = Join-Path $TestDrive 'ListingIdFallback'
        $outputRoot = Join-Path $TestDrive 'ListingIdFallbackArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $configPath = Join-Path $root 'FabPluginRelease.json'
        $configuration = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $configuration.listingId = '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
        Write-ProductFixtureJson -Value $configuration -Path $configPath
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.listingId | Should -BeExactly '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
    }

    It 'rejects conflicting non-null listing IDs before building' {
        $root = Join-Path $TestDrive 'ListingIdConflict'
        $outputRoot = Join-Path $TestDrive 'ListingIdConflictArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName listing_id `
            -NotePropertyValue '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        $configPath = Join-Path $root 'FabPluginRelease.json'
        $configuration = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $configuration.listingId = '19cb2daa-b018-46ae-b28c-7bfe21075c4a'
        Write-ProductFixtureJson -Value $configuration -Path $configPath
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*listing_id conflicts*'
        @($script:ProductReleaseInvocations) | Should -HaveCount 0
    }

    It 'rejects an invalid listing_id' {
        $root = Join-Path $TestDrive 'InvalidListingId'
        $outputRoot = Join-Path $TestDrive 'InvalidListingIdArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName listing_id -NotePropertyValue 'NOT-A-UUID'
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*schema.json*'
    }

    It 'sets portalReady and maps a configured project_file_link exactly' {
        $root = Join-Path $TestDrive 'ConfiguredLink'
        $outputRoot = Join-Path $TestDrive 'ConfiguredLinkArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName project_file_link `
            -NotePropertyValue 'https://downloads.example.invalid/TestPlugin_1.0.0_UE5.8_Win64.zip'
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        Mock -CommandName Get-FabProductRemoteZipHash -MockWith {
            param([string]$Url, [string]$ExpectedSha256)
            return [pscustomobject]@{ Url = $Url; Sha256 = $ExpectedSha256; Bytes = 1; RedirectCount = 0 }
        }
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.portalReady | Should -BeTrue
        $manifest.packages[0].projectFileLink | Should -BeExactly $listing.project_file_link
        (Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'TestPlugin\FabSubmission\SubmissionChecklist.txt')) |
            Should -Match 'PASS - portal automation input ready'
    }

    It 'streams remote content and computes its SHA-256' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('streamed zip content')
        $expected = Get-TestSha256 -Bytes $bytes
        $stream = [System.IO.MemoryStream]::new($bytes)
        try {
            $result = Get-FabProductStreamSha256 -Stream $stream -MaximumBytes 1024
            $result.Sha256 | Should -BeExactly $expected
            $result.Bytes | Should -Be $bytes.Length
        }
        finally {
            $stream.Dispose()
        }
    }

    It 'passes when the remote ZIP bytes match the generated SHA-256' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('matching zip content')
        $expected = Get-TestSha256 -Bytes $bytes
        $client = Get-TestRemoteHttpClient -StatusCode 200 -Bytes $bytes
        try {
            $result = Get-FabProductRemoteZipHash -Url 'https://downloads.example.invalid/file.zip' `
                -ExpectedSha256 $expected -HttpClient $client
            $result.Sha256 | Should -BeExactly $expected
        }
        finally {
            $client.Dispose()
        }
    }

    It 'fails when a reachable remote ZIP has different bytes' {
        $client = Get-TestRemoteHttpClient -StatusCode 200 `
            -Bytes ([System.Text.Encoding]::UTF8.GetBytes('different zip content'))
        try {
            { Get-FabProductRemoteZipHash -Url 'https://downloads.example.invalid/file.zip' `
                    -ExpectedSha256 ('a' * 64) -HttpClient $client } |
                Should -Throw '*SHA-256 mismatch*'
        }
        finally {
            $client.Dispose()
        }
    }

    It 'fails on a non-success remote HTTP result' {
        $client = Get-TestRemoteHttpClient -StatusCode 404
        try {
            { Get-FabProductRemoteZipHash -Url 'https://downloads.example.invalid/file.zip' `
                    -ExpectedSha256 ('a' * 64) -HttpClient $client } |
                Should -Throw '*HTTP 404*'
        }
        finally {
            $client.Dispose()
        }
    }

    It 'fails when public_release_sha256 disagrees with the generated ZIP' {
        $root = Join-Path $TestDrive 'PublicReleaseHashMismatch'
        $outputRoot = Join-Path $TestDrive 'PublicReleaseHashMismatchArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName project_file_link `
            -NotePropertyValue 'https://downloads.example.invalid/TestPlugin_1.0.0_UE5.8_Win64.zip'
        $listing | Add-Member -NotePropertyName public_release_sha256 -NotePropertyValue ('a' * 64)
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*public_release_sha256*'
    }

    It 'requires generated, remote, and metadata SHA-256 values to agree' {
        $root = Join-Path $TestDrive 'AllProjectFileHashesMatch'
        $outputRoot = Join-Path $TestDrive 'AllProjectFileHashesMatchArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8') | Out-Null
        $matchingHash = Get-TestSha256 -Bytes ([System.Text.Encoding]::UTF8.GetBytes('package-5.8'))
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName project_file_link `
            -NotePropertyValue 'https://downloads.example.invalid/TestPlugin_1.0.0_UE5.8_Win64.zip'
        $listing | Add-Member -NotePropertyName public_release_sha256 -NotePropertyValue $matchingHash
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        Mock -CommandName Get-FabProductRemoteZipHash -MockWith {
            param([string]$Url, [string]$ExpectedSha256)
            return [pscustomobject]@{
                Url = $Url
                Sha256 = $ExpectedSha256
                Bytes = 11
                RedirectCount = 0
            }
        }
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.portalReady | Should -BeTrue
        $manifest.packages[0].sha256 | Should -BeExactly $matchingHash
    }

    It 'keeps portalReady false for multi-version listings without per-engine links' {
        $root = Join-Path $TestDrive 'PendingLinks'
        $outputRoot = Join-Path $TestDrive 'PendingLinksArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.portalReady | Should -BeFalse
        $checklist = Get-Content -Raw -LiteralPath (Join-Path $outputRoot 'TestPlugin\FabSubmission\SubmissionChecklist.txt')
        $checklist | Should -Match 'PENDING - Project File Link for UE5.8'
        $checklist | Should -Not -Match 'PASS - portal automation input ready'
    }

    It 'maps project_file_links by engine version without reordering' {
        $root = Join-Path $TestDrive 'ConfiguredLinks'
        $outputRoot = Join-Path $TestDrive 'ConfiguredLinksArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.10', '5.9') | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        $listing | Add-Member -NotePropertyName project_file_links -NotePropertyValue ([ordered]@{
            '5.10' = 'https://downloads.example.invalid/TestPlugin_1.0.0_UE5.10_Win64.zip'
            '5.9'  = 'https://downloads.example.invalid/TestPlugin_1.0.0_UE5.9_Win64.zip'
        })
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        Mock -CommandName Get-FabProductRemoteZipHash -MockWith {
            param([string]$Url, [string]$ExpectedSha256)
            return [pscustomobject]@{ Url = $Url; Sha256 = $ExpectedSha256; Bytes = 1; RedirectCount = 0 }
        }
        Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        @($manifest.packages.projectFileLink) | Should -BeExactly @(
            'https://downloads.example.invalid/TestPlugin_1.0.0_UE5.9_Win64.zip',
            'https://downloads.example.invalid/TestPlugin_1.0.0_UE5.10_Win64.zip')
    }

    It 'rejects unsupported media formats' {
        $root = Join-Path $TestDrive 'UnsupportedMedia'
        $outputRoot = Join-Path $TestDrive 'UnsupportedMediaArtifacts'
        Initialize-ProductFixture -Root $root -MediaOrder @('Media\First.gif', 'Media\Second.png') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'Media\First.gif'), 'gif')
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } |
            Should -Throw '*Unsupported media format*'
    }

    It 'rejects blank text, negative prices, non-boolean flags, and duplicate tags' -ForEach @(
        @{ Name = 'blank title'; Mutate = { param($listing) $listing.title = '   ' }; Pattern = '*non-blank text*' },
        @{ Name = 'negative price'; Mutate = { param($listing) $listing.personal_price_usd = -1 }; Pattern = '*schema.json*' },
        @{ Name = 'string boolean'; Mutate = { param($listing) $listing.mature_content = 'false' }; Pattern = '*schema.json*' },
        @{ Name = 'duplicate tag'; Mutate = { param($listing) $listing.tags_ordered = @('Plugin', 'plugin') }; Pattern = '*unique*' }) {
        $root = Join-Path $TestDrive "InvalidListing-$Name"
        $outputRoot = Join-Path $TestDrive "InvalidListingArtifacts-$Name"
        Initialize-ProductFixture -Root $root | Out-Null
        $listingPath = Join-Path $root 'FabListingFields.json'
        $listing = Get-Content -Raw -LiteralPath $listingPath | ConvertFrom-Json
        & $Mutate $listing
        Write-ProductFixtureJson -Value $listing -Path $listingPath
        { Invoke-ProductCoreForTest -PluginRoot $root -OutputRoot $outputRoot } | Should -Throw $Pattern
    }

    It 'sets portalReady only after the mocked GitHub publication boundary verifies every link' {
        $root = Join-Path $TestDrive 'PublishedLinks'
        $outputRoot = Join-Path $TestDrive 'PublishedLinksArtifacts'
        Initialize-ProductFixture -Root $root -EngineVersions @('5.8', '5.9') | Out-Null
        Mock -CommandName Publish-FabProductProjectFile -MockWith {
            return [ordered]@{
                '5.8' = 'https://github.com/metyatech/TestPlugin/releases/download/fab-v1.0.0/TestPlugin_1.0.0_UE5.8_Win64.zip'
                '5.9' = 'https://github.com/metyatech/TestPlugin/releases/download/fab-v1.0.0/TestPlugin_1.0.0_UE5.9_Win64.zip'
            }
        }
        Invoke-FabProductReleaseCore -PluginPath $root -OutputDirectory $outputRoot `
            -PublishProjectFiles | Out-Null
        $manifest = Get-Content -Raw -LiteralPath (
            Join-Path $outputRoot 'TestPlugin\FabSubmission\FabPortalSubmission.json') | ConvertFrom-Json
        $manifest.portalReady | Should -BeTrue
        @($manifest.packages.projectFileLink) | Should -BeExactly @(
            'https://github.com/metyatech/TestPlugin/releases/download/fab-v1.0.0/TestPlugin_1.0.0_UE5.8_Win64.zip',
            'https://github.com/metyatech/TestPlugin/releases/download/fab-v1.0.0/TestPlugin_1.0.0_UE5.9_Win64.zip')
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
        $checklist | Should -Match 'PASS - manifest integrity'
        $checklist | Should -Match 'Future browser automation / Fab human review:'
    }
}
