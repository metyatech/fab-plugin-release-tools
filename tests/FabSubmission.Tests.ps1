# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab submission preflight' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Test-FabPluginSubmission.ps1'

        function Initialize-SubmissionFixture {
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [switch]$BadLocation,

                [switch]$OtherPluginLocation,

                [switch]$NetworkReplicated
            )

            [System.IO.Directory]::CreateDirectory((Join-Path $Root 'Config')) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $Root 'Source\TestPlugin')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root 'Config\FilterPlugin.ini'), '[FilterPlugin]')
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'Source\TestPlugin\TestPlugin.Build.cs'),
                '// Copyright (c) 2026 metyatech. All rights reserved.')
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'Source\TestPlugin\TestPlugin.h'),
                "// Copyright (c) 2026 metyatech. All rights reserved.`nUCLASS()`nclass UTestPlugin {};`n")
            $location = if ($BadLocation) {
                'FPaths::ProjectPluginsDir() + TEXT("TestPlugin");'
            }
            elseif ($OtherPluginLocation) {
                'FPaths::Combine(FPaths::ProjectPluginsDir(), TEXT("SomeOtherPlugin"));'
            }
            else {
                'IPluginManager::Get().FindPlugin(TEXT("TestPlugin"));'
            }
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'Source\TestPlugin\TestPlugin.cpp'),
                "// Copyright (c) 2026 metyatech. All rights reserved.`n$location`n")
            [System.IO.File]::WriteAllText((Join-Path $Root 'README.md'), '# Test Plugin')
            [System.IO.File]::WriteAllText((Join-Path $Root 'TestPlugin.uplugin'), @'
{
  "FileVersion": 3,
  "Version": 1,
  "VersionName": "1.0.0",
  "FriendlyName": "Test Plugin",
  "Description": "Fixture",
  "Category": "Tools",
  "Modules": [{ "Name": "TestPlugin", "Type": "Runtime" }]
}
'@)
            [System.IO.File]::WriteAllText((Join-Path $Root 'FabPluginRelease.json'), @'
{
  "schemaVersion": 1,
  "pluginName": "TestPlugin",
  "descriptorFile": "TestPlugin.uplugin",
  "engineVersions": ["5.8"],
  "platforms": ["Win64"],
  "distributionModules": ["TestPlugin"],
  "documentationUrl": "https://github.com/metyatech",
  "supportUrl": "https://github.com/metyatech",
  "publisher": { "name": "metyatech", "url": "https://github.com/metyatech", "copyrightNotice": "// Copyright (c) 2026 metyatech. All rights reserved." },
  "listingId": null,
  "enabledPluginDependencies": [],
  "content": { "mode": "none" },
  "includeDirectories": ["Config", "Source/TestPlugin"],
  "includeFiles": ["TestPlugin.uplugin", "README.md"],
  "requiredPackageFiles": ["TestPlugin.uplugin", "Config/FilterPlugin.ini", "Source/TestPlugin/TestPlugin.Build.cs", "README.md"],
  "customDistributionPaths": ["README.md"],
  "thirdPartyLicenseSets": [],
  "forbiddenPackagePatterns": [],
  "buildLogFailPatterns": []
}
'@)
            [System.IO.File]::WriteAllText((Join-Path $Root 'FabSubmissionMetadata.json'), @'
{
  "schemaVersion": 1,
  "product": "Test Plugin",
  "technicalInformation": {
    "features": ["Loads test content."],
    "codeModules": [{ "name": "TestPlugin", "type": "Runtime", "description": "Runtime fixture module." }],
    "numberOfBlueprints": 0,
    "numberOfCppClasses": 1,
    "networkReplicated": false,
    "networkReplicationNotes": "The plugin does not provide network replication.",
    "supportedDevelopmentPlatforms": ["Win64"],
    "supportedTargetBuildPlatforms": ["Win64"],
    "dependencies": [],
    "prerequisites": [],
    "documentationUrl": "https://github.com/metyatech",
    "exampleProjectUrl": null,
    "exampleProjectNotes": "No example project is required for this fixture.",
    "additionalNotes": "Fixture metadata."
  }
}
'@)
            $metadataPath = Join-Path $Root 'FabSubmissionMetadata.json'
            $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
            if ($NetworkReplicated) { $metadata.technicalInformation.networkReplicated = $true }
            $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath
        }

        function Invoke-SubmissionFixture {
            param([Parameter(Mandatory)][string]$Root)
            $output = & pwsh -NoProfile -NonInteractive -File $scriptPath -PluginPath $Root 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = [string]::Join("`n", $output) }
        }
    }

    It 'passes a good fixture and permits identifier lookup' {
        $root = Join-Path $TestDrive 'Good'
        Initialize-SubmissionFixture -Root $root
        $result = Invoke-SubmissionFixture -Root $root
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'FAB SUBMISSION CHECK: PASS'
        Test-Path (Join-Path $PSScriptRoot '..\artifacts\TestPlugin\submission\FabTechnicalInformation.txt') | Should -BeTrue
    }

    It 'fails an explicit plugin-location hardcode' {
        $root = Join-Path $TestDrive 'BadLocation'
        Initialize-SubmissionFixture -Root $root -BadLocation
        $result = Invoke-SubmissionFixture -Root $root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Hardcoded plugin location detected'
    }

    It 'permits a different plugin location reference' {
        $root = Join-Path $TestDrive 'OtherLocation'
        Initialize-SubmissionFixture -Root $root -OtherPluginLocation
        $result = Invoke-SubmissionFixture -Root $root
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'FAB SUBMISSION CHECK: PASS'
    }

    It 'renders empty lists and boolean values for Fab copy and paste' {
        $root = Join-Path $TestDrive 'TechnicalInformation'
        Initialize-SubmissionFixture -Root $root
        $result = Invoke-SubmissionFixture -Root $root
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $text = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\artifacts\TestPlugin\submission\FabTechnicalInformation.txt')
        $text | Should -Match '(?m)^Dependencies: None$'
        $text | Should -Match '(?m)^Prerequisites: None$'
        $text | Should -Match '(?m)^Network Replicated: No$'

        $root = Join-Path $TestDrive 'TechnicalInformationReplicated'
        Initialize-SubmissionFixture -Root $root -NetworkReplicated
        $result = Invoke-SubmissionFixture -Root $root
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $text = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\artifacts\TestPlugin\submission\FabTechnicalInformation.txt')
        $text | Should -Match '(?m)^Network Replicated: Yes$'
    }

    It 'reports standalone license files and tps files separately without failing' {
        $root = Join-Path $TestDrive 'Package'
        Initialize-SubmissionFixture -Root $root
        $zipPath = Join-Path $TestDrive 'Package.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entryName in @('TestPlugin/TestPlugin.uplugin', 'TestPlugin/LICENSE', 'TestPlugin/Source/ThirdParty/test.tps')) {
                $entry = $archive.CreateEntry($entryName)
                $writer = [System.IO.StreamWriter]::new($entry.Open())
                try { $writer.Write('fixture') } finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        $outputRoot = Join-Path $TestDrive 'Output'
        $result = & pwsh -NoProfile -NonInteractive -File $scriptPath -PluginPath $root -PackageZipPath $zipPath `
            -OutputDirectory $outputRoot 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ([string]::Join("`n", $result))
        ([string]::Join("`n", $result)) | Should -Match 'Review Required: standalone license-related files'
        ([string]::Join("`n", $result)) | Should -Match 'Third Party Software metadata'
    }
}
