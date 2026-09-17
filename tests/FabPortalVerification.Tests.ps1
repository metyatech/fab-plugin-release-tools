# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'FabPluginReleaseTools.psd1') -Force

Describe 'Fab portal verify-only contracts' {
    It 'exposes no Portal write parameters from the PowerShell wrapper' {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $command = Get-Command -Name (Join-Path $repositoryRoot 'Invoke-FabPortalSubmission.ps1')
        $command.Parameters.Keys | Should -Not -Contain 'SaveDraft'
        $command.Parameters.Keys | Should -Not -Contain 'SubmitForReview'
    }

    It 'keeps the PowerShell module, tool, and Node CLI versions in sync' {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $moduleManifest = Import-PowerShellDataFile -Path (
            Join-Path $repositoryRoot 'FabPluginReleaseTools.psd1')
        $nodeCliPath = Join-Path $repositoryRoot 'FabPortalAutomation\src\cli.mjs'
        $nodeCliVersion = (& node $nodeCliPath --version).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Node CLI --version failed with exit code $LASTEXITCODE."
        }

        InModuleScope FabPluginReleaseTools -Parameters @{ expectedNodeVersion = $nodeCliVersion; manifestVersion = [string]$moduleManifest.ModuleVersion } {
            param($expectedNodeVersion, $manifestVersion)
            $moduleVersion = $manifestVersion
            $toolVersion = [string]$script:ToolVersion
            $nodeCliVersion = $expectedNodeVersion

            $moduleVersion | Should -BeExactly '0.8.2'
            $toolVersion | Should -BeExactly '0.8.2'
            $nodeCliVersion | Should -BeExactly '0.8.2'
            $moduleVersion | Should -BeExactly $toolVersion
            $toolVersion | Should -BeExactly $nodeCliVersion
        }
    }

    It 'enforces the href and link-mark contract in all rich-text schemas' {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $validRun = [ordered]@{
            text  = 'Docs'
            marks = @('link')
            href  = 'https://example.test/docs'
        }
        $richText = [ordered]@{
            blocks = @([ordered]@{
                    type = 'paragraph'
                    runs = @($validRun)
                })
        }
        $faq = [ordered]@{ question = 'Question?'; answer = 'Answer.' }
        $documents = [ordered]@{
            'FabListingFields.schema.json' = [ordered]@{
                schema_version = 1; product = 'Schema fixture'; version = '1.0.0'; title = 'Schema fixture';
                short_description = 'Short'; long_description = 'Docs'; product_type = 'Tools & Plugins'; category = 'Tools';
                subcategory = @(); tags_ordered = @('fixture', 'schema'); included_format = 'Unreal Engine';
                engine_versions = @('5.8'); platforms = @('Win64'); license = 'Fab Standard License';
                personal_price_usd = 0; professional_price_usd = 0; mature_content = $false; generated_with_ai = $false;
                allows_usage_with_ai = $true; promotional_content = $false; forum_post = $false; activation = 'Manual activation';
                documentation_url = 'https://example.test/docs'; support_url = 'https://example.test/support';
                source_repository_url = 'https://github.com/metyatech/schema-fixture'; media_order = @('media/one.png', 'media/two.png');
                faqs = @($faq); description_rich_text = $richText
            }
            'FabPortalSubmission.schema.json' = [ordered]@{
                schemaVersion = 2; pluginName = 'SchemaFixture'; productVersion = '1.0.0';
                listingId = '11111111-1111-4111-8111-111111111111'; title = 'Schema fixture'; shortDescription = 'Short';
                longDescription = 'Docs'; faqs = @($faq); additionalInformationRichText = $richText; descriptionRichText = $richText;
                productType = 'Tools & Plugins'; category = 'Tools'; subcategory = @(); tags = @('fixture'); includedFormat = 'Unreal Engine';
                engineVersions = @('5.8'); platforms = @('Win64'); license = 'Fab Standard License'; personalPriceUsd = 0;
                professionalPriceUsd = 0; matureContent = $false; generatedWithAi = $false; allowsUsageWithAi = $true;
                promotionalContent = $false; forumPost = $false; activation = 'Manual activation'; documentationUrl = 'https://example.test/docs';
                supportUrl = 'https://example.test/support'; technicalInformationFile = 'FabTechnicalInformation.txt';
                media = @([ordered]@{ order = 1; role = 'thumbnail'; bundleRelativePath = 'media/one.png'; sha256 = ('a' * 64) });
                packages = @([ordered]@{ engineVersion = '5.8'; versionTitle = 'UE 5.8'; bundleRelativePath = 'packages/5.8.zip'; sha256 = ('b' * 64); projectFileLink = $null });
                portalReady = $false
            }
            'FabPortalObservation.schema.json' = [ordered]@{
                schemaVersion = 1; source = 'interactive-browser'; manifestSha256 = ('c' * 64);
                observedAtUtc = '2026-09-17T00:00:00Z'; listingId = '11111111-1111-4111-8111-111111111111';
                listingTitle = 'Schema fixture'; listingStatus = 'Draft'; fields = @([ordered]@{
                        manifestJsonPath = 'descriptionRichText'; state = 'OBSERVED'; view = 'listing'; value = $richText
                    })
            }
        }
        $richProperty = @{
            'FabListingFields.schema.json' = 'description_rich_text'
            'FabPortalSubmission.schema.json' = 'descriptionRichText'
            'FabPortalObservation.schema.json' = 'value'
        }
        $schemaPaths = @{}
        foreach ($schemaName in $documents.Keys) {
            $schemaPaths[$schemaName] = Join-Path $repositoryRoot $schemaName
            $json = $documents[$schemaName] | ConvertTo-Json -Depth 20
            (Test-Json -Json $json -SchemaFile $schemaPaths[$schemaName] -ErrorAction SilentlyContinue) | Should -BeTrue -Because "$schemaName must accept a valid HTTPS link run."
        }
        foreach ($case in @(
                @{ Name = 'href without marks'; Mutate = { param($run) $run.PSObject.Properties.Remove('marks') } },
                @{ Name = 'href without link mark'; Mutate = { param($run) $run.marks = @('bold') } },
                @{ Name = 'link mark without href'; Mutate = { param($run) $run.PSObject.Properties.Remove('href') } }
            )) {
            foreach ($schemaName in $documents.Keys) {
                $candidate = $documents[$schemaName] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $rich = if ($schemaName -eq 'FabPortalObservation.schema.json') { $candidate.fields[0].value } else { $candidate.($richProperty[$schemaName]) }
                & $case.Mutate $rich.blocks[0].runs[0]
                $json = $candidate | ConvertTo-Json -Depth 20
                (Test-Json -Json $json -SchemaFile $schemaPaths[$schemaName] -ErrorAction SilentlyContinue) | Should -BeFalse -Because "$schemaName must reject $($case.Name)."
            }
        }
    }
}
