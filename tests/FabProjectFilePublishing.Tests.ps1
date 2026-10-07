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
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'test-api-token', 'Process')
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

        try {
            Assert-FabR2BucketAccess -Publishing ([pscustomobject]@{
                    Bucket = 'metyatech-fab-project-files'
                }) | Should -BeExactly 'wrangler'
            Should -Invoke Invoke-FabR2Wrangler -Times 2 -Exactly
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
        }
    }

    It 'uses the exact configured bucket info command for local OAuth' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        $previousCi = [Environment]::GetEnvironmentVariable('CI', 'Process')
        $previousGithubActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CI', 'true', 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $null, 'Process')
        Mock Get-FabR2Wrangler { 'wrangler' }
        Mock Invoke-FabR2Wrangler {
            param([string]$WranglerPath, [string[]]$Arguments)
            [void]$WranglerPath
            [void]$Arguments
            [pscustomobject]@{ Output = $null; Error = $null; ExitCode = 0; ExecutionMode = 'LocalOAuth' }
        }

        try {
            Assert-FabR2BucketAccess -Publishing ([pscustomobject]@{
                    Bucket = 'metyatech-fab-project-files'
                }) | Should -BeExactly 'wrangler'
            Should -Invoke Invoke-FabR2Wrangler -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -ceq 'r2 bucket info metyatech-fab-project-files'
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
            [Environment]::SetEnvironmentVariable('CI', $previousCi, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $previousGithubActions, 'Process')
        }
    }

    It 'keeps captured bucket listing for an explicit API token' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'test-api-token', 'Process')
        Mock Get-FabR2Wrangler { 'wrangler' }
        Mock Invoke-FabR2Wrangler {
            param([string]$WranglerPath, [string[]]$Arguments)
            [void]$WranglerPath
            [void]$Arguments
            [pscustomobject]@{
                Output = '[{"name":"metyatech-fab-project-files"}]'
                Error = ''
                ExitCode = 0
                ExecutionMode = 'ApiToken'
            }
        }

        try {
            Assert-FabR2BucketAccess -Publishing ([pscustomobject]@{
                    Bucket = 'metyatech-fab-project-files'
                }) | Should -BeExactly 'wrangler'
            Should -Invoke Invoke-FabR2Wrangler -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -ceq 'r2 bucket list --json'
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
        }
    }

    It 'rejects a missing bucket in the captured API-token bucket list' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'test-api-token', 'Process')
        Mock Get-FabR2Wrangler { 'wrangler' }
        Mock Invoke-FabR2Wrangler {
            [pscustomobject]@{
                Output = '[{"name":"some-other-bucket"}]'
                Error = ''
                ExitCode = 0
                ExecutionMode = 'ApiToken'
            }
        }

        try {
            { Assert-FabR2BucketAccess -Publishing ([pscustomobject]@{
                        Bucket = 'metyatech-fab-project-files'
                    }) } | Should -Throw '*CLOUDFLARE_BUCKET_MISMATCH*'
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
        }
    }

    It 'fails closed on a real CI marker without an API token' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        $previousGithubActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $null, 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', 'true', 'Process')

        try {
            { Get-FabR2WranglerExecutionMode } | Should -Throw '*CLOUDFLARE_API_TOKEN_REQUIRED*'
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $previousGithubActions, 'Process')
        }
    }

    It 'selects the explicit API-token path before CI OAuth rejection' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        $previousGithubActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'test-api-token', 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', 'true', 'Process')

        try {
            Get-FabR2WranglerExecutionMode | Should -BeExactly 'ApiToken'
            $startInfo = Get-FabR2WranglerStartInfo -WranglerPath 'wrangler.cmd' `
                -Arguments @('r2', 'bucket', 'list', '--json')
            $startInfo.RedirectStandardOutput | Should -BeTrue
            $startInfo.RedirectStandardError | Should -BeTrue
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $previousGithubActions, 'Process')
        }
    }

    It 'fails local bucket access when bucket info exits nonzero' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        $previousGithubActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $null, 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $null, 'Process')
        Mock Get-FabR2Wrangler { 'wrangler' }
        Mock Invoke-FabR2Wrangler { throw 'Wrangler failed with exit code 1.' }

        try {
            { Assert-FabR2BucketAccess -Publishing ([pscustomobject]@{
                        Bucket = 'metyatech-fab-project-files'
                    }) } | Should -Throw '*CLOUDFLARE_BUCKET_ACCESS_FAILED*'
            Should -Invoke Invoke-FabR2Wrangler -Times 1 -Exactly -ParameterFilter {
                ($Arguments -join ' ') -ceq 'r2 bucket info metyatech-fab-project-files'
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $previousGithubActions, 'Process')
        }
    }

    It 'configures inherited console streams for local OAuth despite generic CI contamination' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        $previousCi = [Environment]::GetEnvironmentVariable('CI', 'Process')
        $previousGithubActions = [Environment]::GetEnvironmentVariable('GITHUB_ACTIONS', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CI', 'true', 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $null, 'Process')

        try {
            $startInfo = Get-FabR2WranglerStartInfo -WranglerPath 'wrangler.cmd' `
                -Arguments @('r2', 'bucket', 'info', 'metyatech-fab-project-files')
            $startInfo.UseShellExecute | Should -BeFalse
            $startInfo.CreateNoWindow | Should -BeFalse
            $startInfo.RedirectStandardOutput | Should -BeFalse
            $startInfo.RedirectStandardError | Should -BeFalse
            @($startInfo.ArgumentList) | Should -BeExactly @(
                'r2', 'bucket', 'info', 'metyatech-fab-project-files')
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
            [Environment]::SetEnvironmentVariable('CI', $previousCi, 'Process')
            [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS', $previousGithubActions, 'Process')
        }
    }

    It 'captures Wrangler streams for an explicit API token' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'test-api-token', 'Process')

        try {
            $startInfo = Get-FabR2WranglerStartInfo -WranglerPath 'wrangler.cmd' -Arguments @('r2', 'bucket', 'list')
            $startInfo.UseShellExecute | Should -BeFalse
            $startInfo.CreateNoWindow | Should -BeTrue
            $startInfo.RedirectStandardOutput | Should -BeTrue
            $startInfo.RedirectStandardError | Should -BeTrue
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
        }
    }

    It 'preserves object put arguments in local OAuth mode' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        $previousCi = [Environment]::GetEnvironmentVariable('CI', 'Process')
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CI', $null, 'Process')
        $zipPath = Join-Path $TestDrive 'Product.zip'

        try {
            $arguments = Get-FabR2ObjectPutArgumentList -Bucket 'metyatech-fab-project-files' `
                -ObjectKey 'my-product/1.0.0/UE5.8/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Product.zip' `
                -FilePath $zipPath
            $startInfo = Get-FabR2WranglerStartInfo -WranglerPath 'wrangler.cmd' -Arguments $arguments
            @($startInfo.ArgumentList) | Should -BeExactly @(
                'r2', 'object', 'put', 'metyatech-fab-project-files/my-product/1.0.0/UE5.8/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/Product.zip',
                '--file', $zipPath, '--remote', '--content-type', 'application/zip')
            $startInfo.RedirectStandardOutput | Should -BeFalse
            $startInfo.RedirectStandardError | Should -BeFalse
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
            [Environment]::SetEnvironmentVariable('CI', $previousCi, 'Process')
        }
    }

    It 'fails nonzero Wrangler commands and sanitizes API token text from errors' {
        $previousToken = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')
        $fakeToken = 'test-secret-token-never-log'
        [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $fakeToken, 'Process')
        $failureScript = Join-Path $TestDrive 'WranglerFailure.ps1'
        [System.IO.File]::WriteAllText($failureScript, "[Console]::Error.WriteLine('$fakeToken'); exit 7")
        $pwshPath = (Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source

        try {
            $caught = $null
            try {
                Invoke-FabR2Wrangler -WranglerPath $pwshPath -Arguments @('-NoProfile', '-File', $failureScript)
            }
            catch {
                $caught = $_.Exception.Message
            }
            $caught | Should -Match 'exit code 7'
            $caught | Should -Not -Match ([regex]::Escape($fakeToken))
            $caught | Should -Match '\[REDACTED\]'
        }
        finally {
            [Environment]::SetEnvironmentVariable('CLOUDFLARE_API_TOKEN', $previousToken, 'Process')
        }
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

Describe 'Fab project file publication listing update' {
    BeforeAll {
        function Invoke-PublicationFixture {
            param(
                [bool]$FailSecondEngineVerification = $false,
                [string]$TestProjectPath
            )

            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [System.IO.Directory]::CreateDirectory($root) | Out-Null
            $listingPath = Join-Path $root 'FabListingFields.json'
            $listing = [pscustomobject]@{
                title = 'Fixture'
                media_order = @('Marketing/Fab/01.jpg', 'Marketing/Fab/02.jpg')
            }
            $initialText = ($listing | ConvertTo-Json -Depth 20) + "`n"
            [System.IO.File]::WriteAllText($listingPath, $initialText)
            $outputDirectory = Join-Path $root 'publication-output'
            . (Join-Path $PSScriptRoot '..\Publish-FabProjectFiles.ps1') `
                -PluginPath $root -ListingFieldsPath $listingPath -OutputDirectory $outputDirectory `
                -TestProjectPath $TestProjectPath

            $script:publicationFixture = [pscustomobject]@{
                Root = $root
                ListingPath = $listingPath
                Listing = $listing
                InitialText = $initialText
                Records = @()
                FailSecondEngineVerification = $FailSecondEngineVerification
                TestProjectPath = $TestProjectPath
                ForwardedTestProjectPath = $null
                RemoteCallCounts = @{}
            }

            Mock Assert-FabSubmissionPluginRoot { $PluginPath }
            Mock Assert-FabSubmissionSchema {}
            Mock Read-FabSubmissionJson {
                [pscustomobject]@{
                    pluginName = 'FixturePlugin'
                    engineVersions = @('5.6', '5.8')
                }
            }
            Mock Assert-FabProjectFilePublishingConfiguration {
                [pscustomobject]@{
                    Bucket = 'fixture-bucket'
                    PublicBaseUrl = 'https://downloads.example'
                    ObjectPrefix = 'fixture-product'
                }
            }
            Mock Get-FabSubmissionListingData {
                [pscustomobject]@{
                    Root = $script:publicationFixture.Root
                    Path = $script:publicationFixture.ListingPath
                    Listing = $script:publicationFixture.Listing
                    Media = @()
                }
            }
            Mock Invoke-FabProductReleaseCore {
                param([string]$OutputDirectory, [string]$TestProjectPath)
                $script:publicationFixture.ForwardedTestProjectPath = $TestProjectPath
                $bundleRoot = Join-Path $OutputDirectory 'bundle'
                $records = foreach ($engineVersion in @('5.6', '5.8')) {
                    $relativePath = "packages/UE$engineVersion/Fixture_UE$engineVersion.zip"
                    $packagePath = Join-Path $bundleRoot ($relativePath.Replace('/', '\\'))
                    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $packagePath)) | Out-Null
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("fixture-package-UE$engineVersion")
                    [System.IO.File]::WriteAllBytes($packagePath, $bytes)
                    [pscustomobject]@{
                        EngineVersion = $engineVersion
                        RelativePath = $relativePath
                        Bytes = $bytes.Length
                        Sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                    }
                }
                $script:publicationFixture.Records = @($records)
                [pscustomobject]@{
                    BundlePath = $bundleRoot
                    Manifest = [pscustomobject]@{
                        pluginName = 'FixturePlugin'
                        productVersion = '1.0.0'
                        packages = @($records | ForEach-Object {
                                [pscustomobject]@{
                                    engineVersion = $_.EngineVersion
                                    bundleRelativePath = $_.RelativePath
                                    sha256 = $_.Sha256
                                }
                            })
                    }
                }
            }
            Mock Assert-FabR2BucketAccess { 'wrangler' }
            Mock Invoke-FabR2Wrangler { 'uploaded' }
            Mock Get-FabR2RemoteObject {
                param([string]$Url)
                $record = $script:publicationFixture.Records | Where-Object {
                    $Url.Contains("/UE$($_.EngineVersion)/")
                } | Select-Object -First 1
                if ($null -eq $record) { throw "Unexpected fixture URL: $Url" }
                $calls = 0
                if ($script:publicationFixture.RemoteCallCounts.ContainsKey($record.EngineVersion)) {
                    $calls = $script:publicationFixture.RemoteCallCounts[$record.EngineVersion]
                }
                $calls++
                $script:publicationFixture.RemoteCallCounts[$record.EngineVersion] = $calls
                if ($script:publicationFixture.FailSecondEngineVerification -and
                    $record.EngineVersion -eq '5.8' -and $calls -eq 1) {
                    return [pscustomobject]@{ StatusCode = 404; Bytes = 0; Sha256 = '' }
                }
                $sha256 = $record.Sha256
                if ($script:publicationFixture.FailSecondEngineVerification -and
                    $record.EngineVersion -eq '5.8') {
                    $sha256 = '0' * 64
                }
                [pscustomobject]@{ StatusCode = 200; Bytes = $record.Bytes; Sha256 = $sha256 }
            }

            $publicationResult = $null
            $errorMessage = $null
            try {
                $publicationOutput = @(Invoke-FabProjectFilePublication `
                    -TestProjectPath $TestProjectPath -UpdateListingFields)
                $publicationResult = $publicationOutput | Where-Object {
                    $null -ne $_.PSObject.Properties['ListingAction']
                } | Select-Object -Last 1
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            return [pscustomobject]@{
                PublicationResult = $publicationResult
                ErrorMessage = $errorMessage
                Fixture = $script:publicationFixture
            }
        }
    }

    It 'writes the complete exact link set only after every engine verifies' {
        $testResult = Invoke-PublicationFixture
        $testResult.ErrorMessage | Should -BeNullOrEmpty
        $testResult.PublicationResult.ListingAction | Should -BeExactly 'WRITTEN'
        $listing = Get-Content -Raw -LiteralPath $testResult.Fixture.ListingPath | ConvertFrom-Json
        @($listing.project_file_links.PSObject.Properties.Name) | Should -BeExactly @('5.6', '5.8')
        foreach ($record in $testResult.Fixture.Records) {
            $fileName = [System.IO.Path]::GetFileName($record.RelativePath)
            $expectedUrl = "https://downloads.example/fixture-product/1.0.0/UE$($record.EngineVersion)/$($record.Sha256)/$fileName"
            $listing.project_file_links.($record.EngineVersion) | Should -BeExactly $expectedUrl
        }
    }

    It 'leaves the listing byte-for-byte unchanged when an engine verification fails' {
        $testResult = Invoke-PublicationFixture -FailSecondEngineVerification $true
        $testResult.ErrorMessage | Should -BeLike '*R2 object verification failed after publication*'
        [System.IO.File]::ReadAllText($testResult.Fixture.ListingPath) |
            Should -BeExactly $testResult.Fixture.InitialText
    }

    It 'forwards TestProjectPath through direct project-file publication to product release' {
        $testProjectPath = Join-Path $TestDrive 'reviewer-demo-project'
        $testResult = Invoke-PublicationFixture -TestProjectPath $testProjectPath
        $testResult.ErrorMessage | Should -BeNullOrEmpty
        $testResult.Fixture.ForwardedTestProjectPath | Should -BeExactly $testProjectPath
    }
}
