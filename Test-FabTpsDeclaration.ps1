# Copyright (c) 2026 metyatech. All rights reserved.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PluginPath,

    [string]$ListingFieldsPath,

    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TpsJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not [System.IO.File]::Exists($Path)) {
        throw "$Name is missing: $Path"
    }
    $text = [System.IO.File]::ReadAllText($Path)
    try {
        return [pscustomobject]@{
            Text   = $text
            Object = ($text | ConvertFrom-Json -Depth 100)
        }
    }
    catch {
        throw "$Name is invalid JSON: $Path. $($_.Exception.Message)"
    }
}

function Get-RequiredTpsProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Required field '$Name' must contain a value."
    }
    return $property.Value
}

function Assert-TpsSchema {
    param(
        [Parameter(Mandatory)]
        [string]$JsonText,

        [Parameter(Mandatory)]
        [string]$SchemaPath,

        [Parameter(Mandatory)]
        [string]$JsonPath
    )

    try {
        $valid = $JsonText | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop
    }
    catch {
        throw "Schema validation failed for $JsonPath. $($_.Exception.Message)"
    }
    if (-not $valid) {
        throw "Schema validation failed for $JsonPath."
    }
}

function Resolve-TpsPluginFile {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "distributed_notice_file must be relative to the plugin root: $RelativePath"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $PluginRoot $RelativePath))
    $rootPrefix = "$($PluginRoot.TrimEnd('\', '/'))\"
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "distributed_notice_file must remain under the plugin root: $RelativePath"
    }
    return $candidate
}

function Get-TpsAlias {
    param(
        [Parameter(Mandatory)]
        [string]$SoftwareName
    )

    $aliases = [System.Collections.Generic.List[string]]::new()
    $aliases.Add($SoftwareName)
    foreach ($match in [regex]::Matches($SoftwareName, '\(([^()]+)\)')) {
        $alias = $match.Groups[1].Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($alias)) {
            $aliases.Add($alias)
        }
    }
    return @($aliases | Select-Object -Unique)
}

function Assert-TpsPlatform {
    param(
        [Parameter(Mandatory)]
        [object]$Declaration,

        [Parameter(Mandatory)]
        [object]$Listing,

        [Parameter(Mandatory)]
        [object]$Metadata,

        [Parameter(Mandatory)]
        [object]$Descriptor
    )

    $productPlatforms = @($Listing.platforms | ForEach-Object { [string]$_ })
    $metadataPlatforms = @($Metadata.technicalInformation.supportedTargetBuildPlatforms |
        ForEach-Object { [string]$_ })
    $descriptorPlatforms = @($Descriptor.SupportedTargetPlatforms | ForEach-Object { [string]$_ })
    foreach ($platform in @($Declaration.platforms | ForEach-Object { [string]$_ })) {
        if ($productPlatforms -cnotcontains $platform) {
            throw "Declaration platform '$platform' is not supported by FabListingFields.json."
        }
        if ($metadataPlatforms -cnotcontains $platform) {
            throw "Declaration platform '$platform' is not supported by FabSubmissionMetadata.json."
        }
        if ($descriptorPlatforms.Count -gt 0 -and $descriptorPlatforms -cnotcontains $platform) {
            throw "Declaration platform '$platform' is not supported by the plugin descriptor."
        }
    }
}

function Assert-TpsDependency {
    param(
        [Parameter(Mandatory)]
        [object]$Declaration,

        [Parameter(Mandatory)]
        [object]$Metadata
    )

    $dependencies = @($Metadata.technicalInformation.dependencies | ForEach-Object { [string]$_ })
    $aliases = @(Get-TpsAlias -SoftwareName ([string]$Declaration.software_name))
    $matchingDependencies = @($dependencies | Where-Object {
            $dependency = $_
            @($aliases | Where-Object { $dependency -match [regex]::Escape($_) }).Count -gt 0
        })
    if ($matchingDependencies.Count -eq 0) {
        throw "FabSubmissionMetadata.json dependencies do not mention '$($Declaration.software_name)'."
    }
    if (@($matchingDependencies | Where-Object { $_ -match [regex]::Escape([string]$Declaration.version) }).Count -eq 0) {
        throw "FabSubmissionMetadata.json dependencies do not mention '$($Declaration.software_name)' version '$($Declaration.version)'."
    }
    if ([bool]$Declaration.bundled -and
        @($matchingDependencies | Where-Object { $_ -match '(?i)not\s+bundled|external\s+installation' }).Count -gt 0) {
        throw "FabSubmissionMetadata.json contradicts bundled declaration for '$($Declaration.software_name)'."
    }
}

