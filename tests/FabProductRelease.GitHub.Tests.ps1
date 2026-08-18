# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab product GitHub project-file publication boundary' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Invoke-FabProductRelease.ps1'
        . $scriptPath -PluginPath $PSScriptRoot

        function Get-PublishTestRelease {
            param(
                [Parameter(Mandatory)]
                [string]$EngineVersion,

                [Parameter(Mandatory)]
                [string]$Hash
            )

            return [pscustomobject]@{
                EngineVersion = $EngineVersion
                ZipPath       = "C:\verification\TestPlugin_1.0.0_UE${EngineVersion}_Win64.zip"
                Sha256        = $Hash
            }
        }

        function Get-PublishTestListing {
            return [pscustomobject]@{
                SourceRepositoryUrl = 'https://github.com/metyatech/TestPlugin'
            }
        }

        function Get-PublishTestConfiguration {
            return [pscustomobject]@{ pluginName = 'TestPlugin' }
        }
    }

    It 'rejects a missing gh CLI when publication is requested' {
        Mock -CommandName Get-FabProductGhPath -MockWith {
            throw 'gh CLI is required when -PublishProjectFiles is specified.'
        }
        {
            Assert-FabProductGitHubPublicationPrerequisite -PluginRoot $TestDrive `
                -SourceRepositoryUrl 'https://github.com/metyatech/TestPlugin'
        } | Should -Throw '*gh CLI is required*'
    }

    It 'rejects a non-GitHub source repository' {
        { Get-FabProductRepositoryKey -RepositoryUrl 'https://gitlab.com/metyatech/TestPlugin' } |
            Should -Throw '*github.com repository*'
    }

    It 'rejects a private GitHub repository' {
        Mock -CommandName Get-FabProductGhPath -MockWith { return 'gh.exe' }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'repo') {
                return '{"nameWithOwner":"metyatech/TestPlugin","isPrivate":true}'
            }
            return ''
        }
        Mock -CommandName Get-FabProductLocalRepositoryInfo -MockWith {
            return [pscustomobject]@{ Remote = 'https://github.com/metyatech/TestPlugin'; Branch = 'master'; Head = 'a' * 40 }
        }
        {
            Assert-FabProductGitHubPublicationPrerequisite -PluginRoot $TestDrive `
                -SourceRepositoryUrl 'https://github.com/metyatech/TestPlugin'
        } | Should -Throw '*must be public*'
    }

    It 'rejects a source repository that does not match the local origin' {
        Mock -CommandName Get-FabProductGhPath -MockWith { return 'gh.exe' }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith { return '' }
        Mock -CommandName Get-FabProductLocalRepositoryInfo -MockWith {
            return [pscustomobject]@{
                Remote = 'https://github.com/metyatech/OtherPlugin'
                Branch = 'master'
                Head   = 'a' * 40
            }
        }
        {
            Assert-FabProductGitHubPublicationPrerequisite -PluginRoot $TestDrive `
                -SourceRepositoryUrl 'https://github.com/metyatech/TestPlugin'
        } | Should -Throw '*does not match the local origin repository*'
    }

    It 'reuses an existing matching remote asset without uploading it again' {
        $hash = 'a' * 64
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash $hash
        $script:ReleaseInfoCallCount = 0
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return [pscustomobject]@{ RepositoryKey = 'metyatech/TestPlugin' }
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            $script:ReleaseInfoCallCount++
            $isDraft = $script:ReleaseInfoCallCount -eq 1
            return [pscustomobject]@{
                tagName = 'fab-v1.0.0'
                isDraft = $isDraft
                body    = "fab-plugin-release-tools`nrepository=metyatech/TestPlugin`npluginName=TestPlugin`nproductVersion=1.0.0`nengineVersions=5.8"
                assets  = @([pscustomobject]@{
                        name               = [System.IO.Path]::GetFileName($release.ZipPath)
                        digest             = "sha256:$hash"
                        browserDownloadUrl = 'https://github.com/metyatech/TestPlugin/releases/download/fab-v1.0.0/TestPlugin_1.0.0_UE5.8_Win64.zip'
                    })
            }
        }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            $script:GitHubCalls += @([string]::Join(' ', $Arguments))
            return ''
        }
        Mock -CommandName Test-FabProductPublicUrl -MockWith { return $true }
        $script:GitHubCalls = @()
        $links = Publish-FabProductProjectFile -PluginRoot $TestDrive `
            -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
            -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0'
        $links['5.8'] | Should -BeLike 'https://github.com/*/TestPlugin_1.0.0_UE5.8_Win64.zip'
        @($script:GitHubCalls | Where-Object { $_ -like '*release upload*' }) | Should -HaveCount 0
    }

    It 'rejects an existing conflicting remote asset' {
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return [pscustomobject]@{ RepositoryKey = 'metyatech/TestPlugin' }
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            return [pscustomobject]@{
                tagName = 'fab-v1.0.0'
                isDraft = $true
                body    = "fab-plugin-release-tools`nrepository=metyatech/TestPlugin`npluginName=TestPlugin`nproductVersion=1.0.0`nengineVersions=5.8"
                assets  = @([pscustomobject]@{
                        name               = [System.IO.Path]::GetFileName($release.ZipPath)
                        digest             = "sha256:$('b' * 64)"
                        browserDownloadUrl = 'https://example.invalid/file.zip'
                    })
            }
        }
        {
            Publish-FabProductProjectFile -PluginRoot $TestDrive `
                -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
                -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0'
        } | Should -Throw '*conflicting SHA-256*'
    }

    It 'resumes a partial draft by uploading only the missing asset' {
        $release58 = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        $release59 = Get-PublishTestRelease -EngineVersion '5.9' -Hash ('b' * 64)
        $script:ReleaseInfoCallCount = 0
        $script:GitHubCalls = @()
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return [pscustomobject]@{ RepositoryKey = 'metyatech/TestPlugin' }
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            $script:ReleaseInfoCallCount++
            $assets = @([pscustomobject]@{
                    name               = [System.IO.Path]::GetFileName($release58.ZipPath)
                    digest             = "sha256:$('a' * 64)"
                    browserDownloadUrl = 'https://example.invalid/58.zip'
                })
            if ($script:ReleaseInfoCallCount -ge 3) {
                $assets += [pscustomobject]@{
                    name               = [System.IO.Path]::GetFileName($release59.ZipPath)
                    digest             = "sha256:$('b' * 64)"
                    browserDownloadUrl = 'https://example.invalid/59.zip'
                }
            }
            return [pscustomobject]@{
                tagName = 'fab-v1.0.0'
                isDraft = $script:ReleaseInfoCallCount -lt 4
                body    = "fab-plugin-release-tools`nrepository=metyatech/TestPlugin`npluginName=TestPlugin`nproductVersion=1.0.0`nengineVersions=5.8,5.9"
                assets  = $assets
            }
        }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            $script:GitHubCalls += @([string]::Join(' ', $Arguments))
            return ''
        }
        Mock -CommandName Test-FabProductPublicUrl -MockWith { return $true }
        $links = Publish-FabProductProjectFile -PluginRoot $TestDrive `
            -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
            -Releases @($release58, $release59) -EngineVersions @('5.8', '5.9') -ProductVersion '1.0.0'
        @($script:GitHubCalls | Where-Object { $_ -like '*release upload*' }) | Should -HaveCount 1
        $links['5.9'] | Should -BeExactly 'https://example.invalid/59.zip'
    }

    It 'rejects a remote digest mismatch after publication' {
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        $script:ReleaseInfoCallCount = 0
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return [pscustomobject]@{ RepositoryKey = 'metyatech/TestPlugin' }
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            $script:ReleaseInfoCallCount++
            $digest = if ($script:ReleaseInfoCallCount -lt 3) { "sha256:$('a' * 64)" } else { "sha256:$('b' * 64)" }
            return [pscustomobject]@{
                tagName = 'fab-v1.0.0'
                isDraft = $script:ReleaseInfoCallCount -lt 3
                body    = "fab-plugin-release-tools`nrepository=metyatech/TestPlugin`npluginName=TestPlugin`nproductVersion=1.0.0`nengineVersions=5.8"
                assets  = @([pscustomobject]@{
                        name               = [System.IO.Path]::GetFileName($release.ZipPath)
                        digest             = $digest
                        browserDownloadUrl = 'https://example.invalid/file.zip'
                    })
            }
        }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith { return '' }
        {
            Publish-FabProductProjectFile -PluginRoot $TestDrive `
                -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
                -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0'
        } | Should -Throw '*digest verification failed*'
    }

    It 'rejects a missing or unreachable public browser download URL' -ForEach @(
        @{ Name = 'missing'; Url = $null },
        @{ Name = 'unreachable'; Url = 'https://example.invalid/file.zip' }) {
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return [pscustomobject]@{ RepositoryKey = 'metyatech/TestPlugin' }
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            return [pscustomobject]@{
                tagName = 'fab-v1.0.0'
                isDraft = $false
                body    = "fab-plugin-release-tools`nrepository=metyatech/TestPlugin`npluginName=TestPlugin`nproductVersion=1.0.0`nengineVersions=5.8"
                assets  = @([pscustomobject]@{
                        name               = [System.IO.Path]::GetFileName($release.ZipPath)
                        digest             = "sha256:$('a' * 64)"
                        browserDownloadUrl = $Url
                    })
            }
        }
        Mock -CommandName Test-FabProductPublicUrl -MockWith {
            param([switch]$ThrowOnFailure)
            if ($ThrowOnFailure) {
                throw 'Public Project File Link is not reachable without authentication.'
            }
            return $false
        }
        {
            Publish-FabProductProjectFile -PluginRoot $TestDrive `
                -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
                -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0'
        } | Should -Throw
    }
}
