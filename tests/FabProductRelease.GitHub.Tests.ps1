# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fab product GitHub project-file publication boundary' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Invoke-FabProductRelease.ps1'
        . $scriptPath -PluginPath $PSScriptRoot
        $script:PublishTestHead = 'a' * 40

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

        function Get-PublishTestPrerequisite {
            param(
                [string]$Head = $script:PublishTestHead
            )

            return [pscustomobject]@{
                RepositoryKey = 'metyatech/TestPlugin'
                Local         = [pscustomobject]@{ Head = $Head }
            }
        }

        function Get-PublishTestMarker {
            param(
                [Parameter(Mandatory)]
                [string[]]$EngineVersions,

                [string]$SourceCommit = $script:PublishTestHead
            )

            return Get-FabProductReleaseMarker -RepositoryKey 'metyatech/TestPlugin' `
                -PluginName 'TestPlugin' -ProductVersion '1.0.0' `
                -EngineVersions $EngineVersions -SourceCommit $SourceCommit
        }

        function Get-PublishTestReleaseInfo {
            param(
                [Parameter(Mandatory)]
                [string[]]$EngineVersions,

                [object[]]$Assets = @(),

                [bool]$IsDraft = $false,

                [string]$SourceCommit = $script:PublishTestHead,

                [string]$TargetCommitish = $script:PublishTestHead
            )

            return [pscustomobject]@{
                tagName         = 'fab-v1.0.0'
                isDraft         = $IsDraft
                targetCommitish = $TargetCommitish
                body            = Get-PublishTestMarker -EngineVersions $EngineVersions -SourceCommit $SourceCommit
                assets          = @($Assets)
            }
        }
    }

    BeforeEach {
        Mock -CommandName Get-FabProductReleaseTagCommit -MockWith {
            return $script:PublishTestHead
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
            return Get-PublishTestPrerequisite
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            $script:ReleaseInfoCallCount++
            $isDraft = $false
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') -IsDraft $isDraft -Assets @([pscustomobject]@{
                    name               = [System.IO.Path]::GetFileName($release.ZipPath)
                    digest             = "sha256:$hash"
                    browserDownloadUrl = 'https://github.com/metyatech/TestPlugin/releases/download/fab-v1.0.0/TestPlugin_1.0.0_UE5.8_Win64.zip'
                })
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

    It 'requests targetCommitish when reading release information' {
        $script:GitHubArguments = @()
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            $script:GitHubArguments = @($Arguments)
            return '{"tagName":"fab-v1.0.0","isDraft":true,"body":"","assets":[],"targetCommitish":"master"}'
        }
        $info = Get-FabProductReleaseInfo -RepositoryKey 'metyatech/TestPlugin' -Tag 'fab-v1.0.0'
        $info.targetCommitish | Should -BeExactly 'master'
        [string]::Join(',', $script:GitHubArguments) | Should -Match 'tagName,isDraft,body,assets,targetCommitish'
    }

    It 'generates a marker with the exact full source commit' {
        $head = 'c' * 40
        $marker = Get-PublishTestMarker -EngineVersions @('5.8') -SourceCommit $head
        $marker | Should -Match "(?m)^sourceCommit=$head$"
        $marker | Should -Not -Match '(?m)^sourceCommit=[0-9a-fA-F]{1,39}$'
    }

    It 'creates a new release with the exact validated HEAD target and marker' {
        $head = 'c' * 40
        $hash = 'a' * 64
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash $hash
        $script:ReleaseInfoCallCount = 0
        $script:GitHubCalls = @()
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return Get-PublishTestPrerequisite -Head $head
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            $script:ReleaseInfoCallCount++
            if ($script:ReleaseInfoCallCount -eq 1) {
                return $null
            }
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') `
                -Assets @([pscustomobject]@{
                    name               = [System.IO.Path]::GetFileName($release.ZipPath)
                    digest             = "sha256:$hash"
                    browserDownloadUrl = 'https://example.invalid/file.zip'
                }) -SourceCommit $head -TargetCommitish $head
        }
        Mock -CommandName Get-FabProductReleaseTagCommit -MockWith { return $head }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            $script:GitHubCalls += @([string]::Join(' ', $Arguments))
            return ''
        }
        Mock -CommandName Test-FabProductPublicUrl -MockWith { return $true }
        [void](Publish-FabProductProjectFile -PluginRoot $TestDrive `
            -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
            -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0')
        $createCall = @($script:GitHubCalls | Where-Object { $_ -like '*release create*' })
        $createCall | Should -HaveCount 1
        $createCall[0] | Should -Match "--target $head"
        $createCall[0] | Should -Match "sourceCommit=$head"
    }

    It 'rejects a release marker from another source commit before mutation' {
        $head = 'a' * 40
        $otherHead = 'b' * 40
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        $script:GitHubCalls = @()
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return Get-PublishTestPrerequisite -Head $head
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') `
                -Assets @() -SourceCommit $otherHead -TargetCommitish $head
        }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            $script:GitHubCalls += @([string]::Join(' ', $Arguments))
            return ''
        }
        {
            Publish-FabProductProjectFile -PluginRoot $TestDrive `
                -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
                -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0'
        } | Should -Throw '*ownership marker mismatch*'
        @($script:GitHubCalls | Where-Object { $_ -match 'release (create|upload|edit)' }) | Should -HaveCount 0
    }

    It 'rejects a release target that resolves to another source commit before mutation' {
        $head = 'a' * 40
        $otherHead = 'b' * 40
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        $script:GitHubCalls = @()
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return Get-PublishTestPrerequisite -Head $head
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') `
                -Assets @() -SourceCommit $head -TargetCommitish $otherHead
        }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            $script:GitHubCalls += @([string]::Join(' ', $Arguments))
            return ''
        }
        {
            Publish-FabProductProjectFile -PluginRoot $TestDrive `
                -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
                -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0'
        } | Should -Throw '*targetCommitish*not validated local HEAD*'
        @($script:GitHubCalls | Where-Object { $_ -match 'release (create|upload|edit)' }) | Should -HaveCount 0
    }

    It 'rejects a tag resolving to another source commit before mutation' {
        $head = 'a' * 40
        $otherHead = 'b' * 40
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        $script:GitHubCalls = @()
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return Get-PublishTestPrerequisite -Head $head
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') `
                -Assets @() -SourceCommit $head -TargetCommitish $head
        }
        Mock -CommandName Get-FabProductReleaseTagCommit -MockWith { return $otherHead }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            $script:GitHubCalls += @([string]::Join(' ', $Arguments))
            return ''
        }
        {
            Publish-FabProductProjectFile -PluginRoot $TestDrive `
                -Configuration (Get-PublishTestConfiguration) -Listing (Get-PublishTestListing) `
                -Releases @($release) -EngineVersions @('5.8') -ProductVersion '1.0.0'
        } | Should -Throw '*tag resolves to source commit*'
        @($script:GitHubCalls | Where-Object { $_ -match 'release (create|upload|edit)' }) | Should -HaveCount 0
    }

    It 'resolves a branch/ref target and accepts it only at the validated HEAD' {
        $head = 'c' * 40
        Mock -CommandName Get-FabProductReleaseTagCommit -MockWith { return $head }
        Mock -CommandName Invoke-FabProductGhCommand -MockWith {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'api' -and $Arguments[1] -like '*git/ref/heads/*') {
                return ([pscustomobject]@{
                        object = [pscustomobject]@{ sha = $head; type = 'commit' }
                    } | ConvertTo-Json -Compress)
            }
            throw 'Unexpected GitHub API call in branch/ref resolution test.'
        }
        Assert-FabProductReleaseSourceCommit -RepositoryKey 'metyatech/TestPlugin' `
            -Tag 'fab-v1.0.0' -TargetCommitish 'refs/heads/master' `
            -ExpectedSourceCommit $head
    }

    It 'rejects an existing conflicting remote asset' {
        $release = Get-PublishTestRelease -EngineVersion '5.8' -Hash ('a' * 64)
        Mock -CommandName Assert-FabProductGitHubPublicationPrerequisite -MockWith {
            return Get-PublishTestPrerequisite
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') -IsDraft $true -Assets @([pscustomobject]@{
                    name               = [System.IO.Path]::GetFileName($release.ZipPath)
                    digest             = "sha256:$('b' * 64)"
                    browserDownloadUrl = 'https://example.invalid/file.zip'
                })
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
            return Get-PublishTestPrerequisite
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
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8', '5.9') `
                -IsDraft ($script:ReleaseInfoCallCount -lt 4) -Assets $assets
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
            return Get-PublishTestPrerequisite
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            $script:ReleaseInfoCallCount++
            $digest = if ($script:ReleaseInfoCallCount -lt 3) { "sha256:$('a' * 64)" } else { "sha256:$('b' * 64)" }
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') `
                -IsDraft ($script:ReleaseInfoCallCount -lt 3) -Assets @([pscustomobject]@{
                    name               = [System.IO.Path]::GetFileName($release.ZipPath)
                    digest             = $digest
                    browserDownloadUrl = 'https://example.invalid/file.zip'
                })
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
            return Get-PublishTestPrerequisite
        }
        Mock -CommandName Get-FabProductReleaseInfo -MockWith {
            return Get-PublishTestReleaseInfo -EngineVersions @('5.8') -Assets @([pscustomobject]@{
                    name               = [System.IO.Path]::GetFileName($release.ZipPath)
                    digest             = "sha256:$('a' * 64)"
                    browserDownloadUrl = $Url
                })
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
