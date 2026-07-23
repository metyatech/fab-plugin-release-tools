# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'git.exe'
$startInfo.WorkingDirectory = $repositoryRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
foreach ($argument in @('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z')) {
    [void]$startInfo.ArgumentList.Add($argument)
}
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
try {
    [void]$process.Start()
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [System.Threading.Tasks.Task]::WaitAll(@($standardOutput, $standardError))
    if ($process.ExitCode -ne 0) {
        throw "Unable to enumerate staged files: $($standardError.Result)"
    }
    $paths = @($standardOutput.Result.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
}
finally {
    $process.Dispose()
}

$settings = Join-Path $repositoryRoot 'PSScriptAnalyzerSettings.psd1'
foreach ($relativePath in $paths) {
    $extension = [System.IO.Path]::GetExtension($relativePath)
    if ($extension -notin @('.ps1', '.psm1', '.psd1')) {
        continue
    }
    $fullPath = Join-Path $repositoryRoot $relativePath
    if (-not [System.IO.File]::Exists($fullPath)) {
        continue
    }
    $original = [System.IO.File]::ReadAllText($fullPath)
    $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $settings
    if ($formatted -cne $original) {
        [System.IO.File]::WriteAllText($fullPath, $formatted, [System.Text.UTF8Encoding]::new($false))
    }
    $addInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $addInfo.FileName = 'git.exe'
    $addInfo.WorkingDirectory = $repositoryRoot
    $addInfo.UseShellExecute = $false
    $addInfo.CreateNoWindow = $true
    [void]$addInfo.ArgumentList.Add('add')
    [void]$addInfo.ArgumentList.Add('--')
    [void]$addInfo.ArgumentList.Add($relativePath)
    $addProcess = [System.Diagnostics.Process]::Start($addInfo)
    try {
        $addProcess.WaitForExit()
        if ($addProcess.ExitCode -ne 0) {
            throw "Unable to restage formatted file: $relativePath"
        }
    }
    finally {
        $addProcess.Dispose()
    }
}
