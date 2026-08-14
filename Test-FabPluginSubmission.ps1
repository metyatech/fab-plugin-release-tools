# Copyright (c) 2026 metyatech. All rights reserved.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [string]$PackageZipPath,

    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SubmissionJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Required JSON file is missing: $Path"
    }
    try {
        return [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "JSON file is invalid: $Path. $($_.Exception.Message)"
    }
}

function Assert-SubmissionText {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Submission metadata field '$Name' must contain a value."
    }
}

function ConvertTo-StringArray {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$AllowEmpty
    )

    if ($Value -is [string] -or $null -eq $Value) {
        throw "Submission metadata field '$Name' must be an array."
    }
    $items = @($Value | ForEach-Object { [string]$_ })
    if (-not $AllowEmpty -and $items.Count -eq 0) {
        throw "Submission metadata field '$Name' must contain at least one item."
    }
    if (@($items | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "Submission metadata field '$Name' must not contain empty items."
    }
    return $items
}

function Get-ModuleRecord {
    param(
        [Parameter(Mandatory)]
        [object]$Descriptor,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $modules = @($Descriptor.Modules | Where-Object {
            @($Configuration.distributionModules) -contains [string]$_.Name
        })
    if ($modules.Count -eq 0) {
        throw 'No distribution modules were found in the plugin descriptor.'
    }
    return $modules
}

function Get-CppClassCount {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object[]]$ModuleRecords
    )

    $count = 0
    foreach ($module in $ModuleRecords) {
        $moduleRoot = Join-Path $PluginRoot "Source\$($module.Name)"
        if (-not [System.IO.Directory]::Exists($moduleRoot)) {
            throw "Distribution module source directory is missing: Source/$($module.Name)"
        }
        $files = @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -File -Include '*.h', '*.hh', '*.hpp') |
            Where-Object { $_.FullName -notmatch '[\\/]Tests?[\\/]' }
        foreach ($file in $files) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $count += [regex]::Matches($text, '(?m)^\s*UCLASS\b').Count
        }
    }
    return $count
}

function Get-BlueprintAssetCount {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot
    )

    $count = 0
    $contentRoot = Join-Path $PluginRoot 'Content'
    if (-not [System.IO.Directory]::Exists($contentRoot)) {
        return 0
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $contentRoot -Recurse -File -Filter '*.uasset')) {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match '(?i)Blueprint(?:GeneratedClass|Class|Widget)') {
            $count++
        }
    }
    return $count
}

