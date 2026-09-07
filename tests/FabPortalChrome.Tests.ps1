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
            -WorkspaceRoot $repositoryRoot
        $testProfile | Should -BeExactly ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'FabProfile')))
    }

    It 'rejects a profile inside the repository' {
        { Resolve-FabPortalChromeUserDataDir -UserDataDir (Join-Path $repositoryRoot 'ChromeProfile') `
                -WorkspaceRoot $repositoryRoot } | Should -Throw
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
        [System.IO.File]::WriteAllText((Join-Path $testProfile 'DevToolsActivePort'), '43211')
        $probe = { $null }
        $processes = { $null = $args; @(9001) }
        { Wait-FabPortalChromeSession -UserDataDir $testProfile -ProcessId 9001 `
                -TimeoutSeconds 0.25 -EndpointProbe $probe -ProcessIdProvider $processes } |
            Should -Throw '*timed out*'
    }

    It 'accepts a healthy endpoint only with one matching process' {
        $testProfile = Join-Path $TestDrive 'Healthy'
        [System.IO.Directory]::CreateDirectory($testProfile) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $testProfile 'DevToolsActivePort'), '43212')
        $probe = { [pscustomobject]@{ Ready = $true; Browser = 'Chrome/test'; WebSocketDebuggerUrl = 'ws://127.0.0.1/devtools/browser/test' } }
        $processes = { $null = $args; @(9002) }
        $session = Get-FabPortalChromeSession -UserDataDir $testProfile -EndpointProbe $probe -ProcessIdProvider $processes
        $session.Reused | Should -BeTrue
        $session.ChromeProcessId | Should -Be 9002
        $session.CdpEndpoint | Should -BeExactly 'http://127.0.0.1:43212'
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

    It 'rejects listing URLs that could carry credentials or secrets' {
        { Assert-FabPortalListingUrl -ListingUrl 'https://www.fab.com/portal/listings/abc/edit?token=secret' } |
            Should -Throw
        { Assert-FabPortalListingUrl -ListingUrl 'https://user:secret@www.fab.com/portal/listings/abc/edit' } |
            Should -Throw
    }
}