function Assert-TpsNotice {
    param(
        [Parameter(Mandatory)]
        [object]$Declaration,

        [Parameter(Mandatory)]
        [string]$NoticePath
    )

    $noticeText = [System.IO.File]::ReadAllText($NoticePath)
    $xml = [System.Xml.XmlDocument]::new()
    try {
        $xml.LoadXml($noticeText)
    }
    catch {
        throw "distributed_notice_file is not valid XML: $NoticePath. $($_.Exception.Message)"
    }
    $aliases = @(Get-TpsAlias -SoftwareName ([string]$Declaration.software_name))
    if (@($aliases | Where-Object { $noticeText -match [regex]::Escape($_) }).Count -eq 0) {
        throw "distributed_notice_file does not identify '$($Declaration.software_name)'."
    }
    if ($noticeText -notmatch [regex]::Escape([string]$Declaration.version)) {
        throw "distributed_notice_file contradicts version '$($Declaration.version)'."
    }
    if ($noticeText -notmatch [regex]::Escape([string]$Declaration.license)) {
        throw "distributed_notice_file contradicts license '$($Declaration.license)'."
    }

    $additionalInfo = $xml.TpsData.AdditionalInfo
    if ($null -ne $additionalInfo) {
        if (-not [string]::IsNullOrWhiteSpace([string]$additionalInfo.Version) -and
            [string]$additionalInfo.Version -cne [string]$Declaration.version) {
            throw "distributed_notice_file AdditionalInfo.Version contradicts declaration version."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$additionalInfo.License) -and
            [string]$additionalInfo.License -cne [string]$Declaration.license) {
            throw "distributed_notice_file AdditionalInfo.License contradicts declaration license."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$additionalInfo.Url) -and
            [string]$additionalInfo.Url -notmatch '^https://') {
            throw 'distributed_notice_file AdditionalInfo.Url must be HTTPS when present.'
        }
    }
    if ($null -ne $xml.TpsData.Eula -and
        [string]$xml.TpsData.Eula -cne [string]$Declaration.license_url) {
        throw 'distributed_notice_file Eula contradicts declaration license_url.'
    }

    if ([string]$Declaration.software_name -match '(?i)assimp') {
        if ([string]$xml.TpsData.Name -cne 'assimp' -or
            $null -eq $additionalInfo -or
            [string]$additionalInfo.Version -cne [string]$Declaration.version -or
            [string]$additionalInfo.License -cne [string]$Declaration.license) {
            throw 'Assimp name, version, or license contradicts the existing assimp.tps declaration.'
        }
    }
}

function Get-TpsBuildInfo {
    param(
        [Parameter(Mandatory)]
        [string]$NoticePath
    )

    $buildInfoPath = Join-Path (Split-Path -Parent $NoticePath) 'BUILD-INFO.json'
    if (-not [System.IO.File]::Exists($buildInfoPath)) {
        return $null
    }
    return (Get-TpsJson -Path $buildInfoPath -Name 'BUILD-INFO.json').Object
}

