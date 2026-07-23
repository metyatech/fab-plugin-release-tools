# Copyright (c) 2026 metyatech. All rights reserved.

<#
.SYNOPSIS
Validates, builds, packages, and revalidates a Fab Unreal Engine code plugin.

.EXAMPLE
pwsh .\Invoke-FabPluginRelease.ps1 -PluginPath C:\src\MyPlugin -EngineVersion 5.8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^5\.[0-9]+$')]
    [string]$EngineVersion,

    [string]$EngineRoot,

    [string]$ConfigPath,

    [string]$OutputDirectory,

    [switch]$KeepWorkingDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$exitCode = 1
try {
    Import-Module (Join-Path $PSScriptRoot 'FabPluginReleaseTools.psd1') -Force
    $arguments = @{
        PluginPath          = $PluginPath
        EngineVersion       = $EngineVersion
        KeepWorkingDirectory = $KeepWorkingDirectory
    }
    if ($PSBoundParameters.ContainsKey('EngineRoot')) {
        $arguments.EngineRoot = $EngineRoot
    }
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $arguments.ConfigPath = $ConfigPath
    }
    if ($PSBoundParameters.ContainsKey('OutputDirectory')) {
        $arguments.OutputDirectory = $OutputDirectory
    }
    Invoke-FabPluginRelease @arguments
    $exitCode = 0
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
finally {
    if ($exitCode -eq 0) {
        Write-Output 'FAB PLUGIN RELEASE: PASS'
    }
    else {
        Write-Output 'FAB PLUGIN RELEASE: FAIL'
    }
}

exit $exitCode
