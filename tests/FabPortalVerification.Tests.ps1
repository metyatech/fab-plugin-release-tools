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

            $moduleVersion | Should -BeExactly '0.7.9'
            $toolVersion | Should -BeExactly '0.7.9'
            $nodeCliVersion | Should -BeExactly '0.7.9'
            $moduleVersion | Should -BeExactly $toolVersion
            $toolVersion | Should -BeExactly $nodeCliVersion
        }
    }
}
