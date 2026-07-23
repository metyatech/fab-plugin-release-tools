# Copyright (c) 2026 metyatech. All rights reserved.

[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Test', 'Analyze', 'Verify')]
    [string]$Task = 'Verify'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredPowerShellVersion = [version]'7.4.0'
$pesterVersion = '5.9.0'
$analyzerVersion = '1.25.0'

function Assert-PowerShellVersion {
    if ($PSVersionTable.PSVersion -lt $requiredPowerShellVersion) {
        throw "PowerShell $requiredPowerShellVersion or later is required. Current: $($PSVersionTable.PSVersion)"
    }
}

function Install-RequiredModule {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RequiredVersion
    )

    $module = Get-Module -ListAvailable -Name $Name |
        Where-Object Version -EQ ([version]$RequiredVersion) |
        Select-Object -First 1
    if ($null -eq $module) {
        Install-Module -Name $Name -RequiredVersion $RequiredVersion -Scope CurrentUser -Force -AllowClobber
    }
}

function Invoke-Bootstrap {
    Assert-PowerShellVersion
    Install-RequiredModule -Name Pester -RequiredVersion $pesterVersion
    Install-RequiredModule -Name PSScriptAnalyzer -RequiredVersion $analyzerVersion
}

function Invoke-Test {
    Assert-PowerShellVersion
    Import-Module Pester -RequiredVersion $pesterVersion -Force
    $testResultsDirectory = Join-Path $PSScriptRoot 'TestResults'
    [System.IO.Directory]::CreateDirectory($testResultsDirectory) | Out-Null
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $PSScriptRoot 'tests'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = Join-Path $testResultsDirectory 'Pester.xml'
    $result = Invoke-Pester -Configuration $configuration
    if ($null -eq $result -or $null -eq $result.PSObject.Properties['Result']) {
        throw 'Pester did not return a valid run result. Test discovery or result export failed.'
    }
    if ($result.Result -ne 'Passed' -or $result.TotalCount -eq 0 -or
        $result.FailedCount -gt 0 -or $result.SkippedCount -gt 0 -or $result.NotRunCount -gt 0) {
        throw "Pester failed. Result=$($result.Result), Total=$($result.TotalCount), Failed=$($result.FailedCount), Skipped=$($result.SkippedCount), NotRun=$($result.NotRunCount)"
    }
}

function Invoke-Analysis {
    Assert-PowerShellVersion
    Import-Module PSScriptAnalyzer -RequiredVersion $analyzerVersion -Force
    $sourceFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
            Where-Object Extension -In @('.ps1', '.psm1', '.psd1') |
            Where-Object FullName -NotMatch '[\\/]TestResults[\\/]')
    foreach ($file in $sourceFiles) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "PowerShell parser errors in $($file.FullName): $($parseErrors.Message -join '; ')"
        }
        $original = [System.IO.File]::ReadAllText($file.FullName)
        $formatted = Invoke-Formatter -ScriptDefinition $original -Settings (
            Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1')
        if ($formatted -cne $original) {
            throw "PowerShell formatting drift detected: $($file.FullName)"
        }
    }
    $findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings (
            Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'))
    if ($findings.Count -gt 0) {
        $findings | Format-Table -AutoSize | Out-String | Write-Output
        throw "PSScriptAnalyzer reported $($findings.Count) Error/Warning finding(s)."
    }
}

switch ($Task) {
    'Bootstrap' { Invoke-Bootstrap }
    'Test' { Invoke-Test }
    'Analyze' { Invoke-Analysis }
    'Verify' {
        Invoke-Test
        Invoke-Analysis
    }
}
