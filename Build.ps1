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
    $portalDirectory = Join-Path $PSScriptRoot 'FabPortalAutomation'
    $portalInstall = [System.Diagnostics.ProcessStartInfo]::new()
    $portalInstall.FileName = (Get-Command npm.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $portalInstall.UseShellExecute = $false
    $portalInstall.CreateNoWindow = $true
    $portalInstall.WorkingDirectory = $portalDirectory
    [void]$portalInstall.ArgumentList.Add('ci')
    [void]$portalInstall.ArgumentList.Add('--ignore-scripts')
    $portalProcess = [System.Diagnostics.Process]::new()
    $portalProcess.StartInfo = $portalInstall
    if (-not $portalProcess.Start()) {
        throw 'Unable to start npm for Fab portal automation dependencies.'
    }
    $portalProcess.WaitForExit()
    if ($portalProcess.ExitCode -ne 0) {
        throw "Fab portal automation dependency installation failed with exit code $($portalProcess.ExitCode)."
    }
}

function Invoke-PortalAutomationTest {
    $portalDirectory = Join-Path $PSScriptRoot 'FabPortalAutomation'
    $packagePath = Join-Path $portalDirectory 'node_modules\playwright-core\package.json'
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw 'Fab portal automation dependencies are missing. Run pwsh .\Build.ps1 -Task Bootstrap or npm ci in FabPortalAutomation.'
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command npm.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $portalDirectory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add('test')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start Fab portal automation tests.'
    }
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    if (-not [string]::IsNullOrWhiteSpace($output.Result)) {
        $output.Result | Write-Output
    }
    if (-not [string]::IsNullOrWhiteSpace($errors.Result)) {
        $errors.Result | Write-Output
    }
    if ($process.ExitCode -ne 0) {
        throw "Fab portal automation tests failed with exit code $($process.ExitCode)."
    }
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
    Invoke-PortalAutomationTest
}

function Invoke-Analysis {
    Assert-PowerShellVersion
    Import-Module PSScriptAnalyzer -RequiredVersion $analyzerVersion -Force
    $sourceFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
            Where-Object Extension -In @('.ps1', '.psm1', '.psd1') |
            Where-Object FullName -NotMatch '[\\/](?:TestResults|artifacts|node_modules)[\\/]')
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
    $findings = @()
    foreach ($analysisFile in $sourceFiles) {
        $findings += @(Invoke-ScriptAnalyzer -Path $analysisFile.FullName -Settings (
                Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'))
    }
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
