# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab TPS declaration management' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Test-FabTpsDeclaration.ps1'

        function Write-TpsFixtureJson {
            param(
                [Parameter(Mandatory)]
                [object]$Value,

                [Parameter(Mandatory)]
                [string]$Path
            )

            [System.IO.File]::WriteAllText(
                $Path,
                (($Value | ConvertTo-Json -Depth 20) + "`n"),
                [System.Text.UTF8Encoding]::new($false))
        }

        function Initialize-TpsFixture {
            param(
                [Parameter(Mandatory)]
                [string]$Root
            )

            $noticeDirectory = Join-Path $Root 'Source\ThirdParty\test'
            [System.IO.Directory]::CreateDirectory($noticeDirectory) | Out-Null
            $listing = [ordered]@{
                schema_version        = 1
                listing_id             = '19cb2daa-b018-46ae-b28c-7bfe21075c4a'
                product                = 'TPS Fixture Product'
                version                = '2.3.4'
                title                  = 'TPS Fixture Product'
                short_description     = 'Fixture'
                long_description      = 'Fixture'
                product_type           = 'Tools & Plugins'
                category               = 'Engine Tools'
                subcategory            = @()
                tags_ordered           = @('fixture')
                included_format        = 'Unreal Engine'
                engine_versions        = @('5.8')
                platforms              = @('Win64')
                license                = 'Fab Standard License'
                personal_price_usd     = 0
                professional_price_usd = 0
                mature_content         = $false
                generated_with_ai      = $false
                allows_usage_with_ai   = $true
                promotional_content    = $false
                forum_post             = $false
                activation             = 'Manual activation'
                documentation_url     = 'https://example.test/docs'
                support_url            = 'https://example.test/support'
                source_repository_url  = 'https://github.com/metyatech/TpsFixture'
                media_order            = @('media/one.png', 'media/two.png')
            }
            $metadata = [ordered]@{
                schemaVersion = 1
                product       = 'TPS Fixture Product'
                technicalInformation = [ordered]@{
                    features                       = @('Fixture feature')
                    codeModules                    = @([ordered]@{ name = 'TpsFixture'; type = 'Runtime'; description = 'Fixture module.' })
                    numberOfBlueprints             = 0
                    numberOfCppClasses             = 0
                    networkReplicated              = $false
                    networkReplicationNotes        = 'The fixture does not replicate data.'
                    supportedDevelopmentPlatforms = @('Win64')
                    supportedTargetBuildPlatforms = @('Win64')
                    dependencies                   = @('Bundled Test Library 1.2.3')
                    prerequisites                  = @('Unreal Engine 5.8')
                    documentationUrl               = 'https://example.test/docs'
                    exampleProjectUrl              = $null
                    exampleProjectNotes            = 'No example project is required for this fixture.'
                    additionalNotes               = 'Fixture metadata.'
                }
            }
            $declaration = [ordered]@{
                software_name             = 'Test Library'
                version                   = '1.2.3'
                vendor                    = 'Test Vendor'
                homepage_url              = 'https://example.test/library'
                source_repository_url     = 'https://github.com/example/test-library'
                source_tag                = 'v1.2.3'
                source_commit             = ('a' * 40)
                license                   = 'MIT'
                license_url               = 'https://example.test/library/LICENSE'
                bundled                   = $true
                linkage                   = 'dynamic'
                platforms                 = @('Win64')
                upstream_source_modified  = $false
                sends_data_to_creator     = $false
                distributed_notice_file   = 'Source/ThirdParty/test/test.tps'
                purpose                   = 'Fixture parsing.'
                why_required              = 'The fixture module uses the library.'
                additional_information    = 'Built as a shared library for the fixture.'
            }
            $declarations = [ordered]@{ schema_version = 1; declarations = @($declaration) }
            $release = [ordered]@{
                schemaVersion = 1
                pluginName    = 'TpsFixture'
                descriptorFile = 'TpsFixture.uplugin'
                platforms     = @('Win64')
            }
            $descriptor = [ordered]@{
                FileVersion            = 3
                VersionName            = '2.3.4'
                FriendlyName           = 'TPS Fixture'
                SupportedTargetPlatforms = @('Win64')
                Modules                = @()
            }
            $buildInfo = [ordered]@{
                Version                         = '1.2.3'
                SourceRepository               = 'https://github.com/example/test-library.git'
                SourceTag                      = 'v1.2.3'
                SourceCommit                   = ('a' * 40)
                Architecture                   = 'x64'
                DistributedThirdPartyNoticeFile = 'test.tps'
                CMakeOptions                   = @([ordered]@{ Name = 'BUILD_SHARED_LIBS'; Value = 'ON' })
            }
            Write-TpsFixtureJson -Value $listing -Path (Join-Path $Root 'FabListingFields.json')
            Write-TpsFixtureJson -Value $metadata -Path (Join-Path $Root 'FabSubmissionMetadata.json')
            Write-TpsFixtureJson -Value $declarations -Path (Join-Path $Root 'FabTpsDeclarations.json')
            Write-TpsFixtureJson -Value $release -Path (Join-Path $Root 'FabPluginRelease.json')
            Write-TpsFixtureJson -Value $descriptor -Path (Join-Path $Root 'TpsFixture.uplugin')
            Write-TpsFixtureJson -Value $buildInfo -Path (Join-Path $noticeDirectory 'BUILD-INFO.json')
            [System.IO.File]::WriteAllText(
                (Join-Path $noticeDirectory 'assimp.Build.cs'),
                'if (Target.Platform != UnrealTargetPlatform.Win64) {} PublicDelayLoadDLLs.Add("test.dll"); RuntimeDependencies.Add("test.dll");',
                [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText(
                (Join-Path $noticeDirectory 'test.tps'),
                '<TpsData><Name>Test Library</Name><Eula>https://example.test/library/LICENSE</Eula><AdditionalInfo><Name>Test Library</Name><Version>1.2.3</Version><Url>https://example.test/library</Url><License>MIT</License></AdditionalInfo></TpsData>',
                [System.Text.UTF8Encoding]::new($false))
        }

        function Initialize-AssimpTpsFixture {
            param(
                [Parameter(Mandatory)]
                [string]$Root
            )

            Initialize-TpsFixture -Root $Root
            $noticeDirectory = Join-Path $Root 'Source\ThirdParty\assimp'
            [System.IO.Directory]::CreateDirectory($noticeDirectory) | Out-Null
            $declarationsPath = Join-Path $Root 'FabTpsDeclarations.json'
            $declarations = Get-Content -Raw $declarationsPath | ConvertFrom-Json
            $declaration = $declarations.declarations[0]
            $declaration.software_name = 'Open Asset Import Library (assimp)'
            $declaration.version = '6.0.5'
            $declaration.vendor = 'assimp team'
            $declaration.homepage_url = 'https://www.assimp.org/'
            $declaration.source_repository_url = 'https://github.com/assimp/assimp'
            $declaration.source_tag = 'v6.0.5'
            $declaration.source_commit = '392a658f9c271be965271f45e7521a1b80ea4392'
            $declaration.license = 'BSD-3-Clause'
            $declaration.license_url = 'https://github.com/assimp/assimp/blob/v6.0.5/LICENSE'
            $declaration.distributed_notice_file = 'Source/ThirdParty/assimp/assimp.tps'
            $declaration.purpose = 'Fixture runtime mesh import.'
            $declaration.why_required = 'The fixture module uses Assimp.'
            $declaration.additional_information = 'Fixture Assimp build evidence.'
            Write-TpsFixtureJson -Value $declarations -Path $declarationsPath

            $metadataPath = Join-Path $Root 'FabSubmissionMetadata.json'
            $metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
            $metadata.technicalInformation.dependencies = @('Bundled Assimp 6.0.5')
            Write-TpsFixtureJson -Value $metadata -Path $metadataPath

            $buildInfo = [ordered]@{
                Version                         = '6.0.5'
                SourceRepository               = 'https://github.com/assimp/assimp.git'
                SourceTag                      = 'v6.0.5'
                SourceCommit                   = '392a658f9c271be965271f45e7521a1b80ea4392'
                Architecture                   = 'x64'
                DistributedThirdPartyNoticeFile = 'assimp.tps'
                CMakeOptions                   = @([ordered]@{ Name = 'BUILD_SHARED_LIBS'; Value = 'ON' })
            }
            Write-TpsFixtureJson -Value $buildInfo -Path (Join-Path $noticeDirectory 'BUILD-INFO.json')
            [System.IO.File]::WriteAllText(
                (Join-Path $noticeDirectory 'assimp.Build.cs'),
                'if (Target.Platform != UnrealTargetPlatform.Win64) {} PublicAdditionalLibraries.Add("assimp.lib"); PublicDelayLoadDLLs.Add("assimp.dll"); RuntimeDependencies.Add("assimp.dll");',
                [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText(
                (Join-Path $noticeDirectory 'assimp.tps'),
                '<TpsData><Name>assimp</Name><Eula>https://github.com/assimp/assimp/blob/v6.0.5/LICENSE</Eula><AdditionalInfo><Name>assimp</Name><Version>6.0.5</Version><Url>https://github.com/assimp/assimp/releases/tag/v6.0.5</Url><License>BSD-3-Clause</License></AdditionalInfo></TpsData>',
                [System.Text.UTF8Encoding]::new($false))
        }

        function Invoke-TpsFixture {
            param(
                [Parameter(Mandatory)]
                [string]$PluginRoot,

                [Parameter(Mandatory)]
                [string]$OutputRoot,

                [string]$ListingFieldsPath
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = 'pwsh.exe'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @(
                    '-NoProfile', '-File', $scriptPath,
                    '-PluginPath', $PluginRoot,
                    '-OutputDirectory', $OutputRoot)) {
                [void]$startInfo.ArgumentList.Add($argument)
            }
            if (-not [string]::IsNullOrWhiteSpace($ListingFieldsPath)) {
                [void]$startInfo.ArgumentList.Add('-ListingFieldsPath')
                [void]$startInfo.ArgumentList.Add($ListingFieldsPath)
            }
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            try {
                [void]$process.Start()
                $output = $process.StandardOutput.ReadToEndAsync()
                $errors = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                [System.Threading.Tasks.Task]::WaitAll(@($output, $errors))
                return [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    Output   = $output.Result
                    Error    = $errors.Result
                }
            }
            finally {
                $process.Dispose()
            }
        }
    }

    It 'validates a declaration and emits deterministic copy/paste artifacts' {
        $pluginRoot = Join-Path $TestDrive 'ValidPlugin'
        $outputRoot = Join-Path $TestDrive 'artifacts'
        Initialize-TpsFixture -Root $pluginRoot

        $result = Invoke-TpsFixture -PluginRoot $pluginRoot -OutputRoot $outputRoot

        $result.ExitCode | Should -Be 0 -Because $result.Error
        $result.Output | Should -Match 'FAB TPS DECLARATION: PASS'
        $jsonPath = Join-Path $outputRoot 'FabTpsSubmission.json'
        $textPath = Join-Path $outputRoot 'FabTpsSubmission.txt'
        $jsonPath | Should -Exist
        $textPath | Should -Exist
        $artifact = Get-Content -Raw $jsonPath | ConvertFrom-Json
        $artifact.product | Should -BeExactly 'TPS Fixture Product'
        $artifact.version | Should -BeExactly '2.3.4'
        $artifact.listing_id | Should -BeExactly '19cb2daa-b018-46ae-b28c-7bfe21075c4a'
        $artifact.declarations[0].software_name | Should -BeExactly 'Test Library'
        $expectedText = @"
Fab Third-Party Software Declaration
====================================
Product: TPS Fixture Product
Version: 2.3.4
Fab Listing ID: 19cb2daa-b018-46ae-b28c-7bfe21075c4a

Third-Party Software 1
-----------------------
Software name: Test Library
Version: 1.2.3
Vendor: Test Vendor
Homepage URL: https://example.test/library
Source repository URL: https://github.com/example/test-library
Source tag: v1.2.3
Source commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
License: MIT
License URL: https://example.test/library/LICENSE
Bundled: Yes
Linkage: dynamic
Platforms: Win64
Upstream source modified: No
Sends data to creator: No
Distributed notice file: Source/ThirdParty/test/test.tps
Purpose: Fixture parsing.
Why required: The fixture module uses the library.
Additional information: Built as a shared library for the fixture.
"@ -replace "`r`n", "`n"
        $expectedText += "`n"
        (Get-Content -Raw $textPath) | Should -BeExactly $expectedText
    }

    It 'takes generated product identity from a custom listing fields file' {
        $pluginRoot = Join-Path $TestDrive 'CustomListingPlugin'
        $outputRoot = Join-Path $TestDrive 'CustomListingOutput'
        $listingPath = Join-Path $TestDrive 'CustomListingFields.json'
        Initialize-TpsFixture -Root $pluginRoot
        $listing = Get-Content -Raw (Join-Path $pluginRoot 'FabListingFields.json') | ConvertFrom-Json
        $listing.product = 'Custom TPS Product'
        $listing.version = '8.7.6'
        $listing.listing_id = '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
        Write-TpsFixtureJson -Value $listing -Path $listingPath
        $metadata = Get-Content -Raw (Join-Path $pluginRoot 'FabSubmissionMetadata.json') | ConvertFrom-Json
        $metadata.product = 'Custom TPS Product'
        Write-TpsFixtureJson -Value $metadata -Path (Join-Path $pluginRoot 'FabSubmissionMetadata.json')

        $result = Invoke-TpsFixture -PluginRoot $pluginRoot -OutputRoot $outputRoot `
            -ListingFieldsPath $listingPath

        $result.ExitCode | Should -Be 0 -Because $result.Error
        $artifact = Get-Content -Raw (Join-Path $outputRoot 'FabTpsSubmission.json') | ConvertFrom-Json
        $artifact.product | Should -BeExactly 'Custom TPS Product'
        $artifact.version | Should -BeExactly '8.7.6'
        $artifact.listing_id | Should -BeExactly '42e5c3b5-36c3-4a91-ba59-8101812e62c3'
    }

    It 'keeps generic declarations compatible without Assimp evidence files' {
        $pluginRoot = Join-Path $TestDrive 'GenericWithoutEvidence'
        $outputRoot = Join-Path $TestDrive 'GenericWithoutEvidenceOutput'
        Initialize-TpsFixture -Root $pluginRoot
        [System.IO.File]::Delete((Join-Path $pluginRoot 'Source\ThirdParty\test\BUILD-INFO.json'))
        [System.IO.File]::Delete((Join-Path $pluginRoot 'Source\ThirdParty\test\assimp.Build.cs'))

        $result = Invoke-TpsFixture -PluginRoot $pluginRoot -OutputRoot $outputRoot

        $result.ExitCode | Should -Be 0 -Because $result.Error
        (Join-Path $outputRoot 'FabTpsSubmission.txt') | Should -Exist
        (Join-Path $outputRoot 'FabTpsSubmission.json') | Should -Exist
    }

    It 'rejects missing or contradictory Assimp evidence' -ForEach @(
        @{ Name = 'missing BUILD-INFO.json'; Change = {
                param($root)
                [System.IO.File]::Delete((Join-Path $root 'Source\ThirdParty\assimp\BUILD-INFO.json'))
            } },
        @{ Name = 'BUILD-INFO Version mismatch'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\BUILD-INFO.json'
                $json = Get-Content -Raw $path | ConvertFrom-Json
                $json.Version = '6.0.4'
                Write-TpsFixtureJson -Value $json -Path $path
            } },
        @{ Name = 'SourceTag mismatch'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\BUILD-INFO.json'
                $json = Get-Content -Raw $path | ConvertFrom-Json
                $json.SourceTag = 'v6.0.4'
                Write-TpsFixtureJson -Value $json -Path $path
            } },
        @{ Name = 'SourceCommit mismatch'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\BUILD-INFO.json'
                $json = Get-Content -Raw $path | ConvertFrom-Json
                $json.SourceCommit = 'a' * 40
                Write-TpsFixtureJson -Value $json -Path $path
            } },
        @{ Name = 'missing BUILD_SHARED_LIBS'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\BUILD-INFO.json'
                $json = Get-Content -Raw $path | ConvertFrom-Json
                $json.CMakeOptions = @()
                Write-TpsFixtureJson -Value $json -Path $path
            } },
        @{ Name = 'BUILD_SHARED_LIBS OFF with dynamic linkage'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\BUILD-INFO.json'
                $json = Get-Content -Raw $path | ConvertFrom-Json
                $json.CMakeOptions[0].Value = 'OFF'
                Write-TpsFixtureJson -Value $json -Path $path
            } },
        @{ Name = 'missing assimp.Build.cs'; Change = {
                param($root)
                [System.IO.File]::Delete((Join-Path $root 'Source\ThirdParty\assimp\assimp.Build.cs'))
            } },
        @{ Name = 'missing PublicAdditionalLibraries'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\assimp.Build.cs'
                $text = Get-Content -Raw $path
                [System.IO.File]::WriteAllText($path, $text.Replace('PublicAdditionalLibraries.Add("assimp.lib");', ''))
            } },
        @{ Name = 'missing PublicDelayLoadDLLs'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\assimp.Build.cs'
                $text = Get-Content -Raw $path
                [System.IO.File]::WriteAllText($path, $text.Replace('PublicDelayLoadDLLs.Add("assimp.dll");', ''))
            } },
        @{ Name = 'missing RuntimeDependencies'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\assimp.Build.cs'
                $text = Get-Content -Raw $path
                [System.IO.File]::WriteAllText($path, $text.Replace('RuntimeDependencies.Add("assimp.dll");', ''))
            } },
        @{ Name = 'assimp.tps Version mismatch'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\assimp.tps'
                $text = Get-Content -Raw $path
                [System.IO.File]::WriteAllText($path, $text.Replace('6.0.5', '6.0.4'))
            } },
        @{ Name = 'assimp.tps License mismatch'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\assimp.tps'
                $text = Get-Content -Raw $path
                [System.IO.File]::WriteAllText($path, $text.Replace('BSD-3-Clause', 'MIT'))
            } },
        @{ Name = 'assimp.tps Eula mismatch'; Change = {
                param($root)
                $path = Join-Path $root 'Source\ThirdParty\assimp\assimp.tps'
                $text = Get-Content -Raw $path
                [System.IO.File]::WriteAllText($path, $text.Replace('blob/v6.0.5/LICENSE', 'blob/v6.0.4/LICENSE'))
            } },
        @{ Name = 'descriptor platform mismatch'; Change = {
                param($root)
                $path = Join-Path $root 'TpsFixture.uplugin'
                $json = Get-Content -Raw $path | ConvertFrom-Json
                $json.SupportedTargetPlatforms = @('Linux')
                Write-TpsFixtureJson -Value $json -Path $path
            } }
    ) {
        $pluginRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $outputRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Initialize-AssimpTpsFixture -Root $pluginRoot
        & $Change $pluginRoot

        $result = Invoke-TpsFixture -PluginRoot $pluginRoot -OutputRoot $outputRoot

        $result.ExitCode | Should -Be 1 -Because $result.Output
        $result.Output | Should -Match 'FAB TPS DECLARATION: FAIL'
    }

    It 'rejects non-HTTPS URLs, platform conflicts, missing notices, and dependency conflicts' -ForEach @(
        @{ Name = 'a non-HTTPS URL'; Change = { param($root) $json = Get-Content -Raw (Join-Path $root 'FabTpsDeclarations.json') | ConvertFrom-Json; $json.declarations[0].homepage_url = 'http://example.test/library'; Write-TpsFixtureJson -Value $json -Path (Join-Path $root 'FabTpsDeclarations.json') } },
        @{ Name = 'a platform conflict'; Change = { param($root) $json = Get-Content -Raw (Join-Path $root 'FabTpsDeclarations.json') | ConvertFrom-Json; $json.declarations[0].platforms = @('Linux'); Write-TpsFixtureJson -Value $json -Path (Join-Path $root 'FabTpsDeclarations.json') } },
        @{ Name = 'a missing notice'; Change = { param($root) [System.IO.File]::Delete((Join-Path $root 'Source\ThirdParty\test\test.tps')) } },
        @{ Name = 'a dependency conflict'; Change = { param($root) $json = Get-Content -Raw (Join-Path $root 'FabSubmissionMetadata.json') | ConvertFrom-Json; $json.technicalInformation.dependencies = @('Bundled Other Library 9.9.9'); Write-TpsFixtureJson -Value $json -Path (Join-Path $root 'FabSubmissionMetadata.json') } }
    ) {
        $pluginRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $outputRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Initialize-TpsFixture -Root $pluginRoot
        & $Change $pluginRoot

        $result = Invoke-TpsFixture -PluginRoot $pluginRoot -OutputRoot $outputRoot

        $result.ExitCode | Should -Be 1 -Because $result.Output
        $result.Output | Should -Match 'FAB TPS DECLARATION: FAIL'
    }
}
