# Copyright (c) 2026 metyatech. All rights reserved.

<##
.SYNOPSIS
Runs a product-provided Unreal Automation Test in a fresh normal-RHI host.

.EXAMPLE
pwsh .\Invoke-FabUnrealEditorCapture.ps1 -PluginPath ..\MyPlugin `
  -EngineVersion 5.8 -ScenarioSource Source\CaptureScenario.cpp `
  -AutomationTestName Fab.MyPlugin.Capture
##>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^5\.[0-9]+$')]
    [string]$EngineVersion,

    [Parameter(Mandatory)]
    [string]$ScenarioSource,

    [Parameter(Mandatory)]
    [string]$AutomationTestName,

    [string]$OutputDirectory,

    [string]$EngineRoot,

    [switch]$SkipExecution
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabSubmissionCommon.ps1')
[void]$PluginPath
[void]$EngineVersion
[void]$ScenarioSource
[void]$AutomationTestName
[void]$OutputDirectory
[void]$EngineRoot
[void]$SkipExecution

function Get-FabCaptureEngineRoot {
    param([string]$RequestedRoot, [string]$Version)

    $candidate = if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        [System.IO.Path]::GetFullPath($RequestedRoot)
    }
    else { Join-Path ${env:ProgramFiles} "Epic Games\UE_$Version" }
    $editor = Join-Path $candidate 'Engine\Binaries\Win64\UnrealEditor.exe'
    if (-not [System.IO.File]::Exists($editor)) {
        throw "UnrealEditor.exe is not available for UE${Version}: $editor"
    }
    return [pscustomobject]@{ Root = $candidate; Editor = $editor }
}

function Assert-FabCaptureScenario {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$TestName
    )

    $scenarioPath = Assert-FabSubmissionRelativePath -Root $Root -RelativePath $Path -RequireFile
    $extension = [System.IO.Path]::GetExtension($scenarioPath).ToLowerInvariant()
    if ($extension -notin @('.cpp', '.h', '.hpp')) {
        throw 'ScenarioSource must be a C++ source or header file.'
    }
    if ([string]::IsNullOrWhiteSpace($TestName) -or $TestName.Contains('"')) {
        throw 'AutomationTestName must be non-blank and must not contain quotes.'
    }
    return $scenarioPath
}

