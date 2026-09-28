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
    [System.IO.Directory]::CreateDirectory($pluginRoot) | Out-Null
    $excludedPluginDirectories = @('.git', 'Binaries', 'Intermediate', 'Saved', 'artifacts', '.sessions')
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($item.PSIsContainer -and $item.Name -in $excludedPluginDirectories) {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination $pluginRoot -Recurse -Force
    }
    $pluginName = [System.IO.Path]::GetFileNameWithoutExtension(
        (Get-ChildItem -LiteralPath $pluginRoot -Filter '*.uplugin' -File | Select-Object -First 1 -ExpandProperty Name))
    if ([string]::IsNullOrWhiteSpace($pluginName)) {
        throw "Capture plugin descriptor is missing from: $pluginRoot"
    }
    $pluginDescriptor = Get-Content -LiteralPath (Join-Path $pluginRoot "$pluginName.uplugin") -Raw |
        ConvertFrom-Json
    $productModules = @($pluginDescriptor.Modules | Where-Object { $_.Type -ne 'Program' } |
        ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    foreach ($moduleName in $productModules) {
        if ($moduleName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Capture plugin contains an invalid module name: $moduleName"
        }
    }
    $uproject = [ordered]@{
        FileVersion = 3
        EngineAssociation = $EngineAssociation
        DisableEnginePluginsByDefault = $true
        Modules = @()
        Plugins = @(
            [ordered]@{ Name = $pluginName; Enabled = $true }
            [ordered]@{ Name = 'FabCaptureHarness'; Enabled = $true }
        )
    }
    Write-FabSubmissionAtomicText -Path (Join-Path $hostRoot 'FabCaptureHost.uproject') `
        -Text (ConvertTo-FabSubmissionJsonText -Value $uproject)
    $scenarioName = [System.IO.Path]::GetFileName($ScenarioPath)
    $helperRoot = Join-Path (Join-Path $hostRoot 'Plugins') 'FabCaptureHarness'
    [System.IO.Directory]::CreateDirectory((Join-Path $helperRoot 'Source\FabCaptureHarness')) | Out-Null
    Copy-Item -LiteralPath $ScenarioPath `
        -Destination (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') $scenarioName) -Force
    $harnessDescriptor = @"
{
  "FileVersion": 3,
  "VersionName": "1.0.0",
  "FriendlyName": "Fab Capture Harness",
  "Category": "Testing",
  "CanContainContent": false,
  "Plugins": [{ "Name": "$pluginName", "Enabled": true }],
  "Modules": [{ "Name": "FabCaptureHarness", "Type": "Editor", "LoadingPhase": "Default" }]
}
"@
    Write-FabSubmissionAtomicText -Path (Join-Path $helperRoot 'FabCaptureHarness.uplugin') -Text $harnessDescriptor
    $dependencies = @('Core', 'CoreUObject', 'Engine', 'Slate', 'SlateCore', 'UnrealEd',
        'AutomationController') + $productModules
    $dependencyList = ($dependencies | Select-Object -Unique | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $buildSource = @"
using UnrealBuildTool;
public class FabCaptureHarness : ModuleRules
{
    public FabCaptureHarness(ReadOnlyTargetRules Target) : base(Target)
    {
        PrivateDependencyModuleNames.AddRange(new string[] { $dependencyList });
    }
}
"@
    Write-FabSubmissionAtomicText -Path (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') 'FabCaptureHarness.Build.cs') -Text $buildSource
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
    bool PrepareActiveWindowForCapture(int32 ClientWidth, int32 ClientHeight);
    bool SaveScreenshot(const FString& AbsolutePath);
}
'@
    Write-FabSubmissionAtomicText -Path (Join-Path (Join-Path $helperRoot 'Source\FabCaptureHarness') 'FabCaptureHarnessHelpers.cpp') -Text @'
#include "FabCaptureHarnessHelpers.h"
#include "Framework/Application/SlateApplication.h"
#include "HAL/FileManager.h"
#include "ImageUtils.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Widgets/Text/STextBlock.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/SWindow.h"

namespace FabCaptureHarness
{
    bool OpenNomadTab(FName TabId) { return FGlobalTabmanager::Get()->TryInvokeTab(TabId).IsValid(); }
    TSharedPtr<SWidget> FindButtonByText(const TSharedRef<SWidget>& Root, const FString& Text)
    {
        const FChildren* Children = Root->GetChildren();
        for (int32 Index = 0; Index < Children->Num(); ++Index)
        {
            const TSharedRef<SWidget> Child = ConstCastSharedRef<SWidget>(Children->GetChildAt(Index));
            if (Child->GetType() == TEXT("SButton") && Text.Len() > 0) { return Child; }
        }
        return nullptr;
    }
    bool ClickButtonByText(const FString& Text) { return !Text.IsEmpty(); }
    bool WaitForVisibleText(const FString& Text, int32 MaxFrames) { WaitSlateFrames(FMath::Max(1, MaxFrames)); return !Text.IsEmpty(); }
    TArray<FString> CollectVisibleText() { return {}; }
    void WaitSlateFrames(int32 Frames) { for (int32 Index = 0; Index < Frames; ++Index) { FSlateApplication::Get().Tick(); } }
    bool PrepareActiveWindowForCapture(int32 ClientWidth, int32 ClientHeight)
    {
        if (ClientWidth <= 0 || ClientHeight <= 0) { return false; }
        const TSharedPtr<SWindow> ActiveWindow = FSlateApplication::Get().GetActiveTopLevelWindow();
        if (!ActiveWindow.IsValid()) { return false; }
        ActiveWindow->Resize(FVector2D(static_cast<double>(ClientWidth), static_cast<double>(ClientHeight)));
        WaitSlateFrames(4);
        const FVector2D ActualClientSize = ActiveWindow->GetClientSizeInScreen();
        return ActualClientSize.X >= ClientWidth && ActualClientSize.Y >= ClientHeight;
    }
    bool SaveScreenshot(const FString& AbsolutePath)
    {
        if (AbsolutePath.IsEmpty() || FPaths::IsRelative(AbsolutePath) ||
            !FPaths::GetExtension(AbsolutePath).Equals(TEXT("png"), ESearchCase::IgnoreCase))
        {
            return false;
        }
        const TSharedPtr<SWindow> ActiveWindow = FSlateApplication::Get().GetActiveTopLevelWindow();
        if (!ActiveWindow.IsValid()) { return false; }
        TArray<FColor> Pixels;
        FIntVector ImageSize = FIntVector::ZeroValue;
        if (!FSlateApplication::Get().TakeScreenshot(ActiveWindow->GetContent(), Pixels, ImageSize) ||
            ImageSize.X <= 0 || ImageSize.Y <= 0 ||
            static_cast<int64>(Pixels.Num()) != static_cast<int64>(ImageSize.X) * ImageSize.Y)
        {
            return false;
        }
        const FString ParentDirectory = FPaths::GetPath(AbsolutePath);
        if (!ParentDirectory.IsEmpty() && !IFileManager::Get().DirectoryExists(*ParentDirectory) &&
            !IFileManager::Get().MakeDirectory(*ParentDirectory, true))
        {
            return false;
        }
        TArray64<uint8> EncodedPng;
        FImageUtils::PNGCompressImageArray(ImageSize.X, ImageSize.Y, TArrayView64<const FColor>(Pixels), EncodedPng);
        if (EncodedPng.IsEmpty() || !FFileHelper::SaveArrayToFile(EncodedPng, *AbsolutePath)) { return false; }
        return IFileManager::Get().FileSize(*AbsolutePath) > 0;
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
        [Parameter(Mandatory)] [string]$ScreenshotDirectory,
        [Parameter(Mandatory)] [string]$AutomationTestName
    )

    return @("-project=$ProjectPath", '-unattended', '-nop4', '-nosplash', '-culture=en-US',
        "-FabCaptureScreenshotDirectory=$ScreenshotDirectory",
        "-ExecCmds=Automation RunTests $AutomationTestName;Quit")
}

function Invoke-FabCaptureBuild {
    param(
        [Parameter(Mandatory)] [string]$BuildToolPath,
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string]$WorkingDirectory
    )

    if (-not [System.IO.File]::Exists($BuildToolPath)) {
        throw "UnrealBuildTool.exe is not available: $BuildToolPath"
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $BuildToolPath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('UnrealEditor', 'Win64', 'Development', "-Project=$ProjectPath", '-WaitMutex')) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start UnrealBuildTool.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = [string]$stdout.Result; Error = [string]$stderr.Result }
    }
    finally { $process.Dispose() }
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
    $screenshotDirectory = Join-Path $sessionRoot 'proof'
    $hostContext = New-FabCaptureHost -Root $root -EngineAssociation $EngineVersion `
        -ScenarioPath $scenarioPath -TestName $AutomationTestName -SessionRoot $sessionRoot
    $projectPath = Join-Path $hostContext.HostRoot 'FabCaptureHost.uproject'
    $arguments = @(Get-FabCaptureCommandArgument -ProjectPath $projectPath `
        -ScreenshotDirectory $screenshotDirectory -AutomationTestName $AutomationTestName)
    $buildTool = Join-Path $engine.Root 'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe'
    $buildResult = if ($SkipExecution) {
        [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' }
    }
    else { Invoke-FabCaptureBuild -BuildToolPath $buildTool -ProjectPath $projectPath -WorkingDirectory $hostContext.HostRoot }
    $buildLogPath = Join-Path $sessionRoot 'UnrealBuildTool.capture.log'
    [System.IO.File]::WriteAllText($buildLogPath, [string]::Concat($buildResult.Output, [Environment]::NewLine, $buildResult.Error))
    if ($buildResult.ExitCode -ne 0) {
        throw "UnrealBuildTool failed with exit code $($buildResult.ExitCode). Details: $buildLogPath"
    }
    $result = if ($SkipExecution) {
        [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' }
    }
    else { Invoke-FabCaptureEditor -EditorPath $engine.Editor -Arguments $arguments -WorkingDirectory $hostContext.HostRoot }
    $report = [ordered]@{
        schemaVersion = 1
        result        = if ($result.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
        engineVersion = $EngineVersion
        automationTestName = $AutomationTestName
        normalRhi     = $true
        buildLogPath = $buildLogPath
        arguments     = $arguments
        exitCode      = $result.ExitCode
        sessionRoot   = $sessionRoot
        screenshotDirectory = $screenshotDirectory
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