function Assert-TpsBuildInfo {
    param(
        [Parameter(Mandatory)]
        [object]$Declaration,

        [Parameter(Mandatory)]
        [object]$BuildInfo,

        [Parameter(Mandatory)]
        [string]$NoticePath,

        [switch]$RequireAssimpEvidence
    )

    if ($RequireAssimpEvidence) {
        foreach ($name in @(
                'Version', 'SourceRepository', 'SourceTag', 'SourceCommit',
                'Architecture', 'DistributedThirdPartyNoticeFile', 'CMakeOptions')) {
            $property = $BuildInfo.PSObject.Properties[$name]
            if ($null -eq $property -or $null -eq $property.Value -or
                [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw "Assimp BUILD-INFO.json must contain '$name'."
            }
        }
    }
    foreach ($field in @(
            @{ Declaration = 'version'; Build = 'Version' },
            @{ Declaration = 'source_repository_url'; Build = 'SourceRepository' },
            @{ Declaration = 'source_tag'; Build = 'SourceTag' },
            @{ Declaration = 'source_commit'; Build = 'SourceCommit' })) {
        if ($null -ne $BuildInfo.PSObject.Properties[$field.Build]) {
            $buildValue = [string]$BuildInfo.($field.Build)
            $declarationValue = [string]$Declaration.($field.Declaration)
            if ($field.Build -ceq 'SourceRepository') {
                $buildValue = $buildValue -replace '(?i)\.git/?$', ''
                $declarationValue = $declarationValue -replace '(?i)\.git/?$', ''
                $buildValue = $buildValue.TrimEnd('/')
                $declarationValue = $declarationValue.TrimEnd('/')
            }
            if ($buildValue -cne $declarationValue) {
                throw "BUILD-INFO.json $($field.Build) contradicts declaration $($field.Declaration)."
            }
        }
    }
    if ($null -ne $BuildInfo.PSObject.Properties['DistributedThirdPartyNoticeFile'] -and
        [string]$BuildInfo.DistributedThirdPartyNoticeFile -cne [System.IO.Path]::GetFileName($NoticePath)) {
        throw 'BUILD-INFO.json DistributedThirdPartyNoticeFile contradicts distributed_notice_file.'
    }
    if (@($Declaration.platforms | Where-Object { [string]$_ -ceq 'Win64' }).Count -gt 0 -and
        $null -ne $BuildInfo.PSObject.Properties['Architecture'] -and
        [string]$BuildInfo.Architecture -cne 'x64') {
        throw 'BUILD-INFO.json architecture contradicts Win64 declaration platform.'
    }
    $sharedOptions = @($BuildInfo.CMakeOptions | Where-Object { [string]$_.Name -ceq 'BUILD_SHARED_LIBS' })
    if ($RequireAssimpEvidence -and $sharedOptions.Count -ne 1) {
        throw 'Assimp BUILD-INFO.json must contain exactly one BUILD_SHARED_LIBS option.'
    }
    $sharedOption = $sharedOptions | Select-Object -First 1
    if ($null -ne $sharedOption) {
        $expected = if ([string]$Declaration.linkage -ceq 'dynamic') { 'ON' } else { 'OFF' }
        if ([string]$sharedOption.Value -cne $expected) {
            throw "BUILD-INFO.json BUILD_SHARED_LIBS contradicts '$($Declaration.linkage)' linkage."
        }
    }
}

function Assert-TpsIntegration {
    param(
        [Parameter(Mandatory)]
        [object]$Declaration,

        [Parameter(Mandatory)]
        [string]$NoticePath,

        [switch]$RequireAssimpEvidence
    )

    $buildScriptPath = Join-Path (Split-Path -Parent $NoticePath) 'assimp.Build.cs'
    if (-not [System.IO.File]::Exists($buildScriptPath)) {
        if ($RequireAssimpEvidence) {
            throw 'Assimp declaration requires assimp.Build.cs beside distributed_notice_file.'
        }
        return
    }
    $buildScript = [System.IO.File]::ReadAllText($buildScriptPath)
    if (@($Declaration.platforms | Where-Object { [string]$_ -ceq 'Win64' }).Count -gt 0 -and
        $buildScript -notmatch 'UnrealTargetPlatform\.Win64') {
        throw 'assimp.Build.cs does not enforce the declared Win64 platform.'
    }
    if ($RequireAssimpEvidence -and [string]$Declaration.linkage -ceq 'dynamic') {
        foreach ($member in @('PublicAdditionalLibraries', 'PublicDelayLoadDLLs', 'RuntimeDependencies')) {
            if ($buildScript -notmatch [regex]::Escape($member)) {
                throw "assimp.Build.cs does not describe dynamic linkage member '$member'."
            }
        }
    }
}

function ConvertTo-TpsArtifactDeclaration {
    param(
        [Parameter(Mandatory)]
        [object]$Declaration
    )

    $fields = @(
        'software_name', 'version', 'vendor', 'homepage_url', 'source_repository_url',
        'source_tag', 'source_commit', 'license', 'license_url', 'bundled', 'linkage',
        'platforms', 'upstream_source_modified', 'sends_data_to_creator',
        'distributed_notice_file', 'purpose', 'why_required', 'additional_information')
    $result = [ordered]@{}
    foreach ($field in $fields) {
        $result[$field] = $Declaration.$field
    }
    return $result
}

function ConvertTo-TpsSubmissionText {
    param(
        [Parameter(Mandatory)]
        [object]$Artifact
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Fab Third-Party Software Declaration')
    $lines.Add('====================================')
    $lines.Add("Product: $($Artifact.product)")
    $lines.Add("Version: $($Artifact.version)")
    $lines.Add("Fab Listing ID: $($Artifact.listing_id)")
    $lines.Add('')
    for ($index = 0; $index -lt @($Artifact.declarations).Count; $index++) {
        $declaration = @($Artifact.declarations)[$index]
        $lines.Add("Third-Party Software $($index + 1)")
        $lines.Add('-----------------------')
        $lines.Add("Software name: $($declaration.software_name)")
        $lines.Add("Version: $($declaration.version)")
        $lines.Add("Vendor: $($declaration.vendor)")
        $lines.Add("Homepage URL: $($declaration.homepage_url)")
        $lines.Add("Source repository URL: $($declaration.source_repository_url)")
        $lines.Add("Source tag: $($declaration.source_tag)")
        $lines.Add("Source commit: $($declaration.source_commit)")
        $lines.Add("License: $($declaration.license)")
        $lines.Add("License URL: $($declaration.license_url)")
        $lines.Add("Bundled: $(if ($declaration.bundled) { 'Yes' } else { 'No' })")
        $lines.Add("Linkage: $($declaration.linkage)")
        $lines.Add("Platforms: $([string]::Join(', ', @($declaration.platforms)))")
        $lines.Add("Upstream source modified: $(if ($declaration.upstream_source_modified) { 'Yes' } else { 'No' })")
        $lines.Add("Sends data to creator: $(if ($declaration.sends_data_to_creator) { 'Yes' } else { 'No' })")
        $lines.Add("Distributed notice file: $($declaration.distributed_notice_file)")
        $lines.Add("Purpose: $($declaration.purpose)")
        $lines.Add("Why required: $($declaration.why_required)")
        $lines.Add("Additional information: $($declaration.additional_information)")
        if ($index -lt @($Artifact.declarations).Count - 1) {
            $lines.Add('')
        }
    }
    return ([string]::Join("`n", $lines) + "`n")
}

try {
    $resolvedPluginPath = [System.IO.Path]::GetFullPath($PluginPath).TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($resolvedPluginPath)) {
        throw "PluginPath is not a directory: $resolvedPluginPath"
    }

    $schemaPath = Join-Path $PSScriptRoot 'FabTpsDeclarations.schema.json'
    $listingSchemaPath = Join-Path $PSScriptRoot 'FabListingFields.schema.json'
    $metadataSchemaPath = Join-Path $PSScriptRoot 'FabSubmissionMetadata.schema.json'
    foreach ($path in @($schemaPath, $listingSchemaPath, $metadataSchemaPath)) {
        if (-not [System.IO.File]::Exists($path)) {
            throw "Required schema is missing: $path"
        }
    }

    $declarationsPath = Join-Path $resolvedPluginPath 'FabTpsDeclarations.json'
    $declarationsJson = Get-TpsJson -Path $declarationsPath -Name 'FabTpsDeclarations.json'
    Assert-TpsSchema -JsonText $declarationsJson.Text -SchemaPath $schemaPath -JsonPath $declarationsPath
    $declarations = $declarationsJson.Object

    $listingPath = if ([string]::IsNullOrWhiteSpace($ListingFieldsPath)) {
        Join-Path $resolvedPluginPath 'FabListingFields.json'
    }
    else {
        [System.IO.Path]::GetFullPath($ListingFieldsPath)
    }
    $listingJson = Get-TpsJson -Path $listingPath -Name 'FabListingFields.json'
    Assert-TpsSchema -JsonText $listingJson.Text -SchemaPath $listingSchemaPath -JsonPath $listingPath
    $listing = $listingJson.Object
    $product = [string](Get-RequiredTpsProperty -Object $listing -Name 'product')
    $productVersion = [string](Get-RequiredTpsProperty -Object $listing -Name 'version')
    $listingId = [string](Get-RequiredTpsProperty -Object $listing -Name 'listing_id')

    $metadataPath = Join-Path $resolvedPluginPath 'FabSubmissionMetadata.json'
    $metadataJson = Get-TpsJson -Path $metadataPath -Name 'FabSubmissionMetadata.json'
    Assert-TpsSchema -JsonText $metadataJson.Text -SchemaPath $metadataSchemaPath -JsonPath $metadataPath
    $metadata = $metadataJson.Object
    if ([string]$metadata.product -cne $product) {
        throw 'FabSubmissionMetadata.json product contradicts FabListingFields.json product.'
    }

    $releaseConfigPath = Join-Path $resolvedPluginPath 'FabPluginRelease.json'
    $releaseConfig = (Get-TpsJson -Path $releaseConfigPath -Name 'FabPluginRelease.json').Object
    $descriptorPath = Join-Path $resolvedPluginPath ([string](Get-RequiredTpsProperty `
            -Object $releaseConfig -Name 'descriptorFile'))
    $descriptor = (Get-TpsJson -Path $descriptorPath -Name 'plugin descriptor').Object

    $artifactDeclarations = [System.Collections.Generic.List[object]]::new()
    foreach ($declaration in @($declarations.declarations)) {
        $isAssimp = [string]$declaration.software_name -match '(?i)assimp'
        $noticePath = Resolve-TpsPluginFile -PluginRoot $resolvedPluginPath `
            -RelativePath ([string]$declaration.distributed_notice_file)
        if (-not [System.IO.File]::Exists($noticePath)) {
            throw "distributed_notice_file does not exist: $($declaration.distributed_notice_file)"
        }
        Assert-TpsPlatform -Declaration $declaration -Listing $listing -Metadata $metadata -Descriptor $descriptor
        Assert-TpsDependency -Declaration $declaration -Metadata $metadata
        Assert-TpsNotice -Declaration $declaration -NoticePath $noticePath
        $buildInfo = Get-TpsBuildInfo -NoticePath $noticePath
        if ($isAssimp -and $null -eq $buildInfo) {
            throw 'Assimp declaration requires BUILD-INFO.json beside distributed_notice_file.'
        }
        if ($null -ne $buildInfo) {
            Assert-TpsBuildInfo -Declaration $declaration -BuildInfo $buildInfo -NoticePath $noticePath `
                -RequireAssimpEvidence:$isAssimp
        }
        Assert-TpsIntegration -Declaration $declaration -NoticePath $noticePath `
            -RequireAssimpEvidence:$isAssimp
        [void]$artifactDeclarations.Add((ConvertTo-TpsArtifactDeclaration -Declaration $declaration))
    }

    $artifact = [ordered]@{
        schema_version = 1
        product        = $product
        version        = $productVersion
        listing_id     = $listingId
        declarations   = @($artifactDeclarations)
    }
    $artifactObject = [pscustomobject]$artifact
    $outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Join-Path $PSScriptRoot "artifacts\$($releaseConfig.pluginName)\submission"
    }
    else {
        [System.IO.Path]::GetFullPath($OutputDirectory)
    }
    [System.IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $jsonPath = Join-Path $outputRoot 'FabTpsSubmission.json'
    $textPath = Join-Path $outputRoot 'FabTpsSubmission.txt'
    [System.IO.File]::WriteAllText($jsonPath, ($artifactObject | ConvertTo-Json -Depth 20) + "`n",
        [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($textPath, (ConvertTo-TpsSubmissionText -Artifact $artifactObject),
        [System.Text.UTF8Encoding]::new($false))
    Write-Output "Fab TPS submission JSON: $jsonPath"
    Write-Output "Fab TPS submission text: $textPath"
    Write-Output 'FAB TPS DECLARATION: PASS'
    exit 0
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    Write-Output 'FAB TPS DECLARATION: FAIL'
    exit 1
}
