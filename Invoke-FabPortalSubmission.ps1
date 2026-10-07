# Copyright (c) 2026 metyatech. All rights reserved.

[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$CdpEndpoint,
    [string]$ObservationPath,
    [string]$OutputDirectory,
    [string[]]$Tags,
    [switch]$PreSubmit,
    [switch]$TagAvailability,
    [switch]$Json,
    [switch]$VerboseOutput,
    [switch]$Help,
    [switch]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NodeProcess {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$Interactive
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'node'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = -not $Interactive
    if (-not $Interactive) {
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start Node.js.'
    }
    if ($Interactive) {
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = ''
            StandardError = ''
        }
    }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StandardOutput = $stdout.Result
        StandardError = $stderr.Result
    }
}

if ($Help) {
    $helpResult = Invoke-NodeProcess -Arguments @((Join-Path $PSScriptRoot 'FabPortalAutomation\src\cli.mjs'), '--help')
    $helpResult.StandardOutput | Write-Output
    exit $helpResult.ExitCode
}

if ($Version) {
    $versionResult = Invoke-NodeProcess -Arguments @((Join-Path $PSScriptRoot 'FabPortalAutomation\src\cli.mjs'), '--version')
    $versionResult.StandardOutput | Write-Output
    exit $versionResult.ExitCode
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    throw 'ManifestPath is required. Use -Help for usage.'
}
$hasCdpEndpoint = -not [string]::IsNullOrWhiteSpace($CdpEndpoint)
$hasObservationPath = -not [string]::IsNullOrWhiteSpace($ObservationPath)
if ($hasCdpEndpoint -eq $hasObservationPath) {
    throw 'Exactly one of CdpEndpoint or ObservationPath is required. Use -Help for usage.'
}
if ($PreSubmit -and $hasObservationPath) {
    throw 'Pre-submit verification requires live browser/CDP verification and cannot be satisfied by an observation artifact.'
}
if ($PreSubmit -and -not $hasCdpEndpoint) {
    throw 'Pre-submit verification requires live browser/CDP verification and cannot be satisfied by an observation artifact.'
}
if ($TagAvailability -and (-not $hasCdpEndpoint -or $hasObservationPath -or $PreSubmit)) {
    throw 'Tag availability discovery requires live browser/CDP verification and cannot use an observation artifact.'
}
if ($TagAvailability -and (-not $Tags -or $Tags.Count -eq 0)) {
    throw 'TagAvailability requires one or more -Tags candidates.'
}
if (-not $TagAvailability -and $Tags) {
    throw '-Tags is valid only with -TagAvailability.'
}
$runtime = Join-Path $PSScriptRoot 'FabPortalAutomation'
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'node_modules\playwright-core\package.json') -PathType Leaf)) {
    throw "Portal automation dependencies are not installed. Run npm ci in $runtime."
}
$arguments = [System.Collections.Generic.List[string]]::new()
[void]$arguments.Add((Join-Path $runtime 'src\cli.mjs'))
[void]$arguments.Add('--manifest')
[void]$arguments.Add([System.IO.Path]::GetFullPath($ManifestPath))
if ($hasCdpEndpoint) {
    [void]$arguments.Add('--cdp-endpoint')
    [void]$arguments.Add($CdpEndpoint)
}
else {
    [void]$arguments.Add('--observation')
    [void]$arguments.Add([System.IO.Path]::GetFullPath($ObservationPath))
}
if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    [void]$arguments.Add('--output')
    [void]$arguments.Add([System.IO.Path]::GetFullPath($OutputDirectory))
}
if ($Json) { [void]$arguments.Add('--json') }
if ($VerboseOutput) { [void]$arguments.Add('--verbose') }
if ($PreSubmit) { [void]$arguments.Add('--pre-submit') }
if ($TagAvailability) {
    [void]$arguments.Add('--tag-availability')
    foreach ($tag in $Tags) {
        [void]$arguments.Add('--tag')
        [void]$arguments.Add($tag)
    }
}
$result = Invoke-NodeProcess -Arguments $arguments.ToArray() -Interactive
if (-not [string]::IsNullOrEmpty($result.StandardOutput)) {
    $result.StandardOutput | Write-Output
}
if (-not [string]::IsNullOrEmpty($result.StandardError)) {
    $result.StandardError | Write-Error
}
exit $result.ExitCode