function Test-SubmissionUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "$Name must be an absolute HTTPS URL: $Url"
    }
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -MaximumRedirection 5 -TimeoutSec 30 `
            -SkipHttpErrorCheck
    }
    catch {
        throw "$Name was not reachable: $Url. $($_.Exception.Message)"
    }
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -gt 399) {
        throw "$Name returned HTTP $($response.StatusCode): $Url"
    }
}

function Get-HardcodedPluginLocationFinding {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.Directory]::Exists($SourceRoot)) {
        return $findings.ToArray()
    }
    $files = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Include '*.h', '*.hh', '*.hpp', '*.cpp', '*.cc', '*.cxx')
    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($text, '(?is)(?:ProjectPluginsDir|EnginePluginsDir)\s*\(\s*\)[^;]{0,300};')) {
            $block = $match.Value
            if ($block -match '(?i)FindPlugin\s*\(') {
                continue
            }
            if ($block -match '(?i)TEXT\s*\(\s*"[^"]*[\\/][^"]*"\s*\)' -or
                $block -match '(?i)TEXT\s*\(\s*"[^"]+"\s*\)') {
                $relative = [System.IO.Path]::GetRelativePath($SourceRoot, $file.FullName).Replace('\', '/')
                $findings.Add("${relative}: $($block.Trim())")
            }
        }
    }
    return $findings.ToArray()
}

function Get-LicenseInventory {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $standalone = [System.Collections.Generic.List[string]]::new()
        $tps = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $name = [System.IO.Path]::GetFileName($entry.FullName)
            if ($name -match '(?i)^(?:LICENSE|LICENCE|COPYING|NOTICE|THIRD_PARTY_NOTICES)(?:[._-].*)?$') {
                $standalone.Add($entry.FullName)
            }
            elseif ($name -match '(?i)\.tps$') {
                $tps.Add($entry.FullName)
            }
        }
        return [pscustomobject]@{
            StandaloneLicenseFiles = @($standalone | Sort-Object)
            TpsFiles               = @($tps | Sort-Object)
        }
    }
    finally {
        $archive.Dispose()
    }
}

function ConvertTo-TechnicalInformationText {
    param(
        [Parameter(Mandatory)]
        [object]$Metadata
    )

    $technical = $Metadata.technicalInformation
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Product: $($Metadata.product)")
    $lines.Add('')
    $lines.Add('Features')
    foreach ($feature in @($technical.features)) { $lines.Add("- $feature") }
    $lines.Add('')
    $lines.Add('Code Modules')
    foreach ($module in @($technical.codeModules)) {
        $lines.Add("- $($module.name) ($($module.type)): $($module.description)")
    }
    $lines.Add('')
    $lines.Add("Number of Blueprints: $($technical.numberOfBlueprints)")
    $lines.Add("Number of C++ Classes: $($technical.numberOfCppClasses)")
    $lines.Add("Network Replicated: $($technical.networkReplicated)")
    $lines.Add("Network Replication Notes: $($technical.networkReplicationNotes)")
    $lines.Add("Supported Development Platforms: $([string]::Join(', ', @($technical.supportedDevelopmentPlatforms)))")
    $lines.Add("Supported Target Build Platforms: $([string]::Join(', ', @($technical.supportedTargetBuildPlatforms)))")
    $lines.Add("Dependencies: $([string]::Join(', ', @($technical.dependencies)))")
    $lines.Add("Prerequisites: $([string]::Join(', ', @($technical.prerequisites)))")
    $lines.Add("Documentation: $($technical.documentationUrl)")
    $example = if ($null -eq $technical.exampleProjectUrl) { 'Not applicable' } else { [string]$technical.exampleProjectUrl }
    $lines.Add("Example Project: $example — $($technical.exampleProjectNotes)")
    $lines.Add("Additional Notes: $($technical.additionalNotes)")
    return ([string]::Join("`n", $lines) + "`n")
}

try {
    $resolvedPluginPath = [System.IO.Path]::GetFullPath($PluginPath).TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($resolvedPluginPath)) {
        throw "PluginPath is not a directory: $resolvedPluginPath"
    }
    $config = Get-SubmissionJson -Path (Join-Path $resolvedPluginPath 'FabPluginRelease.json')
    $metadataPath = Join-Path $resolvedPluginPath 'FabSubmissionMetadata.json'
    $metadataJson = [System.IO.File]::ReadAllText($metadataPath)
    if (-not ($metadataJson | Test-Json -SchemaFile (Join-Path $PSScriptRoot 'FabSubmissionMetadata.schema.json') -ErrorAction Stop)) {
        throw "FabSubmissionMetadata.json does not conform to FabSubmissionMetadata.schema.json: $metadataPath"
    }
    $metadata = $metadataJson | ConvertFrom-Json -Depth 100
    $descriptor = Get-SubmissionJson -Path (Join-Path $resolvedPluginPath $config.descriptorFile)
    $modules = @(Get-ModuleRecord -Descriptor $descriptor -Configuration $config)
    $metadataModules = @($metadata.technicalInformation.codeModules)
    if ($metadataModules.Count -ne $modules.Count) {
        throw 'technicalInformation.codeModules must match the shipped distribution modules.'
    }
    foreach ($module in $modules) {
        $metadataModule = $metadataModules | Where-Object { $_.name -ceq [string]$module.Name }
        if ($null -eq $metadataModule -or [string]$metadataModule.type -cne [string]$module.Type) {
            throw "technicalInformation.codeModules does not match descriptor module '$($module.Name)'."
        }
    }
    if ([string]$metadata.technicalInformation.documentationUrl -cne [string]$config.documentationUrl) {
        throw 'technicalInformation.documentationUrl must match FabPluginRelease.json.documentationUrl.'
    }
    $targetPlatforms = ConvertTo-StringArray -Value $metadata.technicalInformation.supportedTargetBuildPlatforms `
        -Name 'supportedTargetBuildPlatforms'
    $configuredPlatforms = ConvertTo-StringArray -Value $config.platforms -Name 'platforms'
    if ([string]::Join("`n", $targetPlatforms) -cne [string]::Join("`n", $configuredPlatforms)) {
        throw 'technicalInformation.supportedTargetBuildPlatforms must match FabPluginRelease.json.platforms.'
    }
    [void](ConvertTo-StringArray -Value $metadata.technicalInformation.features -Name 'features')
    [void](ConvertTo-StringArray -Value $metadata.technicalInformation.dependencies -Name 'dependencies' -AllowEmpty)
    [void](ConvertTo-StringArray -Value $metadata.technicalInformation.prerequisites -Name 'prerequisites' -AllowEmpty)
    Assert-SubmissionText -Object $metadata.technicalInformation -Name 'networkReplicationNotes'
    Assert-SubmissionText -Object $metadata.technicalInformation -Name 'exampleProjectNotes'
    Assert-SubmissionText -Object $metadata.technicalInformation -Name 'additionalNotes'
    if ($null -eq $metadata.technicalInformation.exampleProjectUrl -and
        $metadata.technicalInformation.exampleProjectNotes -notmatch '(?i)not\s+(?:applicable|needed|required)|no\s+example') {
        throw 'exampleProjectNotes must explain why exampleProjectUrl is null.'
    }
    if ([int]$metadata.technicalInformation.numberOfCppClasses -ne (Get-CppClassCount `
                -PluginRoot $resolvedPluginPath -ModuleRecords $modules)) {
        throw 'numberOfCppClasses must equal UCLASS declarations in shipped distribution modules.'
    }
    if ([int]$metadata.technicalInformation.numberOfBlueprints -ne (Get-BlueprintAssetCount -PluginRoot $resolvedPluginPath)) {
        throw 'numberOfBlueprints must equal Blueprint assets in the shipped Content tree.'
    }
    Test-SubmissionUrl -Url ([string]$metadata.technicalInformation.documentationUrl) -Name 'documentationUrl'
    if ($null -ne $metadata.technicalInformation.exampleProjectUrl) {
        Test-SubmissionUrl -Url ([string]$metadata.technicalInformation.exampleProjectUrl) -Name 'exampleProjectUrl'
    }

    $hardcodedLocations = @(Get-HardcodedPluginLocationFinding -SourceRoot (Join-Path $resolvedPluginPath 'Source'))
    if ($hardcodedLocations.Count -gt 0) {
        throw "Hardcoded plugin location detected:`n$($hardcodedLocations -join "`n")"
    }

    $licenseInventory = [pscustomobject]@{
        StandaloneLicenseFiles = @()
        TpsFiles               = @()
    }
    if (-not [string]::IsNullOrWhiteSpace($PackageZipPath)) {
        $resolvedZipPath = [System.IO.Path]::GetFullPath($PackageZipPath)
        if (-not [System.IO.File]::Exists($resolvedZipPath)) {
            throw "Package ZIP is missing: $resolvedZipPath"
        }
        $licenseInventory = Get-LicenseInventory -ZipPath $resolvedZipPath
        if ($licenseInventory.StandaloneLicenseFiles.Count -gt 0) {
            Write-Warning ("Review Required: standalone license-related files are present in the package: {0}" -f
                ([string]::Join(', ', $licenseInventory.StandaloneLicenseFiles)))
        }
        if ($licenseInventory.TpsFiles.Count -gt 0) {
            Write-Warning ("Third Party Software metadata (.tps), reported separately: {0}" -f
                ([string]::Join(', ', $licenseInventory.TpsFiles)))
        }
    }

    $outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Join-Path $PSScriptRoot "artifacts\$($config.pluginName)\submission"
    }
    else {
        [System.IO.Path]::GetFullPath($OutputDirectory)
    }
    [System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $textPath = Join-Path $outputRoot 'FabTechnicalInformation.txt'
    [System.IO.File]::WriteAllText($textPath, (ConvertTo-TechnicalInformationText -Metadata $metadata),
        [System.Text.UTF8Encoding]::new($false))
    Write-Output "Fab Technical Information: $textPath"
    if ($PackageZipPath) {
        Write-Output "Standalone license-related files: $($licenseInventory.StandaloneLicenseFiles.Count) (Review Required only)"
        Write-Output "Third Party Software metadata files (.tps): $($licenseInventory.TpsFiles.Count)"
    }
    Write-Output 'FAB SUBMISSION CHECK: PASS'
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    Write-Output 'FAB SUBMISSION CHECK: FAIL'
    exit 1
}
