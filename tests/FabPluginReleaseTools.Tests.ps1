# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'FabPluginReleaseTools.psd1') -Force

InModuleScope FabPluginReleaseTools {
    BeforeAll {
        function Get-TestConfigurationObject {
            return [ordered]@{
                schemaVersion              = 1
                pluginName                 = 'TestPlugin'
                descriptorFile             = 'TestPlugin.uplugin'
                engineVersions             = @('5.8')
                platforms                  = @('Win64')
                distributionModules        = @('TestPlugin')
                enabledPluginDependencies  = @()
                publisher                  = [ordered]@{
                    name            = 'metyatech'
                    url             = 'https://github.com/metyatech'
                    copyrightNotice = '// Copyright (c) 2026 metyatech. All rights reserved.'
                }
                listingId                  = '19cb2daa-b018-46ae-b28c-7bfe21075c4a'
                documentationUrl            = 'https://github.com/metyatech'
                supportUrl                  = 'https://github.com/metyatech'
                content                     = [ordered]@{ mode = 'none' }
                includeDirectories          = @('Config', 'Source/TestPlugin')
                includeFiles                = @('TestPlugin.uplugin', 'README.md', 'LICENSE')
                requiredPackageFiles        = @(
                    'TestPlugin.uplugin',
                    'Config/FilterPlugin.ini',
                    'Source/TestPlugin/TestPlugin.Build.cs',
                    'README.md',
                    'LICENSE')
                customDistributionPaths     = @('README.md', 'LICENSE')
                thirdPartyLicenseSets       = @()
                forbiddenPackagePatterns    = @('^Forbidden(?:/|$)')
                buildLogFailPatterns        = @()
            }
        }

        function Save-TestConfiguration {
            param(
                [Parameter(Mandatory)]
                [object]$Configuration,

                [Parameter(Mandatory)]
                [string]$Path
            )

            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
            [System.IO.File]::WriteAllText(
                $Path,
                ($Configuration | ConvertTo-Json -Depth 30) + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false))
        }

        function Get-TestDescriptorObject {
            param(
                [string]$EngineVersion = '5.7.0',
                [string[]]$Dependencies = @()
            )

            $descriptor = [ordered]@{
                FileVersion       = 3
                Version           = 1
                VersionName       = '1.0.0'
                FriendlyName      = 'Test Plugin'
                Description       = 'Test plugin fixture.'
                Category          = 'Testing'
                EngineVersion     = $EngineVersion
                Modules           = @(
                    [ordered]@{
                        Name              = 'TestPlugin'
                        Type              = 'Runtime'
                        LoadingPhase      = 'Default'
                        PlatformAllowList = @('Win64')
                    },
                    [ordered]@{
                        Name              = 'TestPluginEditor'
                        Type              = 'Editor'
                        LoadingPhase      = 'Default'
                        PlatformAllowList = @('Win64')
                    })
                MarketplaceURL    = 'https://legacy.invalid'
                Installed         = $false
                CanContainContent = $false
            }
            if ($Dependencies.Count -gt 0) {
                $descriptor.Plugins = @($Dependencies | ForEach-Object {
                        [ordered]@{ Name = $_; Enabled = $true }
                    })
            }
            return $descriptor
        }

        function Invoke-TestPluginSetup {
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [switch]$PackContent,

                [switch]$InitializeGit
            )

            [System.IO.Directory]::CreateDirectory((Join-Path $Root 'Config')) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $Root 'Source\TestPlugin')) | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'Config\FilterPlugin.ini'),
                "[FilterPlugin]`n/README.md`n/LICENSE`n")
            $copyright = '// Copyright (c) 2026 metyatech. All rights reserved.'
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'Source\TestPlugin\TestPlugin.Build.cs'),
                "$copyright`npublic class TestPlugin : ModuleRules { }`n")
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'Source\TestPlugin\TestPlugin.h'),
                "$copyright`n#pragma once`n")
            [System.IO.File]::WriteAllText((Join-Path $Root 'README.md'), "# Test Plugin`n")
            [System.IO.File]::WriteAllText((Join-Path $Root 'LICENSE'), "Fixture license`n")
            Save-TestConfiguration -Configuration (Get-TestConfigurationObject) `
                -Path (Join-Path $Root 'FabPluginRelease.json')
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'TestPlugin.uplugin'),
                ((Get-TestDescriptorObject) | ConvertTo-Json -Depth 30) + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false))
            if ($PackContent) {
                [System.IO.Directory]::CreateDirectory((Join-Path $Root 'Content\TestPlugin')) | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $Root 'Content\TestPlugin\Asset.uasset'), 'asset')
            }
            if ($InitializeGit) {
                [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @('init', '-b', 'master') -WorkingDirectory $Root)
                [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @('-C', $Root, 'config', 'user.name', 'Test User'))
                [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @('-C', $Root, 'config', 'user.email', 'test@example.invalid'))
                [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @('-C', $Root, 'remote', 'add', 'origin', 'https://example.invalid/TestPlugin.git'))
                [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @('-C', $Root, 'add', '.'))
                [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @('-C', $Root, 'commit', '-m', 'test fixture'))
            }
        }

        function Invoke-FakeEngineSetup {
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [ValidateSet('Success', 'Failure', 'ErrorLog', 'Warning', 'Timeout', 'MissingDescriptor', 'MissingDll', 'VersionMismatch')]
                [string]$Behavior = 'Success'
            )

            $batchDirectory = Join-Path $Root 'Engine\Build\BatchFiles'
            [System.IO.Directory]::CreateDirectory($batchDirectory) | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $Root 'Engine\Build\Build.version'),
                '{"MajorVersion":5,"MinorVersion":8}')
            $body = @(
                '@echo off',
                'setlocal EnableExtensions DisableDelayedExpansion',
                'set "plugin="',
                'set "package="',
                ':parse',
                'if "%~1"=="" goto run',
                'set "arg=%~1"',
                'if /i "%arg:~0,8%"=="-Plugin=" set "plugin=%arg:~8%"',
                'if /i "%arg:~0,9%"=="-Package=" set "package=%arg:~9%"',
                'shift',
                'goto parse',
                ':run')
            switch ($Behavior) {
                'Failure' { $body += @('echo intentional failure', 'exit /b 7') }
                'ErrorLog' { $body += @('echo LogCompile: Error: intentional', 'exit /b 0') }
                'Timeout' { $body += @('ping 127.0.0.1 -n 10 >nul', 'exit /b 0') }
                default {
                    $body += @(
                        'mkdir "%package%\TestPlugin\Binaries\Win64"',
                        'copy /y "%plugin%" "%package%\TestPlugin\TestPlugin.uplugin" >nul',
                        'echo binary>"%package%\TestPlugin\Binaries\Win64\TestPlugin.dll"')
                    if ($Behavior -eq 'Warning') {
                        $body += 'echo warning C4996: %plugin% deprecated'
                    }
                    if ($Behavior -eq 'MissingDescriptor') {
                        $body += 'del "%package%\TestPlugin\TestPlugin.uplugin"'
                    }
                    if ($Behavior -eq 'MissingDll') {
                        $body += 'del "%package%\TestPlugin\Binaries\Win64\TestPlugin.dll"'
                    }
                    if ($Behavior -eq 'VersionMismatch') {
                        $body += 'pwsh -NoLogo -NoProfile -NonInteractive -Command "$p=$env:package + ''\TestPlugin\TestPlugin.uplugin''; $j=ConvertFrom-Json (Get-Content -Raw $p); $j.EngineVersion=''5.7.0''; $json=ConvertTo-Json -InputObject $j -Depth 20; [IO.File]::WriteAllText($p,$json)"'
                    }
                    $body += 'exit /b 0'
                }
            }
            [System.IO.File]::WriteAllLines((Join-Path $batchDirectory 'RunUAT.bat'), $body)
        }

        function Import-TestConfiguration {
            param(
                [Parameter(Mandatory)]
                [string]$Directory,

                [object]$Configuration = (Get-TestConfigurationObject)
            )

            $path = Join-Path $Directory 'FabPluginRelease.json'
            Save-TestConfiguration -Configuration $Configuration -Path $path
            return Import-FabPluginReleaseConfiguration -ConfigPath $path -EngineVersion '5.8'
        }

        function New-TestInspectableZip {
            [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
            param(
                [Parameter(Mandatory)]
                [string]$SourceRoot,

                [Parameter(Mandatory)]
                [string]$PackageRoot,

                [Parameter(Mandatory)]
                [string]$ZipPath
            )

            if (-not $PSCmdlet.ShouldProcess($ZipPath, 'Create an inspectable test ZIP')) {
                return
            }
            Invoke-TestPluginSetup -Root $SourceRoot
            $configuration = Import-FabPluginReleaseConfiguration `
                -ConfigPath (Join-Path $SourceRoot 'FabPluginRelease.json') -EngineVersion '5.8'
            $sourceDescriptor = Read-PluginDescriptor -DescriptorPath (Join-Path $SourceRoot 'TestPlugin.uplugin')
            Copy-FabPluginAllowList -PluginPath $SourceRoot -DestinationRoot $PackageRoot `
                -Configuration $configuration
            [void](ConvertTo-SalesPluginDescriptor -SourceDescriptor $sourceDescriptor `
                    -Configuration $configuration -EngineVersion '5.8' `
                    -DestinationPath (Join-Path $PackageRoot 'TestPlugin.uplugin'))
            New-DeterministicFabZip -PluginRoot $PackageRoot -PluginName 'TestPlugin' `
                -ZipPath $ZipPath -Confirm:$false
            return $configuration
        }
    }

    Describe 'Strict configuration validation' {
        BeforeEach {
            Set-Variable -Name configurationPath -Value (Join-Path $TestDrive 'FabPluginRelease.json')
        }

        It 'accepts the valid configuration' {
            Save-TestConfiguration -Configuration (Get-TestConfigurationObject) -Path $configurationPath
            $result = Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8'
            $result.pluginName | Should -BeExactly 'TestPlugin'
        }

        It 'rejects an unknown property' {
            $configuration = Get-TestConfigurationObject
            $configuration.unknown = $true
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects a missing required property' {
            $configuration = Get-TestConfigurationObject
            [void]$configuration.Remove('supportUrl')
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects invalid schemaVersion' {
            $configuration = Get-TestConfigurationObject
            $configuration.schemaVersion = 2
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects invalid EngineVersion syntax in configuration' {
            $configuration = Get-TestConfigurationObject
            $configuration.engineVersions = @('UE5.8')
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects a requested version absent from engineVersions' {
            $configuration = Get-TestConfigurationObject
            $configuration.engineVersions = @('5.7')
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects a platform other than exact Win64' {
            $configuration = Get-TestConfigurationObject
            $configuration.platforms = @('Linux')
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects an invalid listingId' {
            $configuration = Get-TestConfigurationObject
            $configuration.listingId = 'ABC'
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects documentation URL userinfo' {
            $configuration = Get-TestConfigurationObject
            $configuration.documentationUrl = 'https://user:fixed-test-secret@example.com/docs'
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects support URL userinfo' {
            $configuration = Get-TestConfigurationObject
            $configuration.supportUrl = 'https://user@example.com/support'
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects unsafe relative path <Path>' -ForEach @(
            @{ Path = 'C:\absolute' },
            @{ Path = '\\server\share' },
            @{ Path = 'Source/../Secret' },
            @{ Path = 'Source/*.cpp' }) {
            $configuration = Get-TestConfigurationObject
            $configuration.includeFiles = @($Path)
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects a case-insensitive duplicate path' {
            $configuration = Get-TestConfigurationObject
            $configuration.includeFiles = @('README.md', 'readme.md')
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects include directory parent-child overlap' {
            $configuration = Get-TestConfigurationObject
            $configuration.includeDirectories = @('Source', 'Source/TestPlugin')
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }

        It 'rejects an invalid forbidden regex' {
            $configuration = Get-TestConfigurationObject
            $configuration.forbiddenPackagePatterns = @('[')
            Save-TestConfiguration -Configuration $configuration -Path $configurationPath
            { Import-FabPluginReleaseConfiguration -ConfigPath $configurationPath -EngineVersion '5.8' } |
                Should -Throw
        }
    }

    Describe 'Report secrecy and Git repository safety' {
        It 'removes userinfo, query, and fragment from a report URI' {
            $actual = ConvertTo-FabSafeReportUri `
                -Uri ([uri]'https://user:fixed-test-secret@example.com/docs?id=query-secret#part')
            $actual | Should -BeExactly 'https://example.com/docs'
        }

        It 'removes query and fragment from URL validation results' {
            $result = Test-FabHttpsUrl -Url 'https://github.com/metyatech?fixed-query=value#part'
            $result.requestedUrl | Should -BeExactly 'https://github.com/metyatech'
            $result.finalUrl | Should -Not -Match '[?#]'
        }

        It 'sanitizes an HTTPS origin containing a fixed test credential' {
            $pluginRoot = Join-Path $TestDrive 'SanitizedRemotePlugin'
            Invoke-TestPluginSetup -Root $pluginRoot -InitializeGit
            [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @(
                    '-C', $pluginRoot, 'remote', 'set-url', 'origin',
                    'https://x-access-token:fixed-test-secret@example.com/TestPlugin.git?token=query-secret#part'))
            $result = Get-GitRepositoryInformation -PluginPath $pluginRoot
            $result.Remote | Should -BeExactly 'https://example.com/TestPlugin.git'
        }

        It 'preserves an SCP-style Git remote' {
            ConvertTo-FabSafeGitRemote -Remote 'git@github.com:owner/repo.git' |
                Should -BeExactly 'git@github.com:owner/repo.git'
        }

        It 'accepts a Git root whose path differs only by Windows letter case' {
            $pluginRoot = Join-Path $TestDrive 'MixedCasePlugin'
            Invoke-TestPluginSetup -Root $pluginRoot -InitializeGit
            $result = Get-GitRepositoryInformation -PluginPath $pluginRoot.ToUpperInvariant()
            $result.Head | Should -Not -BeNullOrEmpty
        }

        It 'rejects a Git repository root specified through a junction' {
            $pluginRoot = Join-Path $TestDrive 'ActualGitPlugin'
            $junctionRoot = Join-Path $TestDrive 'JunctionGitPlugin'
            Invoke-TestPluginSetup -Root $pluginRoot -InitializeGit
            [void](New-Item -ItemType Junction -Path $junctionRoot -Target $pluginRoot)
            try {
                { Get-GitRepositoryInformation -PluginPath $junctionRoot } | Should -Throw
            }
            finally {
                if ([System.IO.Directory]::Exists($junctionRoot)) {
                    [System.IO.Directory]::Delete($junctionRoot)
                }
            }
        }
    }

    Describe 'Public CLI contract' {
        It 'exports only Invoke-FabPluginRelease with the allowed parameter surface' {
            $module = Get-Module FabPluginReleaseTools
            @($module.ExportedFunctions.Keys) | Should -BeExactly @('Invoke-FabPluginRelease')
            $command = Get-Command Invoke-FabPluginRelease
            foreach ($requiredParameter in @('PluginPath', 'EngineVersion')) {
                $command.Parameters.Keys | Should -Contain $requiredParameter
                $parameterAttribute = @($command.Parameters[$requiredParameter].Attributes |
                        Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })[0]
                $parameterAttribute.Mandatory | Should -BeTrue
            }
            foreach ($forbiddenParameter in @('SkipBuild', 'SkipValidation', 'Force', 'IgnoreErrors', 'IgnoreWarnings')) {
                $command.Parameters.Keys | Should -Not -Contain $forbiddenParameter
            }
        }

        It 'rejects an OutputDirectory inside the plugin without creating it' {
            $pluginRoot = Join-Path $TestDrive "UnsafeOutputPlugin-$([guid]::NewGuid())"
            Invoke-TestPluginSetup -Root $pluginRoot
            $unsafeOutput = Join-Path $pluginRoot 'artifacts'
            { Invoke-FabPluginRelease -PluginPath $pluginRoot -EngineVersion '5.8' `
                    -OutputDirectory $unsafeOutput } | Should -Throw
            $unsafeOutput | Should -Not -Exist
            $fallback = Join-Path (Get-Module FabPluginReleaseTools).ModuleBase `
                "artifacts\$([System.IO.Path]::GetFileName($pluginRoot))"
            if ([System.IO.Directory]::Exists($fallback)) {
                [System.IO.Directory]::Delete($fallback, $true)
            }
        }
    }

    Describe 'Allowlist parent reparse-point safety' {
        It 'rejects includeFiles below a junction before copying a file' {
            $pluginRoot = Join-Path $TestDrive 'FileJunctionPlugin'
            $externalRoot = Join-Path $TestDrive 'ExternalFiles'
            $junctionRoot = Join-Path $pluginRoot 'Linked'
            $destination = Join-Path $TestDrive 'FileJunctionDestination'
            [System.IO.Directory]::CreateDirectory($pluginRoot) | Out-Null
            [System.IO.Directory]::CreateDirectory($externalRoot) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $externalRoot 'secret.txt'), 'outside')
            [void](New-Item -ItemType Junction -Path $junctionRoot -Target $externalRoot)
            $configuration = [pscustomobject]@{
                includeDirectories = @()
                includeFiles       = @('Linked/secret.txt')
            }
            try {
                { Copy-FabPluginAllowList -PluginPath $pluginRoot -DestinationRoot $destination `
                        -Configuration $configuration } | Should -Throw
                @(Get-ChildItem -LiteralPath $destination -File -Recurse -ErrorAction SilentlyContinue).Count |
                    Should -Be 0
            }
            finally {
                if ([System.IO.Directory]::Exists($junctionRoot)) {
                    [System.IO.Directory]::Delete($junctionRoot)
                }
            }
        }

        It 'rejects includeDirectories below a parent junction' {
            $pluginRoot = Join-Path $TestDrive 'DirectoryJunctionPlugin'
            $externalRoot = Join-Path $TestDrive 'ExternalDirectories'
            $externalNested = Join-Path $externalRoot 'Nested'
            $junctionRoot = Join-Path $pluginRoot 'Linked'
            $destination = Join-Path $TestDrive 'DirectoryJunctionDestination'
            [System.IO.Directory]::CreateDirectory($pluginRoot) | Out-Null
            [System.IO.Directory]::CreateDirectory($externalNested) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $externalNested 'outside.txt'), 'outside')
            [void](New-Item -ItemType Junction -Path $junctionRoot -Target $externalRoot)
            $configuration = [pscustomobject]@{
                includeDirectories = @('Linked/Nested')
                includeFiles       = @()
            }
            try {
                { Copy-FabPluginAllowList -PluginPath $pluginRoot -DestinationRoot $destination `
                        -Configuration $configuration } | Should -Throw
                @(Get-ChildItem -LiteralPath $destination -File -Recurse -ErrorAction SilentlyContinue).Count |
                    Should -Be 0
            }
            finally {
                if ([System.IO.Directory]::Exists($junctionRoot)) {
                    [System.IO.Directory]::Delete($junctionRoot)
                }
            }
        }
    }

    Describe 'Descriptor JSON array typing' {
        It 'rejects source Modules encoded as an object' {
            $configuration = Get-TestConfigurationObject
            $descriptorObject = Get-TestDescriptorObject
            $descriptorObject.Modules = $descriptorObject.Modules[0]
            $descriptor = $descriptorObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            { Assert-SourcePluginDescriptor -Descriptor $descriptor -Configuration $configuration } |
                Should -Throw
        }

        It 'rejects source PlatformAllowList encoded as a string' {
            $configuration = Get-TestConfigurationObject
            $descriptorObject = Get-TestDescriptorObject
            $descriptorObject.Modules[0].PlatformAllowList = 'Win64'
            $descriptor = $descriptorObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            { Assert-SourcePluginDescriptor -Descriptor $descriptor -Configuration $configuration } |
                Should -Throw
        }

        It 'rejects source Plugins encoded as an object' {
            $configuration = Get-TestConfigurationObject
            $configuration.enabledPluginDependencies = @('ProceduralMeshComponent')
            $descriptorObject = Get-TestDescriptorObject
            $descriptorObject.Plugins = [ordered]@{
                Name = 'ProceduralMeshComponent'; Enabled = $true
            }
            $descriptor = $descriptorObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            { Assert-SourcePluginDescriptor -Descriptor $descriptor -Configuration $configuration } |
                Should -Throw
        }

        It 'rejects source SupportedTargetPlatforms encoded as a string' {
            $configuration = Get-TestConfigurationObject
            $descriptorObject = Get-TestDescriptorObject
            $descriptorObject.SupportedTargetPlatforms = 'Win64'
            $descriptor = $descriptorObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            { Assert-SourcePluginDescriptor -Descriptor $descriptor -Configuration $configuration } |
                Should -Throw
        }

        It 'rejects sales descriptor scalar substitution for <Property>' -ForEach @(
            @{ Property = 'Modules' },
            @{ Property = 'SupportedTargetPlatforms' },
            @{ Property = 'PlatformAllowList' },
            @{ Property = 'Plugins' }) {
            $configurationObject = Get-TestConfigurationObject
            $dependencies = @()
            if ($Property -eq 'Plugins') {
                $dependencies = @('ProceduralMeshComponent')
                $configurationObject.enabledPluginDependencies = $dependencies
            }
            $configuration = Import-TestConfiguration -Directory `
                (Join-Path $TestDrive "SalesArray-$Property") -Configuration $configurationObject
            $source = Get-TestDescriptorObject -Dependencies $dependencies
            $destination = Join-Path $TestDrive "SalesArray-$Property\TestPlugin.uplugin"
            $sales = ConvertTo-SalesPluginDescriptor `
                -SourceDescriptor ($source | ConvertTo-Json -Depth 30 | ConvertFrom-Json) `
                -Configuration $configuration -EngineVersion '5.8' -DestinationPath $destination
            switch ($Property) {
                'Modules' { $sales.Modules = $sales.Modules[0] }
                'SupportedTargetPlatforms' { $sales.SupportedTargetPlatforms = 'Win64' }
                'PlatformAllowList' { $sales.Modules[0].PlatformAllowList = 'Win64' }
                'Plugins' { $sales.Plugins = $sales.Plugins[0] }
            }
            $descriptor = $sales | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            { Assert-SalesPluginDescriptor -Descriptor $descriptor -Configuration $configuration `
                    -EngineVersion '5.8' } | Should -Throw
        }
    }

    Describe 'Sales descriptor normalization' {
        BeforeEach {
            Set-Variable -Name configuration -Value (Import-TestConfiguration -Directory $TestDrive)
            Set-Variable -Name descriptor -Value ((Get-TestDescriptorObject) | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
            Set-Variable -Name destination -Value (Join-Path $TestDrive 'TestPlugin.uplugin')
        }

        It 'normalizes all sales metadata and module policy' {
            $result = ConvertTo-SalesPluginDescriptor -SourceDescriptor $descriptor `
                -Configuration $configuration -EngineVersion '5.8' -DestinationPath $destination
            $result.EngineVersion | Should -BeExactly '5.8.0'
            $result.Installed | Should -BeTrue
            @($result.SupportedTargetPlatforms) | Should -BeExactly @('Win64')
            @($result.Modules).Count | Should -Be 1
            $result.Modules[0].Name | Should -BeExactly 'TestPlugin'
            @($result.Modules[0].PlatformAllowList) | Should -BeExactly @('Win64')
        }

        It 'generates FabURL and removes MarketplaceURL' {
            $result = ConvertTo-SalesPluginDescriptor -SourceDescriptor $descriptor `
                -Configuration $configuration -EngineVersion '5.8' -DestinationPath $destination
            $result.FabURL | Should -BeExactly 'com.epicgames.launcher://ue/Fab/product/19cb2daa-b018-46ae-b28c-7bfe21075c4a'
            $result.PSObject.Properties.Name | Should -Not -Contain 'MarketplaceURL'
        }

        It 'removes FabURL when listingId is null' {
            $configuration.listingId = $null
            Set-JsonObjectProperty -Object $descriptor -Name FabURL -Value 'legacy'
            $result = ConvertTo-SalesPluginDescriptor -SourceDescriptor $descriptor `
                -Configuration $configuration -EngineVersion '5.8' -DestinationPath $destination
            $result.PSObject.Properties.Name | Should -Not -Contain 'FabURL'
        }

        It 'writes UTF-8 without BOM' {
            [void](ConvertTo-SalesPluginDescriptor -SourceDescriptor $descriptor `
                    -Configuration $configuration -EngineVersion '5.8' -DestinationPath $destination)
            $bytes = [System.IO.File]::ReadAllBytes($destination)
            @($bytes[0..2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        }

        It 'requires enabled plugin dependencies to match exactly' {
            $configuration.enabledPluginDependencies = @('ProceduralMeshComponent')
            { Assert-SourcePluginDescriptor -Descriptor $descriptor -Configuration $configuration } |
                Should -Throw
        }
    }

    Describe 'Copyright validation' {
        BeforeEach {
            Set-Variable -Name root -Value (Join-Path $TestDrive "Plugin-$([guid]::NewGuid())")
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Source\Main')) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Source\ThirdParty\Vendor')) | Out-Null
            Set-Variable -Name notice -Value '// Copyright (c) 2026 metyatech. All rights reserved.'
        }

        It 'accepts the notice after blank lines' {
            [System.IO.File]::WriteAllText((Join-Path $root 'Source\Main\Good.cpp'), "`n`n$notice`n")
            { Test-SourceCopyright -PluginPath $root -ExpectedNotice $notice } | Should -Not -Throw
        }

        It 'rejects missing or mismatched publisher notice' {
            [System.IO.File]::WriteAllText((Join-Path $root 'Source\Main\Bad.h'), "// someone else`n")
            { Test-SourceCopyright -PluginPath $root -ExpectedNotice $notice } | Should -Throw
        }

        It 'checks Build.cs including test and ThirdParty modules' {
            [System.IO.File]::WriteAllText((Join-Path $root 'Source\ThirdParty\Vendor\Vendor.Build.cs'), "// wrong`n")
            { Test-SourceCopyright -PluginPath $root -ExpectedNotice $notice } | Should -Throw
        }

        It 'excludes ThirdParty C++ sources' {
            [System.IO.File]::WriteAllText((Join-Path $root 'Source\ThirdParty\Vendor\vendor.cpp'), "// vendor`n")
            { Test-SourceCopyright -PluginPath $root -ExpectedNotice $notice } | Should -Not -Throw
        }
    }

    Describe 'Unreal Category scanner' {
        BeforeEach {
            Set-Variable -Name root -Value (Join-Path $TestDrive "Plugin-$([guid]::NewGuid())")
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Source\Main')) | Out-Null
            Set-Variable -Name header -Value (Join-Path $root 'Source\Main\Api.h')
        }

        It 'accepts one-line UFUNCTION and UPROPERTY categories' {
            [System.IO.File]::WriteAllText($header, @'
UFUNCTION(BlueprintCallable, Category="Tools") void Run();
UPROPERTY(EditAnywhere, Category="Tools") int32 Count;
'@)
            { Test-UnrealCategorySpecifier -PluginPath $root } | Should -Not -Throw
        }

        It 'accepts multiline nested meta and commas inside strings' {
            [System.IO.File]::WriteAllText($header, @'
UFUNCTION(
    BlueprintPure,
    meta=(DisplayName="A, B", ClampMin="0"),
    Category = "Tools")
int32 GetValue() const;
'@)
            { Test-UnrealCategorySpecifier -PluginPath $root } | Should -Not -Throw
        }

        It 'ignores fake macros in comments and strings' {
            [System.IO.File]::WriteAllText($header, @'
// UFUNCTION(BlueprintCallable)
const char* Text = "UPROPERTY(EditAnywhere)";
'@)
            { Test-UnrealCategorySpecifier -PluginPath $root } | Should -Not -Throw
        }

        It 'rejects UFUNCTION with a missing direct Category and reports line' {
            [System.IO.File]::WriteAllText($header, "`nUFUNCTION(BlueprintCallable)`nvoid Run();`n")
            { Test-UnrealCategorySpecifier -PluginPath $root } |
                Should -Throw -ExpectedMessage '*UFUNCTION*Source/Main/Api.h:2*BlueprintCallable*'
        }

        It 'rejects UPROPERTY when Category exists only under meta' {
            [System.IO.File]::WriteAllText($header, 'UPROPERTY(EditAnywhere, meta=(Category="Fake")) int32 Count;')
            { Test-UnrealCategorySpecifier -PluginPath $root } |
                Should -Throw -ExpectedMessage '*UPROPERTY*EditAnywhere*'
        }
    }

    Describe 'Content and FilterPlugin validation' {
        BeforeEach {
            Set-Variable -Name root -Value (Join-Path $TestDrive "Package-$([guid]::NewGuid())")
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Config')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'README.md'), 'readme')
            [System.IO.File]::WriteAllText((Join-Path $root 'LICENSE'), 'license')
            Set-Variable -Name configuration -Value (Import-TestConfiguration -Directory "$root-config")
            [System.IO.File]::WriteAllText(
                (Join-Path $root 'Config\FilterPlugin.ini'),
                "[FilterPlugin]`n/README.md`n/LICENSE`n")
        }

        It 'accepts the valid pack-folder layout' {
            $configuration.content = [pscustomobject]@{ mode = 'pack'; packFolder = 'TestPlugin' }
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Content\TestPlugin')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'Content\TestPlugin\Asset.uasset'), 'asset')
            { Assert-ContentLayout -PluginRoot $root -Configuration $configuration } | Should -Not -Throw
        }

        It 'rejects a mismatched pack folder, a top-level file, or multiple folders' -ForEach @(
            @{ Variant = 'Mismatch' },
            @{ Variant = 'TopFile' },
            @{ Variant = 'Multiple' }) {
            $configuration.content = [pscustomobject]@{ mode = 'pack'; packFolder = 'TestPlugin' }
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Content\Wrong')) | Out-Null
            if ($Variant -eq 'TopFile') {
                [System.IO.File]::WriteAllText((Join-Path $root 'Content\Loose.uasset'), 'asset')
            }
            elseif ($Variant -eq 'Multiple') {
                [System.IO.Directory]::CreateDirectory((Join-Path $root 'Content\Other')) | Out-Null
            }
            { Assert-ContentLayout -PluginRoot $root -Configuration $configuration } | Should -Throw
        }

        It 'accepts 140 content-relative characters and rejects 141' {
            $configuration.content = [pscustomobject]@{ mode = 'pack'; packFolder = 'TestPlugin' }
            $packRoot = Join-Path $root 'Content\TestPlugin'
            [System.IO.Directory]::CreateDirectory($packRoot) | Out-Null
            $extension = '.uasset'
            $baseLength = 140 - 'TestPlugin/'.Length - $extension.Length
            $validName = ('A' * $baseLength) + $extension
            [System.IO.File]::WriteAllText((Join-Path $packRoot $validName), 'asset')
            { Assert-ContentLayout -PluginRoot $root -Configuration $configuration } | Should -Not -Throw
            [System.IO.File]::Delete((Join-Path $packRoot $validName))
            $invalidName = ('A' * ($baseLength + 1)) + $extension
            [System.IO.File]::WriteAllText((Join-Path $packRoot $invalidName), 'asset')
            { Assert-ContentLayout -PluginRoot $root -Configuration $configuration } | Should -Throw
        }

        It 'rejects spaces and non-ASCII content names' -ForEach @(
            @{ Name = 'Bad Name.uasset' },
            @{ Name = ([string][char]0x65E5 + [char]0x672C + '.uasset') }) {
            $configuration.content = [pscustomobject]@{ mode = 'pack'; packFolder = 'TestPlugin' }
            $packRoot = Join-Path $root 'Content\TestPlugin'
            [System.IO.Directory]::CreateDirectory($packRoot) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $packRoot $Name), 'asset')
            { Assert-ContentLayout -PluginRoot $root -Configuration $configuration } | Should -Throw
        }

        It 'rejects any Content in none mode' {
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Content')) | Out-Null
            { Assert-ContentLayout -PluginRoot $root -Configuration $configuration } | Should -Throw
        }

        It 'accepts exact file and directory FilterPlugin forms' {
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'Docs')) | Out-Null
            $configuration.customDistributionPaths = @('README.md', 'LICENSE', 'Docs')
            [System.IO.File]::WriteAllText(
                (Join-Path $root 'Config\FilterPlugin.ini'),
                "[FilterPlugin]`n/README.md`n/LICENSE`n/Docs/...`n")
            { Assert-FilterPluginConfiguration -PluginRoot $root -Configuration $configuration } |
                Should -Not -Throw
        }

        It 'rejects missing, extra, duplicate, and case-mismatched FilterPlugin entries' -ForEach @(
            @{ Text = "[FilterPlugin]`n/README.md`n" },
            @{ Text = "[FilterPlugin]`n/README.md`n/LICENSE`n/Extra`n" },
            @{ Text = "[FilterPlugin]`n/README.md`n/README.md`n/LICENSE`n" },
            @{ Text = "[FilterPlugin]`n/readme.md`n/LICENSE`n" }) {
            [System.IO.File]::WriteAllText((Join-Path $root 'Config\FilterPlugin.ini'), $Text)
            { Assert-FilterPluginConfiguration -PluginRoot $root -Configuration $configuration } |
                Should -Throw
        }

        It 'rejects a missing custom path target' {
            $configuration.customDistributionPaths = @('README.md', 'LICENSE', 'MISSING.md')
            { Assert-FilterPluginConfiguration -PluginRoot $root -Configuration $configuration } |
                Should -Throw
        }
    }

    Describe 'Package and license validation' {
        BeforeEach {
            Set-Variable -Name sourceRoot -Value (Join-Path $TestDrive "$([guid]::NewGuid())\SourcePlugin")
            Invoke-TestPluginSetup -Root $sourceRoot
            Set-Variable -Name configuration -Value (Import-FabPluginReleaseConfiguration `
                -ConfigPath (Join-Path $sourceRoot 'FabPluginRelease.json') -EngineVersion '5.8'
            )
            Set-Variable -Name packageRoot -Value (Join-Path (Split-Path $sourceRoot) 'Staged\TestPlugin')
            Copy-FabPluginAllowList -PluginPath $sourceRoot -DestinationRoot $packageRoot -Configuration $configuration
            Set-Variable -Name sourceDescriptor -Value (Read-PluginDescriptor `
                -DescriptorPath (Join-Path $sourceRoot 'TestPlugin.uplugin'))
            [void](ConvertTo-SalesPluginDescriptor -SourceDescriptor $sourceDescriptor `
                    -Configuration $configuration -EngineVersion '5.8' `
                    -DestinationPath (Join-Path $packageRoot 'TestPlugin.uplugin'))
        }

        It 'accepts the valid staged package' {
            { Assert-FabPackage -PluginRoot $packageRoot -Configuration $configuration -EngineVersion '5.8' } |
                Should -Not -Throw
        }

        It 'rejects a missing required file' {
            [System.IO.File]::Delete((Join-Path $packageRoot 'LICENSE'))
            { Assert-RequiredPackageFile -PluginRoot $packageRoot -Configuration $configuration } |
                Should -Throw
        }

        It 'rejects built-in and configured forbidden files' -ForEach @(
            @{ Relative = 'Tests/Fixture.txt' },
            @{ Relative = 'Forbidden/Fixture.txt' },
            @{ Relative = 'Debug.pdb' },
            @{ Relative = 'Nested.zip' }) {
            $path = Join-Path $packageRoot $Relative
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path)) | Out-Null
            [System.IO.File]::WriteAllText($path, 'bad')
            { Assert-NoForbiddenPackageFile -PluginRoot $packageRoot -Configuration $configuration } |
                Should -Throw
        }

        It 'accepts 170 ZIP-path characters and rejects 171' {
            $prefixLength = 'TestPlugin/'.Length
            $validRelative = ('A' * (170 - $prefixLength - '.txt'.Length)) + '.txt'
            [System.IO.File]::WriteAllText((Join-Path $packageRoot $validRelative), 'ok')
            { Assert-NoForbiddenPackageFile -PluginRoot $packageRoot -Configuration $configuration } |
                Should -Not -Throw
            [System.IO.File]::Delete((Join-Path $packageRoot $validRelative))
            $invalidRelative = ('A' * (171 - $prefixLength - '.txt'.Length)) + '.txt'
            [System.IO.File]::WriteAllText((Join-Path $packageRoot $invalidRelative), 'bad')
            { Assert-NoForbiddenPackageFile -PluginRoot $packageRoot -Configuration $configuration } |
                Should -Throw
        }

        It 'tests the 15 GiB boundary without allocating a huge file' {
            Get-TotalFileSize -Lengths @(10L, 5L) -MaximumBytes 15L | Should -Be 15L
            { Get-TotalFileSize -Lengths @(10L, 6L) -MaximumBytes 15L } | Should -Throw
        }

        It 'rejects a reparse-point directory' {
            $target = Join-Path $TestDrive 'Target'
            $junction = Join-Path $packageRoot 'Linked'
            [System.IO.Directory]::CreateDirectory($target) | Out-Null
            [void](New-Item -ItemType Junction -Path $junction -Target $target)
            { Get-SafeTreeFile -Root $packageRoot } | Should -Throw
        }

        It 'accepts an exact third-party license allowlist' {
            $licenseRoot = Join-Path $packageRoot 'Source\ThirdParty\Vendor\LICENSES'
            [System.IO.Directory]::CreateDirectory($licenseRoot) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $licenseRoot 'LICENSE.txt'), 'license')
            $configuration.thirdPartyLicenseSets = @(
                [pscustomobject]@{ root = 'Source/ThirdParty/Vendor/LICENSES'; files = @('LICENSE.txt') })
            { Assert-ThirdPartyLicenseSet -PluginRoot $packageRoot -Configuration $configuration } |
                Should -Not -Throw
        }

        It 'rejects missing, extra, case-mismatched, and empty licenses' -ForEach @(
            @{ Variant = 'Missing' },
            @{ Variant = 'Extra' },
            @{ Variant = 'Case' },
            @{ Variant = 'Empty' }) {
            $licenseRoot = Join-Path $packageRoot 'Source\ThirdParty\Vendor\LICENSES'
            [System.IO.Directory]::CreateDirectory($licenseRoot) | Out-Null
            $expected = 'LICENSE.txt'
            if ($Variant -ne 'Missing') {
                $actualName = if ($Variant -eq 'Case') { 'license.txt' } else { 'LICENSE.txt' }
                $contents = if ($Variant -eq 'Empty') { '' } else { 'license' }
                [System.IO.File]::WriteAllText((Join-Path $licenseRoot $actualName), $contents)
            }
            if ($Variant -eq 'Extra') {
                [System.IO.File]::WriteAllText((Join-Path $licenseRoot 'EXTRA.txt'), 'extra')
            }
            $configuration.thirdPartyLicenseSets = @(
                [pscustomobject]@{ root = 'Source/ThirdParty/Vendor/LICENSES'; files = @($expected) })
            { Assert-ThirdPartyLicenseSet -PluginRoot $packageRoot -Configuration $configuration } |
                Should -Throw
        }
    }

    Describe 'Session deletion safety' {
        It 'removes a session child and rejects outside or root deletion' {
            $session = Join-Path $TestDrive 'Session'
            $child = Join-Path $session 'child'
            $outside = Join-Path $TestDrive 'Outside'
            [System.IO.Directory]::CreateDirectory($child) | Out-Null
            [System.IO.Directory]::CreateDirectory($outside) | Out-Null
            Remove-SafeDirectory -Path $child -SessionRoot $session -Confirm:$false
            $child | Should -Not -Exist
            { Remove-SafeDirectory -Path $outside -SessionRoot $session -Confirm:$false } | Should -Throw
            { Remove-SafeDirectory -Path $session -SessionRoot $session -Confirm:$false } | Should -Throw
        }
    }

    Describe 'ZIP safety and determinism' {
        BeforeEach {
            Set-Variable -Name pluginRoot -Value (Join-Path $TestDrive "$([guid]::NewGuid())\TestPlugin")
            [System.IO.Directory]::CreateDirectory($pluginRoot) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $pluginRoot 'A.txt'), 'alpha')
            [System.IO.File]::WriteAllText((Join-Path $pluginRoot 'B.txt'), 'beta')
        }

        It 'creates byte-identical ZIPs with ordinal order and fixed timestamps' {
            $first = Join-Path $TestDrive 'first.zip'
            $second = Join-Path $TestDrive 'second.zip'
            New-DeterministicFabZip -PluginRoot $pluginRoot -PluginName 'TestPlugin' -ZipPath $first -Confirm:$false
            New-DeterministicFabZip -PluginRoot $pluginRoot -PluginName 'TestPlugin' -ZipPath $second -Confirm:$false
            (Get-FileHash $first -Algorithm SHA256).Hash | Should -BeExactly (Get-FileHash $second -Algorithm SHA256).Hash
            $archive = [System.IO.Compression.ZipFile]::OpenRead($first)
            try {
                @($archive.Entries.FullName) | Should -BeExactly @('TestPlugin/A.txt', 'TestPlugin/B.txt')
                foreach ($entry in $archive.Entries) {
                    $entry.LastWriteTime.DateTime | Should -Be ([datetime]'1980-01-01T00:00:00')
                }
            }
            finally { $archive.Dispose() }
        }

        It 'rejects zip slip, absolute, backslash, and case-colliding entries' -ForEach @(
            @{ Entries = @('TestPlugin/../evil.txt') },
            @{ Entries = @('/absolute.txt') },
            @{ Entries = @('TestPlugin\bad.txt') },
            @{ Entries = @('TestPlugin/A.txt', 'TestPlugin/a.txt') },
            @{ Entries = @('TestPlugin/Folder/A.txt', 'TestPlugin/folder/B.txt') }) {
            $zipPath = Join-Path $TestDrive "$([guid]::NewGuid()).zip"
            $stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
            $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($entryName in $Entries) {
                    $entry = $archive.CreateEntry($entryName)
                    $writer = [System.IO.StreamWriter]::new($entry.Open())
                    try { $writer.Write('x') } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose(); $stream.Dispose() }
            { Expand-FabZipSafely -ZipPath $zipPath -DestinationRoot (Join-Path $TestDrive ([guid]::NewGuid())) } |
                Should -Throw
        }

        It 'matches staged and extracted manifests and detects a changed extraction' {
            $zipPath = Join-Path $TestDrive 'manifest.zip'
            $extracted = Join-Path $TestDrive 'Extracted'
            New-DeterministicFabZip -PluginRoot $pluginRoot -PluginName 'TestPlugin' -ZipPath $zipPath -Confirm:$false
            Expand-FabZipSafely -ZipPath $zipPath -DestinationRoot $extracted
            $expected = @(Get-FabFileManifest -PluginRoot $pluginRoot)
            $actualRoot = Join-Path $extracted 'TestPlugin'
            $actual = @(Get-FabFileManifest -PluginRoot $actualRoot)
            { Assert-FabManifestsEqual -Expected $expected -Actual $actual } | Should -Not -Throw
            [System.IO.File]::AppendAllText((Join-Path $actualRoot 'A.txt'), 'changed')
            $changed = @(Get-FabFileManifest -PluginRoot $actualRoot)
            { Assert-FabManifestsEqual -Expected $expected -Actual $changed } | Should -Throw
        }

        It 'rejects a forbidden empty Tests directory during direct ZIP inspection' {
            $sourceRoot = Join-Path $TestDrive 'DirectTestsSource'
            $packageRoot = Join-Path $TestDrive 'DirectTestsPackage'
            $zipPath = Join-Path $TestDrive 'DirectTests.zip'
            $configuration = New-TestInspectableZip -SourceRoot $sourceRoot `
                -PackageRoot $packageRoot -ZipPath $zipPath
            $archive = [System.IO.Compression.ZipFile]::Open(
                $zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
            try { [void]$archive.CreateEntry('TestPlugin/Tests/') } finally { $archive.Dispose() }
            { Assert-FabZipDirectly -ZipPath $zipPath -Configuration $configuration `
                    -EngineVersion '5.8' } | Should -Throw
        }

        It 'rejects a 171-character empty directory during direct ZIP inspection' {
            $sourceRoot = Join-Path $TestDrive 'DirectLongSource'
            $packageRoot = Join-Path $TestDrive 'DirectLongPackage'
            $zipPath = Join-Path $TestDrive 'DirectLong.zip'
            $configuration = New-TestInspectableZip -SourceRoot $sourceRoot `
                -PackageRoot $packageRoot -ZipPath $zipPath
            $prefix = 'TestPlugin/'
            $entryName = "$prefix$('A' * (171 - $prefix.Length - 1))/"
            $archive = [System.IO.Compression.ZipFile]::Open(
                $zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
            try { [void]$archive.CreateEntry($entryName) } finally { $archive.Dispose() }
            { Assert-FabZipDirectly -ZipPath $zipPath -Configuration $configuration `
                    -EngineVersion '5.8' } | Should -Throw
        }

        It 'accepts a 170-character allowed empty directory during direct ZIP inspection' {
            $sourceRoot = Join-Path $TestDrive 'DirectBoundarySource'
            $packageRoot = Join-Path $TestDrive 'DirectBoundaryPackage'
            $zipPath = Join-Path $TestDrive 'DirectBoundary.zip'
            $configuration = New-TestInspectableZip -SourceRoot $sourceRoot `
                -PackageRoot $packageRoot -ZipPath $zipPath
            $prefix = 'TestPlugin/'
            $entryName = "$prefix$('A' * (170 - $prefix.Length - 1))/"
            $archive = [System.IO.Compression.ZipFile]::Open(
                $zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
            try { [void]$archive.CreateEntry($entryName) } finally { $archive.Dispose() }
            { Assert-FabZipDirectly -ZipPath $zipPath -Configuration $configuration `
                    -EngineVersion '5.8' } | Should -Not -Throw
        }
    }

    Describe 'Engine root resolution' {
        It 'resolves an explicit engine root and an explicit parent directory' {
            $engineRoot = Join-Path $TestDrive 'Explicit\UE_5.8'
            Invoke-FakeEngineSetup -Root $engineRoot
            Resolve-FabEngineRoot -EngineVersion '5.8' -EngineRoot $engineRoot `
                -EnvironmentEngineRoot '' -ManifestDirectory (Join-Path $TestDrive 'None') `
                -DefaultEpicDirectory (Join-Path $TestDrive 'Default') |
                Should -BeExactly ([System.IO.Path]::GetFullPath($engineRoot))
            Resolve-FabEngineRoot -EngineVersion '5.8' -EngineRoot (Split-Path $engineRoot) `
                -EnvironmentEngineRoot '' -ManifestDirectory (Join-Path $TestDrive 'None') `
                -DefaultEpicDirectory (Join-Path $TestDrive 'Default') |
                Should -BeExactly ([System.IO.Path]::GetFullPath($engineRoot))
        }

        It 'resolves the environment variable candidate' {
            $engineRoot = Join-Path $TestDrive 'Environment\UE_5.8'
            Invoke-FakeEngineSetup -Root $engineRoot
            Resolve-FabEngineRoot -EngineVersion '5.8' -EnvironmentEngineRoot (Split-Path $engineRoot) `
                -ManifestDirectory (Join-Path $TestDrive 'None') `
                -DefaultEpicDirectory (Join-Path $TestDrive 'Default') |
                Should -BeExactly ([System.IO.Path]::GetFullPath($engineRoot))
        }

        It 'resolves a matching Epic Launcher manifest' {
            $engineRoot = Join-Path $TestDrive 'ManifestEngine'
            $manifestDirectory = Join-Path $TestDrive 'Manifests'
            Invoke-FakeEngineSetup -Root $engineRoot
            [System.IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $manifestDirectory 'engine.item'),
                (@{ AppName = 'UE_5.8'; InstallLocation = $engineRoot } | ConvertTo-Json))
            Resolve-FabEngineRoot -EngineVersion '5.8' -EnvironmentEngineRoot '' `
                -ManifestDirectory $manifestDirectory -DefaultEpicDirectory (Join-Path $TestDrive 'Default') |
                Should -BeExactly ([System.IO.Path]::GetFullPath($engineRoot))
        }

        It 'rejects multiple distinct manifest candidates' {
            $manifestDirectory = Join-Path $TestDrive 'Manifests'
            [System.IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
            foreach ($number in 1..2) {
                $engineRoot = Join-Path $TestDrive "Engine$number"
                Invoke-FakeEngineSetup -Root $engineRoot
                [System.IO.File]::WriteAllText(
                    (Join-Path $manifestDirectory "$number.item"),
                    (@{ AppName = 'UE_5.8'; InstallLocation = $engineRoot } | ConvertTo-Json))
            }
            { Resolve-FabEngineRoot -EngineVersion '5.8' -EnvironmentEngineRoot '' `
                    -ManifestDirectory $manifestDirectory -DefaultEpicDirectory (Join-Path $TestDrive 'Default') } |
                Should -Throw -ExpectedMessage '*Multiple*EngineRoot*'
        }

        It 'rejects a mismatched Build.version' {
            $engineRoot = Join-Path $TestDrive 'WrongVersion'
            Invoke-FakeEngineSetup -Root $engineRoot
            [System.IO.File]::WriteAllText(
                (Join-Path $engineRoot 'Engine\Build\Build.version'),
                '{"MajorVersion":5,"MinorVersion":7}')
            { Resolve-FabEngineRoot -EngineVersion '5.8' -EngineRoot $engineRoot } | Should -Throw
        }
    }

    Describe 'Fake UAT BuildPlugin boundary' {
        BeforeEach {
            Set-Variable -Name sourceRoot -Value (Join-Path $TestDrive "$([guid]::NewGuid())\SourcePlugin")
            Invoke-TestPluginSetup -Root $sourceRoot
            Set-Variable -Name configuration -Value (Import-FabPluginReleaseConfiguration `
                -ConfigPath (Join-Path $sourceRoot 'FabPluginRelease.json') -EngineVersion '5.8'
            )
            Set-Variable -Name stagedRoot -Value (Join-Path (Split-Path $sourceRoot) 'Staged\TestPlugin')
            Copy-FabPluginAllowList -PluginPath $sourceRoot -DestinationRoot $stagedRoot -Configuration $configuration
            Set-Variable -Name sourceDescriptor -Value (Read-PluginDescriptor `
                -DescriptorPath (Join-Path $sourceRoot 'TestPlugin.uplugin'))
            [void](ConvertTo-SalesPluginDescriptor -SourceDescriptor $sourceDescriptor `
                    -Configuration $configuration -EngineVersion '5.8' `
                    -DestinationPath (Join-Path $stagedRoot 'TestPlugin.uplugin'))
            Set-Variable -Name logPath -Value (Join-Path $TestDrive 'uat.log')
            [System.IO.File]::WriteAllText($logPath, '')
        }

        It 'accepts successful fake BuildPlugin output' {
            $engineRoot = Join-Path $TestDrive 'EngineSuccess'
            Invoke-FakeEngineSetup -Root $engineRoot -Behavior Success
            $result = Invoke-UatBuildPlugin -EngineRoot $engineRoot -StagedPluginRoot $stagedRoot `
                -BuildInputPluginRoot (Join-Path $TestDrive 'BuildInput\TestPlugin') `
                -BuildOutputRoot (Join-Path $TestDrive 'BuildOutput') -Configuration $configuration `
                -EngineVersion '5.8' -LogPath $logPath -TimeoutSeconds 10
            $result.exitCode | Should -Be 0
            $result.timedOut | Should -BeFalse
        }

        It 'rejects nonzero exit, error log with zero exit, plugin warning, and timeout' -ForEach @(
            @{ Behavior = 'Failure'; Timeout = 10 },
            @{ Behavior = 'ErrorLog'; Timeout = 10 },
            @{ Behavior = 'Warning'; Timeout = 10 },
            @{ Behavior = 'Timeout'; Timeout = 1 }) {
            $engineRoot = Join-Path $TestDrive "Engine$Behavior"
            Invoke-FakeEngineSetup -Root $engineRoot -Behavior $Behavior
            { Invoke-UatBuildPlugin -EngineRoot $engineRoot -StagedPluginRoot $stagedRoot `
                    -BuildInputPluginRoot (Join-Path $TestDrive "Input$Behavior\TestPlugin") `
                    -BuildOutputRoot (Join-Path $TestDrive "Output$Behavior") -Configuration $configuration `
                    -EngineVersion '5.8' -LogPath $logPath -TimeoutSeconds $Timeout } |
                Should -Throw
        }

        It 'rejects missing descriptor, missing Win64 DLL, and EngineVersion mismatch' -ForEach @(
            @{ Behavior = 'MissingDescriptor' },
            @{ Behavior = 'MissingDll' },
            @{ Behavior = 'VersionMismatch' }) {
            $engineRoot = Join-Path $TestDrive "Engine$Behavior"
            Invoke-FakeEngineSetup -Root $engineRoot -Behavior $Behavior
            { Invoke-UatBuildPlugin -EngineRoot $engineRoot -StagedPluginRoot $stagedRoot `
                    -BuildInputPluginRoot (Join-Path $TestDrive "Input$Behavior\TestPlugin") `
                    -BuildOutputRoot (Join-Path $TestDrive "Output$Behavior") -Configuration $configuration `
                    -EngineVersion '5.8' -LogPath $logPath -TimeoutSeconds 10 } |
                Should -Throw
        }
    }

    Describe 'Separate-process release entry point' {
        BeforeAll {
            function Invoke-TestEntryPoint {
                param(
                    [Parameter(Mandatory)]
                    [string]$PluginRoot,

                    [Parameter(Mandatory)]
                    [string]$EngineRoot,

                    [Parameter(Mandatory)]
                    [string]$OutputRoot,

                    [string]$ScriptPath,

                    [string]$ModulePath
                )

                $entryPoint = if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
                    Join-Path (Get-Module FabPluginReleaseTools).ModuleBase 'Invoke-FabPluginRelease.ps1'
                }
                else {
                    $ScriptPath
                }
                $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = 'pwsh.exe'
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.Environment['NO_COLOR'] = '1'
                $startInfo.Environment['TERM'] = 'dumb'
                foreach ($argument in @(
                        '-NoProfile', '-File', $entryPoint,
                        '-PluginPath', $PluginRoot,
                        '-EngineVersion', '5.8',
                        '-EngineRoot', $EngineRoot,
                        '-OutputDirectory', $OutputRoot)) {
                    [void]$startInfo.ArgumentList.Add($argument)
                }
                if (-not [string]::IsNullOrWhiteSpace($ModulePath)) {
                    [void]$startInfo.ArgumentList.Add('-ModulePath')
                    [void]$startInfo.ArgumentList.Add($ModulePath)
                }
                $process = [System.Diagnostics.Process]::new()
                $process.StartInfo = $startInfo
                try {
                    [void]$process.Start()
                    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                    $stderrTask = $process.StandardError.ReadToEndAsync()
                    $process.WaitForExit()
                    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
                    return [pscustomobject]@{
                        ExitCode = $process.ExitCode
                        StdOut   = $stdoutTask.Result.TrimEnd("`r", "`n")
                        StdErr   = $stderrTask.Result.TrimEnd("`r", "`n")
                    }
                }
                finally { $process.Dispose() }
            }
        }

        It 'returns 0, ends in PASS, and emits ZIP, checksum, report, and log' {
            $pluginRoot = Join-Path $TestDrive 'SuccessPlugin'
            $engineRoot = Join-Path $TestDrive 'SuccessEngine'
            $outputRoot = Join-Path $TestDrive 'SuccessOutput'
            Invoke-TestPluginSetup -Root $pluginRoot -InitializeGit
            Invoke-FakeEngineSetup -Root $engineRoot -Behavior Success
            $result = Invoke-TestEntryPoint -PluginRoot $pluginRoot -EngineRoot $engineRoot -OutputRoot $outputRoot
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            @($result.StdOut -split "`r?`n")[-1] | Should -BeExactly 'FAB PLUGIN RELEASE: PASS'
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.zip').Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.sha256').Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.report.json').Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.log').Count | Should -Be 1
        }

        It 'does not expose a fixed test credential from the Git origin in report or log' {
            $pluginRoot = Join-Path $TestDrive 'SecretRemotePlugin'
            $engineRoot = Join-Path $TestDrive 'SecretRemoteEngine'
            $outputRoot = Join-Path $TestDrive 'SecretRemoteOutput'
            $testSecret = 'fixed-test-secret-value'
            Invoke-TestPluginSetup -Root $pluginRoot -InitializeGit
            [void](Invoke-NativeProcessCapture -FileName 'git.exe' -ArgumentList @(
                    '-C', $pluginRoot, 'remote', 'set-url', 'origin',
                    "https://x-access-token:${testSecret}@example.invalid/TestPlugin.git?token=query-secret#part"))
            Invoke-FakeEngineSetup -Root $engineRoot -Behavior Success
            $result = Invoke-TestEntryPoint -PluginRoot $pluginRoot -EngineRoot $engineRoot `
                -OutputRoot $outputRoot
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            $reportText = [System.IO.File]::ReadAllText(
                @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.report.json')[0].FullName)
            $logText = [System.IO.File]::ReadAllText(
                @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.log')[0].FullName)
            $reportText | Should -Not -Match ([regex]::Escape($testSecret))
            $reportText | Should -Not -Match 'query-secret|x-access-token|#part'
            $logText | Should -Not -Match ([regex]::Escape($testSecret))
            $logText | Should -Not -Match 'query-secret|x-access-token|#part'
        }

        It 'returns 1, ends in FAIL, removes ZIP/checksum, and retains report/log on BuildPlugin failure' {
            $pluginRoot = Join-Path $TestDrive 'FailurePlugin'
            $engineRoot = Join-Path $TestDrive 'FailureEngine'
            $outputRoot = Join-Path $TestDrive 'FailureOutput'
            Invoke-TestPluginSetup -Root $pluginRoot -InitializeGit
            Invoke-FakeEngineSetup -Root $engineRoot -Behavior Failure
            $result = Invoke-TestEntryPoint -PluginRoot $pluginRoot -EngineRoot $engineRoot -OutputRoot $outputRoot
            $result.ExitCode | Should -Be 1
            @($result.StdOut -split "`r?`n")[-1] | Should -BeExactly 'FAB PLUGIN RELEASE: FAIL'
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.zip').Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.sha256').Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.report.json').Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.log').Count | Should -Be 1
            $report = Get-Content -Raw (Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.report.json').FullName |
                ConvertFrom-Json
            $report.build.exitCode | Should -Be 7
            $report.build.timedOut | Should -BeFalse
        }

        It 'fails at direct ZIP reinspection in a separate process and retains only report/log' {
            $pluginRoot = Join-Path $TestDrive 'CorruptZipPlugin'
            $engineRoot = Join-Path $TestDrive 'CorruptZipEngine'
            $outputRoot = Join-Path $TestDrive 'CorruptZipOutput'
            $modulePath = Join-Path (Get-Module FabPluginReleaseTools).ModuleBase 'FabPluginReleaseTools.psd1'
            $harnessPath = Join-Path $TestDrive 'Invoke-CorruptZipTest.ps1'
            [System.IO.File]::WriteAllText($harnessPath, @'
# Copyright (c) 2026 metyatech. All rights reserved.
param(
    [string]$PluginPath,
    [string]$EngineVersion,
    [string]$EngineRoot,
    [string]$OutputDirectory,
    [string]$ModulePath
)
$exitCode = 1
try {
    Import-Module $ModulePath -Force
    $module = Get-Module FabPluginReleaseTools
    & $module {
        param($plugin, $version, $engine, $output)
        Invoke-FabPluginReleaseCore -PluginPath $plugin -EngineVersion $version `
            -EngineRoot $engine -OutputDirectory $output -AfterZipCreated {
                param($zipPath)
                $stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Open)
                try { $stream.SetLength($stream.Length - 32) } finally { $stream.Dispose() }
            }
    } $PluginPath $EngineVersion $EngineRoot $OutputDirectory
    $exitCode = 0
}
catch {
}
finally {
    if ($exitCode -eq 0) { Write-Output 'FAB PLUGIN RELEASE: PASS' }
    else { Write-Output 'FAB PLUGIN RELEASE: FAIL' }
}
exit $exitCode
'@)
            Invoke-TestPluginSetup -Root $pluginRoot -InitializeGit
            Invoke-FakeEngineSetup -Root $engineRoot -Behavior Success
            $result = Invoke-TestEntryPoint -PluginRoot $pluginRoot -EngineRoot $engineRoot `
                -OutputRoot $outputRoot -ScriptPath $harnessPath -ModulePath $modulePath
            $result.ExitCode | Should -Be 1
            @($result.StdOut -split "`r?`n")[-1] | Should -BeExactly 'FAB PLUGIN RELEASE: FAIL'
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.zip').Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.sha256').Count | Should -Be 0
            $reportFile = Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.report.json'
            @($reportFile).Count | Should -Be 1
            @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.log').Count | Should -Be 1
            $report = Get-Content -Raw $reportFile.FullName | ConvertFrom-Json
            @($report.gates)[-1].name | Should -BeLike '8.*'
            @($report.gates)[-1].status | Should -BeExactly 'FAIL'
        }
    }
}