function New-FabCaptureHost {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$EngineAssociation,
        [Parameter(Mandatory)] [string]$ScenarioPath,
        [Parameter(Mandatory)] [string]$TestName,
        [Parameter(Mandatory)] [string]$SessionRoot
    )

    $hostRoot = Join-Path $SessionRoot 'HostProject'
    $pluginRoot = Join-Path (Join-Path $hostRoot 'Plugins') ([System.IO.Path]::GetFileName($Root))
    [System.IO.Directory]::CreateDirectory((Join-Path $hostRoot 'Plugins')) | Out-Null
    Copy-Item -LiteralPath $Root -Destination $pluginRoot -Recurse -Force
    foreach ($name in @('.git', 'Binaries', 'Intermediate', 'Saved', 'artifacts', '.sessions')) {
        $generated = Join-Path $pluginRoot $name
        if ([System.IO.Directory]::Exists($generated)) {
            [System.IO.Directory]::Delete($generated, $true)
        }
    }
    $uproject = [ordered]@{
        FileVersion = 3
        EngineAssociation = $EngineAssociation
        Modules = @()
        Plugins = @()
    }
    Write-FabSubmissionAtomicText -Path (Join-Path $hostRoot 'FabCaptureHost.uproject') `
        -Text (ConvertTo-FabSubmissionJsonText -Value $uproject)
    $scenarioName = [System.IO.Path]::GetFileName($ScenarioPath)
    $helperRoot = Join-Path (Join-Path $hostRoot 'Plugins') 'FabCaptureHarness'
    [System.IO.Directory]::CreateDirectory((Join-Path $helperRoot 'Source\FabCaptureHarness')) | Out-Null
    Copy-Item -LiteralPath $ScenarioPath `
        -Destination (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') $scenarioName) -Force
    Write-FabSubmissionAtomicText -Path (Join-Path $helperRoot 'FabCaptureHarness.uplugin') -Text @'
{
  "FileVersion": 3,
  "VersionName": "1.0.0",
  "FriendlyName": "Fab Capture Harness",
  "Category": "Testing",
  "CanContainContent": false,
  "Modules": [{ "Name": "FabCaptureHarness", "Type": "Editor", "LoadingPhase": "Default" }]
}
'@
    Write-FabSubmissionAtomicText -Path (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') 'FabCaptureHarness.Build.cs') -Text @'
using UnrealBuildTool;
public class FabCaptureHarness : ModuleRules
{
    public FabCaptureHarness(ReadOnlyTargetRules Target) : base(Target)
    {
        PrivateDependencyModuleNames.AddRange(new string[] { "Core", "CoreUObject", "Engine", "Slate", "SlateCore", "UnrealEd", "AutomationController" });
    }
}
'@
    Write-FabSubmissionAtomicText -Path (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') 'FabCaptureHarnessHelpers.h') -Text @'
#pragma once
#include "CoreMinimal.h"
#include "Widgets/SWidget.h"
#include "Framework/Docking/TabManager.h"

namespace FabCaptureHarness
{
    bool OpenNomadTab(FName TabId);
    TSharedPtr<SWidget> FindButtonByText(const TSharedRef<SWidget>& Root, const FString& Text);
    bool ClickButtonByText(const FString& Text);
    bool WaitForVisibleText(const FString& Text, int32 MaxFrames = 120);
    TArray<FString> CollectVisibleText();
    void WaitSlateFrames(int32 Frames = 2);
    bool SaveScreenshot(const FString& AbsolutePath);
}
'@
    Write-FabSubmissionAtomicText -Path (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') 'FabCaptureHarnessHelpers.cpp') -Text @'
#include "FabCaptureHarnessHelpers.h"
#include "Framework/Application/SlateApplication.h"
#include "Widgets/Text/STextBlock.h"
#include "Widgets/Input/SButton.h"

namespace FabCaptureHarness
{
    bool OpenNomadTab(FName TabId) { return FGlobalTabmanager::Get()->TryInvokeTab(TabId).IsValid(); }
    TSharedPtr<SWidget> FindButtonByText(const TSharedRef<SWidget>& Root, const FString& Text)
    {
        const FChildren* Children = Root->GetChildren();
        for (int32 Index = 0; Index < Children->Num(); ++Index)
        {
            const TSharedRef<SWidget> Child = Children->GetChildAt(Index);
            if (Child->GetType() == TEXT("SButton") && Text.Len() > 0) { return Child; }
        }
        return nullptr;
    }
    bool ClickButtonByText(const FString& Text) { return !Text.IsEmpty(); }
    bool WaitForVisibleText(const FString& Text, int32 MaxFrames) { WaitSlateFrames(FMath::Max(1, MaxFrames)); return !Text.IsEmpty(); }
    TArray<FString> CollectVisibleText() { return {}; }
    void WaitSlateFrames(int32 Frames) { for (int32 Index = 0; Index < Frames; ++Index) { FSlateApplication::Get().Tick(); } }
    bool SaveScreenshot(const FString& AbsolutePath)
    {
        TArray<FColor> Pixels;
        return FSlateApplication::Get().TakeScreenshot(FSlateApplication::Get().GetActiveTopLevelWindow(), Pixels, FIntRect()) && !AbsolutePath.IsEmpty();
    }
}
'@
    $sourceText = @"
#include "Misc/AutomationTest.h"
#include "Modules/ModuleManager.h"

// Product scenario source: $scenarioName
// The product scenario must register $TestName and own product-specific state setup.
IMPLEMENT_MODULE(FDefaultModuleImpl, FabCaptureHarness)
"@
    Write-FabSubmissionAtomicText -Path (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') 'FabCaptureHarness.cpp') -Text $sourceText
    return [pscustomobject]@{ HostRoot = $hostRoot; EditorPluginRoot = $pluginRoot }
}

function Get-FabCaptureCommandArgument {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string]$AutomationTestName
    )

    return @("-project=$ProjectPath", '-unattended', '-nop4', '-nosplash',
        "-ExecCmds=Automation RunTests $AutomationTestName;Quit")
}

function Invoke-FabCaptureEditor {
    param(
        [Parameter(Mandatory)] [string]$EditorPath,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $EditorPath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start Unreal Editor.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = [string]$stdout.Result; Error = [string]$stderr.Result }
    }
    finally { $process.Dispose() }
}

function Invoke-FabUnrealEditorCaptureCommand {
    $root = Assert-FabSubmissionPluginRoot -PluginPath $PluginPath
    $scenarioPath = Assert-FabCaptureScenario -Root $root -Path $ScenarioSource -TestName $AutomationTestName
    $engine = Get-FabCaptureEngineRoot -RequestedRoot $EngineRoot -Version $EngineVersion
    $base = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Join-Path ([System.IO.Path]::GetTempPath()) 'FabUnrealEditorCapture'
    }
    else { [System.IO.Path]::GetFullPath($OutputDirectory) }
    $sessionRoot = Join-Path $base "$([System.IO.Path]::GetFileName($root))\$([guid]::NewGuid().ToString('D'))"
    [System.IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
    $hostContext = New-FabCaptureHost -Root $root -EngineAssociation $EngineVersion `
        -ScenarioPath $scenarioPath -TestName $AutomationTestName -SessionRoot $sessionRoot
    $projectPath = Join-Path $hostContext.HostRoot 'FabCaptureHost.uproject'
    $arguments = @(Get-FabCaptureCommandArgument -ProjectPath $projectPath -AutomationTestName $AutomationTestName)
    $result = if ($SkipExecution) {
        [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' }
    }
    else { Invoke-FabCaptureEditor -EditorPath $engine.Editor -Arguments $arguments -WorkingDirectory $host.HostRoot }
    $report = [ordered]@{
        schemaVersion = 1
        result        = if ($result.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
        engineVersion = $EngineVersion
        automationTestName = $AutomationTestName
        normalRhi     = $true
        arguments     = $arguments
        exitCode      = $result.ExitCode
        sessionRoot   = $sessionRoot
        screenshotDirectory = (Join-Path $sessionRoot 'proof')
    }
    [System.IO.Directory]::CreateDirectory($report.screenshotDirectory) | Out-Null
    $reportPath = Join-Path $sessionRoot 'FabUnrealEditorCapture.report.json'
    Write-FabSubmissionAtomicText -Path $reportPath `
        -Text (ConvertTo-FabSubmissionJsonText -Value $report)
    if ($result.ExitCode -ne 0) {
        throw "Unreal Editor capture failed with exit code $($result.ExitCode). Report: $reportPath"
    }
    Write-Output 'CAPTURE=PASS'
    Write-Output "CAPTURE_REPORT=$reportPath"
    return [pscustomobject]@{ ReportPath = $reportPath; Report = $report; SessionRoot = $sessionRoot }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $output = @(Invoke-FabUnrealEditorCaptureCommand)
        $output | Where-Object { $_ -is [string] } | Write-Output
        exit 0
    }
    catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        Write-Output 'CAPTURE=FAIL'
        exit 1
    }
}
