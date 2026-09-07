# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'FabPortalAutomation\src\fab-portal-chrome.psm1'
Import-Module $modulePath -Force

Describe 'Fab dedicated Chrome launcher' {
    It 'rejects the default Chrome user-data directory and descendants' {
        $defaultRoots = @(Get-FabPortalChromeDefaultUserDataDirectory)
        $defaultRoots.Count | Should -BeGreaterThan 0
        { Resolve-FabPortalChromeUserDataDir -UserDataDir (Join-Path $defaultRoots[0] 'Default') `
                -WorkspaceRoot $TestDrive } | Should -Throw
    }

    It 'accepts a non-default profile outside the repository' {
        $testProfile = Resolve-FabPortalChromeUserDataDir -UserDataDir (Join-Path $TestDrive 'FabProfile') `
            -WorkspaceRoot (Join-Path $TestDrive 'Workspace')
        $testProfile | Should -BeExactly ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'FabProfile')))
    }

    It 'rejects a profile inside the repository' {
        $workspace = Join-Path $TestDrive 'Workspace'
        { Resolve-FabPortalChromeUserDataDir -UserDataDir (Join-Path $workspace 'ChromeProfile') `
                -WorkspaceRoot $workspace } | Should -Throw
    }

    It 'fails when an explicit Chrome executable is missing' {
        { Get-FabPortalChromeExecutable -ChromePath (Join-Path $TestDrive 'missing-chrome.exe') } |
            Should -Throw
    }

    It 'parses a valid DevToolsActivePort file' {
        $testProfile = Join-Path $TestDrive 'ValidPort'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllLines((Join-Path $testProfile 'DevToolsActivePort'), @('43210', '/devtools/browser/test'))
        $port = Read-FabPortalDevToolsActivePort -UserDataDir $testProfile
        $port.Port | Should -Be 43210
        $port.WebSocketPath | Should -BeExactly '/devtools/browser/test'
    }

    It 'fails closed for a malformed DevToolsActivePort file' {
        $testProfile = Join-Path $TestDrive 'MalformedPort'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $testProfile 'DevToolsActivePort'), 'not-a-port')
        { Read-FabPortalDevToolsActivePort -UserDataDir $testProfile } | Should -Throw
    }

    It 'times out when the endpoint never becomes ready' {
        $testProfile = Join-Path $TestDrive 'NeverReady'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllLines((Join-Path $testProfile 'DevToolsActivePort'), @('43211', '/devtools/browser/never-ready'))
        $probe = { $null }
        $processes = { $null = $args; @(9001) }
        { Wait-FabPortalChromeSession -UserDataDir $testProfile -ProcessId 9001 `
                -TimeoutSeconds 0.25 -EndpointProbe $probe -ProcessIdProvider $processes } |
            Should -Throw '*timed out*'
    }

    It 'removes stale metadata only when the profile is not running or locked' {
        $testProfile = Join-Path $TestDrive 'StaleMetadata'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        $metadataPath = Join-Path $testProfile 'DevToolsActivePort'
        [System.IO.File]::WriteAllLines($metadataPath, @('43214', '/devtools/browser/stale'))
        $removed = Remove-FabPortalStaleDevToolsActivePort -UserDataDir $testProfile -ProcessIdProvider { return @() }
        $removed | Should -BeTrue
        Test-Path -LiteralPath $metadataPath | Should -BeFalse
    }

    It 'refuses stale metadata cleanup while a dedicated Chrome process is running' {
        $testProfile = Join-Path $TestDrive 'RunningMetadata'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        $metadataPath = Join-Path $testProfile 'DevToolsActivePort'
        [System.IO.File]::WriteAllLines($metadataPath, @('43215', '/devtools/browser/running'))
        { Remove-FabPortalStaleDevToolsActivePort -UserDataDir $testProfile -ProcessIdProvider { @(9015) } } |
            Should -Throw '*process is running*'
        Test-Path -LiteralPath $metadataPath | Should -BeTrue
    }

    It 'refuses stale metadata cleanup while the profile lock is present' {
        $testProfile = Join-Path $TestDrive 'LockedMetadata'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        $metadataPath = Join-Path $testProfile 'DevToolsActivePort'
        [System.IO.File]::WriteAllLines($metadataPath, @('43216', '/devtools/browser/locked'))
        [System.IO.File]::WriteAllText((Join-Path $testProfile 'SingletonLock'), 'lock')
        { Remove-FabPortalStaleDevToolsActivePort -UserDataDir $testProfile -ProcessIdProvider { return @() } } |
            Should -Throw '*profile is locked*'
        Test-Path -LiteralPath $metadataPath | Should -BeTrue
    }

    It 'accepts metadata written after the current process baseline' {
        $testProfile = Join-Path $TestDrive 'FreshMetadata'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        $baseline = [DateTime]::UtcNow.AddMilliseconds(-100)
        Start-Sleep -Milliseconds 150
        [System.IO.File]::WriteAllLines((Join-Path $testProfile 'DevToolsActivePort'), @('43217', '/devtools/browser/fresh'))
        $fresh = Test-FabPortalDevToolsActivePortFresh -UserDataDir $testProfile -NotBeforeUtc $baseline
        $fresh.Port | Should -Be 43217
        $fresh.WebSocketPath | Should -BeExactly '/devtools/browser/fresh'
    }

    It 'rejects metadata written before the current process baseline' {
        $testProfile = Join-Path $TestDrive 'OldMetadata'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllLines((Join-Path $testProfile 'DevToolsActivePort'), @('43218', '/devtools/browser/old'))
        $future = [DateTime]::UtcNow.AddMilliseconds(100)
        Test-FabPortalDevToolsActivePortFresh -UserDataDir $testProfile -NotBeforeUtc $future | Should -BeNullOrEmpty
    }

    It 'rejects metadata without a browser websocket path for fresh sessions' {
        $testProfile = Join-Path $TestDrive 'MissingWebSocketPath'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $testProfile 'DevToolsActivePort'), '43219')
        { Test-FabPortalDevToolsActivePortFresh -UserDataDir $testProfile -NotBeforeUtc ([DateTime]::UtcNow.AddSeconds(-1)) } |
            Should -Throw '*missing the browser websocket path*'
    }

    It 'does not touch credential or profile files during stale cleanup' {
        $testProfile = Join-Path $TestDrive 'PreservedProfile'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        $metadataPath = Join-Path $testProfile 'DevToolsActivePort'
        $sentinelPath = Join-Path $testProfile 'Cookies'
        [System.IO.File]::WriteAllLines($metadataPath, @('43220', '/devtools/browser/stale'))
        [System.IO.File]::WriteAllText($sentinelPath, 'sentinel')
        [void](Remove-FabPortalStaleDevToolsActivePort -UserDataDir $testProfile -ProcessIdProvider { return @() })
        Test-Path -LiteralPath $metadataPath | Should -BeFalse
        [System.IO.File]::ReadAllText($sentinelPath) | Should -BeExactly 'sentinel'
    }

    It 'accepts a healthy endpoint only with one matching process' {
        $testProfile = Join-Path $TestDrive 'Healthy'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllLines((Join-Path $testProfile 'DevToolsActivePort'), @('43212', '/devtools/browser/test'))
        $probe = { [pscustomobject]@{ Ready = $true; Browser = 'Chrome/test'; WebSocketDebuggerUrl = 'ws://127.0.0.1/devtools/browser/test' } }
        $processes = { $null = $args; @(9002) }
        $session = Get-FabPortalChromeSession -UserDataDir $testProfile -EndpointProbe $probe -ProcessIdProvider $processes
        $session.Reused | Should -BeTrue
        $session.ChromeProcessId | Should -Be 9002
        $session.CdpEndpoint | Should -BeExactly 'http://127.0.0.1:43212'
        $session.CdpWebSocketEndpoint | Should -BeExactly 'ws://127.0.0.1:43212/devtools/browser/test'
    }

    It 'rejects an ambiguous healthy session without terminating anything' {
        $testProfile = Join-Path $TestDrive 'Ambiguous'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $testProfile 'DevToolsActivePort'), '43213')
        $probe = { [pscustomobject]@{ Ready = $true; Browser = 'Chrome/test'; WebSocketDebuggerUrl = 'ws://127.0.0.1/devtools/browser/test' } }
        $processes = { $null = $args; @(9003, 9004) }
        { Get-FabPortalChromeSession -UserDataDir $testProfile -EndpointProbe $probe -ProcessIdProvider $processes } |
            Should -Throw '*ambiguous*'
    }

    It 'builds the required safe Chrome arguments without weakening flags' {
        $chromeArgs = Get-FabPortalChromeArgumentList -UserDataDir (Join-Path $TestDrive 'FabProfile') `
            -ListingUrl 'https://www.fab.com/portal/listings/96fc1bdc-71ea-4b80-8c68-e08ae430a2a8/edit'
        $chromeArgs | Should -Contain '--remote-debugging-address=127.0.0.1'
        $chromeArgs | Should -Contain '--remote-debugging-port=0'
        ($chromeArgs -join ' ') | Should -Not -Match 'disable-web-security|ignore-certificate-errors|disable-site-isolation-trials'
    }

    It 'builds manual-login arguments for the same profile without CDP flags' {
        $manualArgs = Get-FabPortalChromeArgumentList -UserDataDir (Join-Path $TestDrive 'FabProfile') `
            -ListingUrl 'https://www.fab.com/portal/listings/96fc1bdc-71ea-4b80-8c68-e08ae430a2a8/edit' `
            -Mode ManualLogin
        ($manualArgs -join ' ') | Should -Match '--user-data-dir='
        ($manualArgs -join ' ') | Should -Not -Match 'remote-debugging-port|remote-debugging-address|remote-debugging-pipe'
    }

    It 'keeps automation arguments CDP-enabled for the same profile' {
        $automationArgs = Get-FabPortalChromeArgumentList -UserDataDir (Join-Path $TestDrive 'FabProfile') `
            -ListingUrl 'https://www.fab.com/portal/listings/96fc1bdc-71ea-4b80-8c68-e08ae430a2a8/edit' `
            -Mode Automation
        $automationArgs | Should -Contain '--remote-debugging-address=127.0.0.1'
        $automationArgs | Should -Contain '--remote-debugging-port=0'
    }

    It 'returns manual-login state without a CDP endpoint' {
        $manualState = [pscustomobject]@{
            Mode                   = 'manual-login'
            UserDataDir            = Join-Path $TestDrive 'FabProfile'
            ChromeProcessId        = 9005
            RemoteDebuggingEnabled = $false
        }
        $manualState.Mode | Should -BeExactly 'manual-login'
        $manualState.RemoteDebuggingEnabled | Should -BeFalse
        $manualState.PSObject.Properties.Name | Should -Not -Contain 'CdpEndpoint'
    }

    It 'rejects listing URLs that could carry credentials or secrets' {
        { Assert-FabPortalListingUrl -ListingUrl 'https://www.fab.com/portal/listings/abc/edit?token=secret' } |
            Should -Throw
        { Assert-FabPortalListingUrl -ListingUrl 'https://user:secret@www.fab.com/portal/listings/abc/edit' } |
            Should -Throw
    }
}
