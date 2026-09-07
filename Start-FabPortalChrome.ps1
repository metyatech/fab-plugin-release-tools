# Copyright (c) 2026 metyatech. All rights reserved.

[CmdletBinding()]
param(
    [string]$ListingUrl = 'https://www.fab.com/portal/listings/96fc1bdc-71ea-4b80-8c68-e08ae430a2a8/edit',
    [string]$UserDataDir,
    [string]$ChromePath,
    [ValidateSet('Automation', 'ManualLogin')]
    [string]$Mode = 'Automation',
    [ValidateRange(1, 300)]
    [int]$ReadyTimeoutSeconds = 30,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'FabPortalAutomation\src\fab-portal-chrome.psm1'
Import-Module $modulePath -Force

try {
    $session = Start-FabPortalChromeSession -ListingUrl $ListingUrl -UserDataDir $UserDataDir `
        -ChromePath $ChromePath -Mode $Mode -ReadyTimeoutSeconds $ReadyTimeoutSeconds
    if ($Json) {
        $session | ConvertTo-Json -Depth 10 -Compress | Write-Output
    }
    else {
        if ($Mode -eq 'ManualLogin') {
            @(
                'Fab dedicated Chrome manual-login window is ready.',
                'Complete Fab login, MFA, and any security challenge in that window.',
                'Close that Chrome window normally before starting Automation mode.',
                "Mode: $($session.Mode)",
                "ChromeProcessId: $($session.ChromeProcessId)",
                "UserDataDir: $($session.UserDataDir)",
                "RemoteDebuggingEnabled: $($session.RemoteDebuggingEnabled)"
            ) | Write-Output
        }
        else {
            @(
                'Fab dedicated Chrome is ready.',
                "CdpEndpoint: $($session.CdpEndpoint)",
                "ChromeProcessId: $($session.ChromeProcessId)",
                "UserDataDir: $($session.UserDataDir)",
                "Launched: $($session.Launched)",
                "Reused: $($session.Reused)"
            ) | Write-Output
        }
    }
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
