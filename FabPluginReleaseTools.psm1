# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '0.1.2'
$script:MaximumPackageBytes = 15L * 1024L * 1024L * 1024L
$script:CopyrightExtensions = @('.h', '.hh', '.hpp', '.inl', '.ipp', '.cpp', '.cc', '.cxx')
$script:ForbiddenTopLevelDirectories = @('Binaries', 'Build', 'Intermediate', 'Saved', 'DerivedDataCache')
$script:ForbiddenPathElements = @('Test', 'Tests', 'Sample', 'Samples', 'Example', 'Examples')
$script:ForbiddenExtensions = @('.pdb', '.obj', '.sln', '.vcxproj', '.vcxproj.filters', '.user')
$script:ForbiddenNames = @('.DS_Store', 'Thumbs.db', 'FabPluginRelease.json', '.tasks.jsonl', 'AGENTS.md', 'agent-ruleset.json')

function Test-IsDescendantPath {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Candidate
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $resolvedCandidate = [System.IO.Path]::GetFullPath($Candidate).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $resolvedCandidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemInfo]$Item
    )

    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points, symbolic links, and junctions are not allowed: $($Item.FullName)"
    }
}

function Assert-FabAbsoluteDirectoryPathChain {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.Directory]::Exists($resolvedPath)) {
        throw "Absolute path is not an existing directory: $resolvedPath"
    }

    $pathRoot = [System.IO.Path]::GetPathRoot($resolvedPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot) -or
        -not [System.IO.Directory]::Exists($pathRoot)) {
        throw 'Absolute path volume or UNC share root is missing.'
    }

    Assert-NoReparsePoint -Item ([System.IO.DirectoryInfo]::new($pathRoot))
    $relativePath = [System.IO.Path]::GetRelativePath($pathRoot, $resolvedPath)
    if ($relativePath -ceq '.') {
        return
    }

    $segments = @($relativePath.Split(
            [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
            [System.StringSplitOptions]::RemoveEmptyEntries))
    $currentPath = $pathRoot
    foreach ($segment in $segments) {
        $currentPath = [System.IO.Path]::Combine($currentPath, $segment)
        if (-not [System.IO.Directory]::Exists($currentPath)) {
            throw "Absolute path directory element does not exist: $currentPath"
        }
        Assert-NoReparsePoint -Item ([System.IO.DirectoryInfo]::new($currentPath))
    }
}

function Assert-FabPathChain {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Candidate
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolvedCandidate = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    if (-not $resolvedCandidate.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not (Test-IsDescendantPath -Root $resolvedRoot -Candidate $resolvedCandidate)) {
        throw 'Candidate path must be the validated root or one of its descendants.'
    }
    if (-not [System.IO.Directory]::Exists($resolvedRoot)) {
        throw "Validated path root is not an existing directory: $resolvedRoot"
    }

    Assert-NoReparsePoint -Item ([System.IO.DirectoryInfo]::new($resolvedRoot))
    if ($resolvedCandidate.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $resolvedCandidate)
    $segments = @($relativePath.Split(
            [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
            [System.StringSplitOptions]::RemoveEmptyEntries))
    $currentPath = $resolvedRoot
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $currentPath = [System.IO.Path]::Combine($currentPath, $segments[$index])
        if ([System.IO.Directory]::Exists($currentPath)) {
            Assert-NoReparsePoint -Item ([System.IO.DirectoryInfo]::new($currentPath))
            continue
        }
        if ([System.IO.File]::Exists($currentPath)) {
            if ($index -ne $segments.Count - 1) {
                throw "A file appears where a path directory is required: $currentPath"
            }
            Assert-NoReparsePoint -Item ([System.IO.FileInfo]::new($currentPath))
            continue
        }
        throw "Path element does not exist: $currentPath"
    }
}

function Remove-SafeDirectory {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SessionRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Refusing to remove an empty path.'
    }
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedSessionRoot = [System.IO.Path]::GetFullPath($SessionRoot).TrimEnd('\', '/')
    if ($resolvedPath.TrimEnd('\', '/') -eq $resolvedSessionRoot) {
        throw "Refusing to remove the session root itself: $resolvedPath"
    }
    if (-not (Test-IsDescendantPath -Root $resolvedSessionRoot -Candidate $resolvedPath)) {
        throw "Refusing to remove a path outside the current session: $resolvedPath"
    }
    if ([System.IO.Path]::GetPathRoot($resolvedPath).TrimEnd('\', '/') -eq $resolvedPath.TrimEnd('\', '/')) {
        throw "Refusing to remove a drive root: $resolvedPath"
    }
    if (-not [System.IO.Directory]::Exists($resolvedPath)) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($resolvedPath, 'Recursively remove validated session child directory')) {
        return
    }
    foreach ($file in [System.IO.Directory]::EnumerateFiles(
            $resolvedPath, '*', [System.IO.SearchOption]::AllDirectories)) {
        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal)
    }
    [System.IO.Directory]::Delete($resolvedPath, $true)
    if ([System.IO.Directory]::Exists($resolvedPath)) {
        throw "Failed to remove directory: $resolvedPath"
    }
}

function Remove-SessionDirectory {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$SessionRoot
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($SessionRoot)
    if (-not [System.IO.Directory]::Exists($resolvedRoot)) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($resolvedRoot, 'Remove validated session directory contents and empty root')) {
        return
    }
    foreach ($child in [System.IO.Directory]::EnumerateDirectories($resolvedRoot)) {
        Remove-SafeDirectory -Path $child -SessionRoot $resolvedRoot -Confirm:$false
    }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($resolvedRoot)) {
        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($file)
    }
    [System.IO.Directory]::Delete($resolvedRoot, $false)
    if ([System.IO.Directory]::Exists($resolvedRoot)) {
        throw "Failed to remove session directory: $resolvedRoot"
    }
}

function ConvertTo-NormalizedRelativePath {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -ne $Path.TrimEnd()) {
        throw "$PropertyName contains an empty path or trailing whitespace: '$Path'"
    }
    if ([System.IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\') -or
        $Path.StartsWith('/') -or $Path -match '^[A-Za-z]:') {
        throw "$PropertyName must contain relative paths only: '$Path'"
    }
    if ($Path.IndexOfAny([char[]]'*?[]') -ge 0) {
        throw "$PropertyName must not contain wildcard characters: '$Path'"
    }
    if ($Path.IndexOfAny([char[]]'<>:"|') -ge 0) {
        throw "$PropertyName contains characters that are invalid on Windows: '$Path'"
    }
    $normalized = $Path.Replace('\', '/').Trim('/')
    $segments = @($normalized.Split('/'))
    if ($segments.Count -eq 0 -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
        throw "$PropertyName contains an unsafe path segment: '$Path'"
    }
    return [string]::Join('/', $segments)
}

function Assert-UniqueStringSet {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Values,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [switch]$CaseSensitive
    )

    $comparison = if ($CaseSensitive) {
        [System.StringComparer]::Ordinal
    }
    else {
        [System.StringComparer]::OrdinalIgnoreCase
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparison)
    foreach ($value in $Values) {
        $text = [string]$value
        if (-not $seen.Add($text)) {
            throw "$PropertyName contains a duplicate value: '$text'"
        }
    }
}

function Assert-ExactStringSet {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Actual,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $actualSorted = @($Actual | Sort-Object -CaseSensitive)
    $expectedSorted = @($Expected | Sort-Object -CaseSensitive)
    if ([string]::Join("`n", $actualSorted) -cne [string]::Join("`n", $expectedSorted)) {
        throw "$Description mismatch. Expected: [$($expectedSorted -join ', ')]. Actual: [$($actualSorted -join ', ')]."
    }
}

function Test-ContainsStringOrdinalIgnoreCase {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Values,

        [Parameter(Mandatory)]
        [string]$Value
    )

    foreach ($candidate in $Values) {
        if ($candidate.Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Assert-HttpsUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "$PropertyName must be an absolute HTTPS URL without user information."
    }
}

function ConvertTo-FabSafeReportUri {
    param(
        [Parameter(Mandatory)]
        [System.Uri]$Uri
    )

    if (-not $Uri.IsAbsoluteUri) {
        throw 'Report URI must be absolute.'
    }
    $builder = [System.UriBuilder]::new($Uri)
    $builder.UserName = ''
    $builder.Password = ''
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri.AbsoluteUri
}

function ConvertTo-FabSafeGitRemote {
    param(
        [Parameter(Mandatory)]
        [string]$Remote
    )

    if ($Remote -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        $uri = $null
        if ([System.Uri]::TryCreate($Remote, [System.UriKind]::Absolute, [ref]$uri)) {
            return ConvertTo-FabSafeReportUri -Uri $uri
        }
        return '[invalid absolute URI remote omitted]'
    }
    return $Remote
}

function ConvertTo-NormalizedPathArray {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Values,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    $result = @($Values | ForEach-Object {
            ConvertTo-NormalizedRelativePath -Path ([string]$_) -PropertyName $PropertyName
        })
    Assert-UniqueStringSet -Values $result -PropertyName $PropertyName
    return ,$result
}

function Import-FabPluginReleaseConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$EngineVersion,

        [string]$SchemaPath = (Join-Path $PSScriptRoot 'FabPluginRelease.schema.json')
    )

    if (-not [System.IO.File]::Exists($ConfigPath)) {
        throw "Configuration file is missing: $ConfigPath"
    }
    $json = [System.IO.File]::ReadAllText($ConfigPath)
    try {
        $configuration = $json | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Configuration is not valid JSON: $ConfigPath. $($_.Exception.Message)"
    }
    if (-not ($json | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw "Configuration does not conform to FabPluginRelease.schema.json: $ConfigPath"
    }

    if ($configuration.schemaVersion -isnot [long] -and $configuration.schemaVersion -isnot [int]) {
        throw 'schemaVersion must be the integer 1.'
    }
    if ($configuration.schemaVersion -ne 1) {
        throw 'schemaVersion must be 1.'
    }
    if ([string]$configuration.pluginName -cnotmatch '^[0-9A-Za-z][0-9A-Za-z_]*$') {
        throw 'pluginName must start with an ASCII letter or digit and contain only letters, digits, and underscores.'
    }
    $configuration.descriptorFile = ConvertTo-NormalizedRelativePath `
        -Path ([string]$configuration.descriptorFile) -PropertyName 'descriptorFile'
    if ([string]$configuration.descriptorFile -cne "$($configuration.pluginName).uplugin") {
        throw 'descriptorFile must exactly match <pluginName>.uplugin.'
    }

    $engineVersions = @($configuration.engineVersions | ForEach-Object { [string]$_ })
    if ($engineVersions.Count -eq 0) {
        throw 'engineVersions must not be empty.'
    }
    Assert-UniqueStringSet -Values $engineVersions -PropertyName 'engineVersions' -CaseSensitive
    foreach ($configuredVersion in $engineVersions) {
        if ($configuredVersion -cnotmatch '^5\.[0-9]+$') {
            throw "engineVersions contains an invalid Unreal Engine version: '$configuredVersion'"
        }
    }
    if ($engineVersions -cnotcontains $EngineVersion) {
        throw "EngineVersion '$EngineVersion' is not allowed by engineVersions."
    }
    $configuration.engineVersions = $engineVersions

    $platforms = @($configuration.platforms | ForEach-Object { [string]$_ })
    if ($platforms.Count -ne 1 -or $platforms[0] -cne 'Win64') {
        throw 'platforms must be exactly ["Win64"] for schemaVersion 1.'
    }
    $configuration.platforms = $platforms

    $distributionModules = @($configuration.distributionModules | ForEach-Object { [string]$_ })
    if ($distributionModules.Count -eq 0 -or $distributionModules -contains '') {
        throw 'distributionModules must contain at least one non-empty module name.'
    }
    Assert-UniqueStringSet -Values $distributionModules -PropertyName 'distributionModules'
    $configuration.distributionModules = $distributionModules

    $dependencies = @($configuration.enabledPluginDependencies | ForEach-Object { [string]$_ })
    if ($dependencies -contains '') {
        throw 'enabledPluginDependencies must not contain an empty name.'
    }
    Assert-UniqueStringSet -Values $dependencies -PropertyName 'enabledPluginDependencies'
    $configuration.enabledPluginDependencies = $dependencies

    if ($null -ne $configuration.listingId -and
        [string]$configuration.listingId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'listingId must be null or a lowercase UUID.'
    }
    Assert-HttpsUrl -Url ([string]$configuration.publisher.url) -PropertyName 'publisher.url'
    Assert-HttpsUrl -Url ([string]$configuration.documentationUrl) -PropertyName 'documentationUrl'
    Assert-HttpsUrl -Url ([string]$configuration.supportUrl) -PropertyName 'supportUrl'

    if ([string]$configuration.content.mode -cnotin @('pack', 'none')) {
        throw 'content.mode must be pack or none.'
    }
    if ($configuration.content.mode -ceq 'pack') {
        if ($configuration.content.packFolder -cne $configuration.pluginName) {
            throw 'content.packFolder must exactly match pluginName in pack mode.'
        }
    }
    elseif ($null -ne $configuration.content.PSObject.Properties['packFolder']) {
        throw 'content.packFolder is forbidden in none mode.'
    }

    foreach ($propertyName in @(
            'includeDirectories',
            'includeFiles',
            'requiredPackageFiles',
            'customDistributionPaths')) {
        $configuration.$propertyName = ConvertTo-NormalizedPathArray `
            -Values @($configuration.$propertyName) -PropertyName $propertyName
    }
    $licenseRoots = [System.Collections.Generic.List[string]]::new()
    foreach ($licenseSet in @($configuration.thirdPartyLicenseSets)) {
        $licenseSet.root = ConvertTo-NormalizedRelativePath `
            -Path ([string]$licenseSet.root) -PropertyName 'thirdPartyLicenseSets.root'
        $licenseRoots.Add([string]$licenseSet.root)
        $licenseSet.files = ConvertTo-NormalizedPathArray `
            -Values @($licenseSet.files) -PropertyName 'thirdPartyLicenseSets.files'
    }
    Assert-UniqueStringSet -Values $licenseRoots.ToArray() -PropertyName 'thirdPartyLicenseSets.root'

    $directories = @($configuration.includeDirectories)
    for ($leftIndex = 0; $leftIndex -lt $directories.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $directories.Count; $rightIndex++) {
            $left = $directories[$leftIndex].TrimEnd('/') + '/'
            $right = $directories[$rightIndex].TrimEnd('/') + '/'
            if ($left.StartsWith($right, [System.StringComparison]::OrdinalIgnoreCase) -or
                $right.StartsWith($left, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "includeDirectories contains parent/child overlap: '$($directories[$leftIndex])' and '$($directories[$rightIndex])'"
            }
        }
    }
    foreach ($filePath in @($configuration.includeFiles)) {
        foreach ($directoryPath in $directories) {
            $prefix = $directoryPath.TrimEnd('/') + '/'
            if ($filePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "includeFiles path '$filePath' is already included by directory '$directoryPath'."
            }
        }
    }

    $compiledForbiddenPatterns = @()
    foreach ($pattern in @($configuration.forbiddenPackagePatterns) + @($configuration.buildLogFailPatterns)) {
        try {
            $compiledForbiddenPatterns += [regex]::new(
                [string]$pattern,
                [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        }
        catch {
            throw "Configuration contains an invalid regular expression '$pattern': $($_.Exception.Message)"
        }
    }
    Add-Member -InputObject $configuration -NotePropertyName CompiledForbiddenPatterns `
        -NotePropertyValue @($compiledForbiddenPatterns | Select-Object -First @($configuration.forbiddenPackagePatterns).Count)
    Add-Member -InputObject $configuration -NotePropertyName CompiledBuildLogFailPatterns `
        -NotePropertyValue @($compiledForbiddenPatterns | Select-Object -Skip @($configuration.forbiddenPackagePatterns).Count)
    return $configuration
}

function Invoke-NativeProcessCapture {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList,

        [string]$WorkingDirectory = $PWD.Path
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start process: $FileName"
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [System.Threading.Tasks.Task]::WaitAll(@($standardOutput, $standardError))
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $standardOutput.Result.TrimEnd("`r", "`n")
            StdErr   = $standardError.Result.TrimEnd("`r", "`n")
        }
        if ($result.ExitCode -ne 0) {
            throw "Process failed with exit code $($result.ExitCode): $FileName $($ArgumentList -join ' '). $($result.StdErr)"
        }
        return $result
    }
    finally {
        $process.Dispose()
    }
}

function Get-GitRepositoryInformation {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath
    )

    $resolvedPluginPath = [System.IO.Path]::GetFullPath($PluginPath).TrimEnd('\', '/')
    if (-not [System.IO.Directory]::Exists($resolvedPluginPath)) {
        throw "PluginPath is not a directory: $resolvedPluginPath"
    }
    Assert-FabAbsoluteDirectoryPathChain -Path $resolvedPluginPath
    $rootResult = Invoke-NativeProcessCapture -FileName 'git.exe' `
        -ArgumentList @('-C', $resolvedPluginPath, 'rev-parse', '--show-toplevel')
    $repositoryRoot = [System.IO.Path]::GetFullPath($rootResult.StdOut).TrimEnd('\', '/')
    if (-not $repositoryRoot.Equals($resolvedPluginPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PluginPath must exactly match the Git repository root. Root: $repositoryRoot"
    }

    $gitDirectoryResult = Invoke-NativeProcessCapture -FileName 'git.exe' `
        -ArgumentList @('-C', $resolvedPluginPath, 'rev-parse', '--absolute-git-dir')
    $gitDirectory = [System.IO.Path]::GetFullPath($gitDirectoryResult.StdOut)
    $operationMarkers = @(
        (Join-Path $gitDirectory 'MERGE_HEAD'),
        (Join-Path $gitDirectory 'CHERRY_PICK_HEAD'),
        (Join-Path $gitDirectory 'rebase-apply'),
        (Join-Path $gitDirectory 'rebase-merge')
    )
    foreach ($marker in $operationMarkers) {
        if ([System.IO.File]::Exists($marker) -or [System.IO.Directory]::Exists($marker)) {
            throw "Git repository has an in-progress merge, rebase, or cherry-pick: $marker"
        }
    }

    $status = Invoke-NativeProcessCapture -FileName 'git.exe' `
        -ArgumentList @('-C', $resolvedPluginPath, 'status', '--porcelain=v1', '--untracked-files=all')
    if (-not [string]::IsNullOrWhiteSpace($status.StdOut)) {
        throw "Git working tree must be completely clean (tracked and untracked files):`n$($status.StdOut)"
    }
    $head = Invoke-NativeProcessCapture -FileName 'git.exe' `
        -ArgumentList @('-C', $resolvedPluginPath, 'rev-parse', 'HEAD')
    $branch = Invoke-NativeProcessCapture -FileName 'git.exe' `
        -ArgumentList @('-C', $resolvedPluginPath, 'branch', '--show-current')
    $remote = Invoke-NativeProcessCapture -FileName 'git.exe' `
        -ArgumentList @('-C', $resolvedPluginPath, 'remote', 'get-url', 'origin')
    return [pscustomobject]@{
        Head   = $head.StdOut
        Branch = $branch.StdOut
        Remote = ConvertTo-FabSafeGitRemote -Remote $remote.StdOut
    }
}

function Test-EngineRootLayout {
    param(
        [Parameter(Mandatory)]
        [string]$Candidate,

        [Parameter(Mandatory)]
        [string]$EngineVersion
    )

    if (-not [System.IO.Directory]::Exists($Candidate)) {
        return $null
    }
    $resolved = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    $uatPath = Join-Path $resolved 'Engine\Build\BatchFiles\RunUAT.bat'
    $buildVersionPath = Join-Path $resolved 'Engine\Build\Build.version'
    if (-not [System.IO.File]::Exists($uatPath) -or -not [System.IO.File]::Exists($buildVersionPath)) {
        return $null
    }
    try {
        $buildVersion = [System.IO.File]::ReadAllText($buildVersionPath) | ConvertFrom-Json
    }
    catch {
        throw "Engine Build.version is not valid JSON: $buildVersionPath. $($_.Exception.Message)"
    }
    $detectedVersion = "$($buildVersion.MajorVersion).$($buildVersion.MinorVersion)"
    if ($detectedVersion -cne $EngineVersion) {
        throw "Engine version mismatch at '$resolved'. Expected $EngineVersion, found $detectedVersion."
    }
    return $resolved
}

function Resolve-EngineCandidateInput {
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,

        [Parameter(Mandatory)]
        [string]$EngineVersion
    )

    $candidatePaths = @(
        [System.IO.Path]::GetFullPath($InputPath),
        [System.IO.Path]::Combine([System.IO.Path]::GetFullPath($InputPath), "UE_$EngineVersion")
    )
    $resolvedCandidates = @($candidatePaths | ForEach-Object {
            Test-EngineRootLayout -Candidate $_ -EngineVersion $EngineVersion
        } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
    if ($resolvedCandidates.Count -eq 0) {
        throw "No valid UE $EngineVersion installation was found at or below: $InputPath"
    }
    if ($resolvedCandidates.Count -gt 1) {
        throw "Multiple UE $EngineVersion installations were resolved; specify -EngineRoot exactly: $($resolvedCandidates -join ', ')"
    }
    return $resolvedCandidates[0]
}

function Resolve-FabEngineRoot {
    param(
        [Parameter(Mandatory)]
        [string]$EngineVersion,

        [string]$EngineRoot,

        [string]$EnvironmentEngineRoot = $env:FAB_PLUGIN_RELEASE_ENGINE_ROOT,

        [string]$ManifestDirectory = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests',

        [string]$DefaultEpicDirectory = 'C:\Program Files\Epic Games'
    )

    if (-not [string]::IsNullOrWhiteSpace($EngineRoot)) {
        return Resolve-EngineCandidateInput -InputPath $EngineRoot -EngineVersion $EngineVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($EnvironmentEngineRoot)) {
        return Resolve-EngineCandidateInput -InputPath $EnvironmentEngineRoot -EngineVersion $EngineVersion
    }

    $manifestCandidates = @()
    if ([System.IO.Directory]::Exists($ManifestDirectory)) {
        foreach ($manifestPath in [System.IO.Directory]::EnumerateFiles($ManifestDirectory, '*.item')) {
            try {
                $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
            }
            catch {
                throw "Epic Launcher manifest is not valid JSON: $manifestPath. $($_.Exception.Message)"
            }
            if ([string]$manifest.AppName -ceq "UE_$EngineVersion" -and
                -not [string]::IsNullOrWhiteSpace([string]$manifest.InstallLocation)) {
                $resolved = Test-EngineRootLayout `
                    -Candidate ([string]$manifest.InstallLocation) -EngineVersion $EngineVersion
                if ($null -ne $resolved) {
                    $manifestCandidates += $resolved
                }
            }
        }
    }
    $manifestCandidates = @($manifestCandidates | Sort-Object -Unique)
    if ($manifestCandidates.Count -gt 1) {
        throw "Multiple UE $EngineVersion installations were found in Launcher manifests; specify -EngineRoot: $($manifestCandidates -join ', ')"
    }
    if ($manifestCandidates.Count -eq 1) {
        return $manifestCandidates[0]
    }

    $defaultCandidate = Join-Path $DefaultEpicDirectory "UE_$EngineVersion"
    $resolvedDefault = Test-EngineRootLayout -Candidate $defaultCandidate -EngineVersion $EngineVersion
    if ($null -eq $resolvedDefault) {
        throw "Unable to resolve a valid UE $EngineVersion installation. Specify -EngineRoot."
    }
    return $resolvedDefault
}

function Test-FabHttpsUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [int]$TimeoutSeconds = 20
    )

    Assert-HttpsUrl -Url $Url -PropertyName 'URL'
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 10
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("fab-plugin-release-tools/$script:ToolVersion")
    $requestedUri = [System.Uri]::new($Url, [System.UriKind]::Absolute)
    $safeRequestedUrl = ConvertTo-FabSafeReportUri -Uri $requestedUri
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Url)
        try {
            $response = $client.Send($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        }
        finally {
            $request.Dispose()
        }
        if ([int]$response.StatusCode -in @(403, 405)) {
            $response.Dispose()
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
            try {
                $response = $client.Send($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
            }
            finally {
                $request.Dispose()
            }
        }
        try {
            $statusCode = [int]$response.StatusCode
            $finalUrl = ConvertTo-FabSafeReportUri -Uri $response.RequestMessage.RequestUri
            if ($statusCode -lt 200 -or $statusCode -gt 399) {
                $statusException = [System.InvalidOperationException]::new(
                    "URL validation failed with HTTP ${statusCode}.")
                $statusException.Data['FabSafeMessage'] = $true
                throw $statusException
            }
            return [pscustomobject]@{
                requestedUrl = $safeRequestedUrl
                finalUrl     = $finalUrl
                statusCode   = $statusCode
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch [System.Net.Http.HttpRequestException] {
        throw "URL request failed for '$safeRequestedUrl' (HttpRequestException)."
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        throw "URL request failed for '$safeRequestedUrl' (timeout)."
    }
    catch {
        if ($_.Exception.Data['FabSafeMessage'] -eq $true) {
            throw
        }
        throw "URL validation failed for '$safeRequestedUrl' ($($_.Exception.GetType().Name))."
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-JsonObjectProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return $Object.PSObject.Properties[$Name]
}

function Assert-JsonArrayProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Description,

        [switch]$Optional
    )

    $property = Get-JsonObjectProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        if ($Optional) { return }
        throw "$Description must be a JSON array."
    }
    if ($property.Value -isnot [System.Array]) {
        throw "$Description must be a JSON array."
    }
}

function Set-JsonObjectProperty {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    if (-not $PSCmdlet.ShouldProcess($Name, 'Set JSON object property')) {
        return
    }
    $property = Get-JsonObjectProperty -Object $Object -Name $Name
    if ($null -eq $property) {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
}

function Read-PluginDescriptor {
    param(
        [Parameter(Mandatory)]
        [string]$DescriptorPath
    )

    if (-not [System.IO.File]::Exists($DescriptorPath)) {
        throw "Plugin descriptor is missing: $DescriptorPath"
    }
    try {
        return [System.IO.File]::ReadAllText($DescriptorPath) | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Plugin descriptor is not valid JSON: $DescriptorPath. $($_.Exception.Message)"
    }
}

function Assert-SourcePluginDescriptor {
    param(
        [Parameter(Mandatory)]
        [object]$Descriptor,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    if ($Descriptor.FileVersion -ne 3) {
        throw 'Descriptor FileVersion must be 3.'
    }
    if (($Descriptor.Version -isnot [long] -and $Descriptor.Version -isnot [int]) -or $Descriptor.Version -le 0) {
        throw 'Descriptor Version must be a positive integer.'
    }
    foreach ($propertyName in @('VersionName', 'FriendlyName', 'Description', 'Category')) {
        if ([string]::IsNullOrWhiteSpace([string]$Descriptor.$propertyName)) {
            throw "Descriptor $propertyName must not be empty."
        }
    }
    if ([string]$Descriptor.VersionName -cnotmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
        throw 'Descriptor VersionName is not safe for use in a file name.'
    }
    Assert-JsonArrayProperty -Object $Descriptor -Name 'Modules' -Description 'Descriptor Modules'
    Assert-JsonArrayProperty -Object $Descriptor -Name 'Plugins' -Description 'Descriptor Plugins' -Optional
    Assert-JsonArrayProperty -Object $Descriptor -Name 'SupportedTargetPlatforms' `
        -Description 'Descriptor SupportedTargetPlatforms' -Optional
    $modules = @($Descriptor.Modules)
    if ($modules.Count -eq 0) {
        throw 'Descriptor Modules must not be empty.'
    }
    $moduleNames = @($modules | ForEach-Object { [string]$_.Name })
    Assert-UniqueStringSet -Values $moduleNames -PropertyName 'descriptor.Modules.Name'
    foreach ($requiredModule in @($Configuration.distributionModules)) {
        if ($moduleNames -cnotcontains $requiredModule) {
            throw "Distribution module is missing from descriptor: $requiredModule"
        }
    }
    foreach ($module in $modules) {
        Assert-JsonArrayProperty -Object $module -Name 'PlatformAllowList' `
            -Description "Descriptor module PlatformAllowList: $($module.Name)"
        if ($null -ne (Get-JsonObjectProperty -Object $module -Name 'PlatformDenyList')) {
            throw "PlatformDenyList is forbidden in schemaVersion 1: $($module.Name)"
        }
        $allowList = @($module.PlatformAllowList)
        if ($allowList.Count -ne 1 -or [string]$allowList[0] -cne 'Win64') {
            throw "Every source module must have exactly PlatformAllowList [`"Win64`"]: $($module.Name)"
        }
    }

    $sourcePluginsProperty = Get-JsonObjectProperty -Object $Descriptor -Name 'Plugins'
    $sourcePlugins = if ($null -eq $sourcePluginsProperty) { @() } else { @($sourcePluginsProperty.Value) }
    $enabledDependencies = @($sourcePlugins |
            Where-Object { $_.Enabled -eq $true } |
            ForEach-Object { [string]$_.Name })
    Assert-UniqueStringSet -Values $enabledDependencies -PropertyName 'descriptor enabled Plugins'
    Assert-ExactStringSet -Actual $enabledDependencies `
        -Expected @($Configuration.enabledPluginDependencies) `
        -Description 'Enabled plugin dependencies'
}

function Get-CopyrightFile {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath
    )

    $sourceRoot = Join-Path $PluginPath 'Source'
    if (-not [System.IO.Directory]::Exists($sourceRoot)) {
        throw "Plugin Source directory is missing: $sourceRoot"
    }
    return @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object {
            $relative = [System.IO.Path]::GetRelativePath($sourceRoot, $_.FullName).Replace('\', '/')
            $isBuildScript = $_.Name.EndsWith('.Build.cs', [System.StringComparison]::Ordinal)
            $isCppFile = $script:CopyrightExtensions -ccontains $_.Extension
            $isThirdParty = $relative.StartsWith('ThirdParty/', [System.StringComparison]::OrdinalIgnoreCase)
            $isBuildScript -or ($isCppFile -and -not $isThirdParty)
        })
}

function Test-SourceCopyright {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath,

        [Parameter(Mandatory)]
        [string]$ExpectedNotice
    )

    foreach ($file in Get-CopyrightFile -PluginPath $PluginPath) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
            $content = $content.Substring(1)
        }
        $actualFirstLine = @($content -split "`r?`n" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First 1)
        $actual = if ($actualFirstLine.Count -eq 0) { '' } else { $actualFirstLine[0] }
        if ($actual -cne $ExpectedNotice) {
            $relative = [System.IO.Path]::GetRelativePath($PluginPath, $file.FullName).Replace('\', '/')
            throw "Copyright mismatch in '$relative'. Actual first line: '$actual'. Expected: '$ExpectedNotice'."
        }
    }
}

function Get-UnrealMacroInvocation {
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $macroNames = @('UFUNCTION', 'UPROPERTY')
    $index = 0
    $line = 1
    $state = 'Code'
    while ($index -lt $Content.Length) {
        $character = $Content[$index]
        $next = if ($index + 1 -lt $Content.Length) { $Content[$index + 1] } else { [char]0 }
        if ($character -eq "`n") {
            $line++
        }
        if ($state -eq 'LineComment') {
            if ($character -eq "`n") { $state = 'Code' }
            $index++
            continue
        }
        if ($state -eq 'BlockComment') {
            if ($character -eq '*' -and $next -eq '/') {
                $state = 'Code'
                $index += 2
            }
            else {
                $index++
            }
            continue
        }
        if ($state -eq 'String') {
            if ($character -eq '\') {
                $index += [Math]::Min(2, $Content.Length - $index)
            }
            else {
                if ($character -eq '"') { $state = 'Code' }
                $index++
            }
            continue
        }
        if ($state -eq 'Character') {
            if ($character -eq '\') {
                $index += [Math]::Min(2, $Content.Length - $index)
            }
            else {
                if ($character -eq "'") { $state = 'Code' }
                $index++
            }
            continue
        }
        if ($character -eq '/' -and $next -eq '/') {
            $state = 'LineComment'
            $index += 2
            continue
        }
        if ($character -eq '/' -and $next -eq '*') {
            $state = 'BlockComment'
            $index += 2
            continue
        }
        if ($character -eq '"') {
            $state = 'String'
            $index++
            continue
        }
        if ($character -eq "'") {
            $state = 'Character'
            $index++
            continue
        }

        $matchedMacro = $null
        foreach ($macroName in $macroNames) {
            if ($index + $macroName.Length -le $Content.Length -and
                $Content.Substring($index, $macroName.Length) -ceq $macroName) {
                $previousIsIdentifier = $index -gt 0 -and $Content[$index - 1] -match '[0-9A-Za-z_]'
                $afterIndex = $index + $macroName.Length
                $nextIsIdentifier = $afterIndex -lt $Content.Length -and $Content[$afterIndex] -match '[0-9A-Za-z_]'
                if (-not $previousIsIdentifier -and -not $nextIsIdentifier) {
                    $matchedMacro = $macroName
                    break
                }
            }
        }
        if ($null -eq $matchedMacro) {
            $index++
            continue
        }

        $macroLine = $line
        $cursor = $index + $matchedMacro.Length
        while ($cursor -lt $Content.Length -and [char]::IsWhiteSpace($Content[$cursor])) {
            if ($Content[$cursor] -eq "`n") { $line++ }
            $cursor++
        }
        if ($cursor -ge $Content.Length -or $Content[$cursor] -ne '(') {
            $index += $matchedMacro.Length
            continue
        }
        $argumentStart = $cursor + 1
        $depth = 1
        $innerState = 'Code'
        $cursor++
        while ($cursor -lt $Content.Length -and $depth -gt 0) {
            $current = $Content[$cursor]
            $following = if ($cursor + 1 -lt $Content.Length) { $Content[$cursor + 1] } else { [char]0 }
            if ($current -eq "`n") { $line++ }
            if ($innerState -eq 'LineComment') {
                if ($current -eq "`n") { $innerState = 'Code' }
                $cursor++
                continue
            }
            if ($innerState -eq 'BlockComment') {
                if ($current -eq '*' -and $following -eq '/') {
                    $innerState = 'Code'
                    $cursor += 2
                }
                else {
                    $cursor++
                }
                continue
            }
            if ($innerState -eq 'String') {
                if ($current -eq '\') {
                    $cursor += [Math]::Min(2, $Content.Length - $cursor)
                }
                else {
                    if ($current -eq '"') { $innerState = 'Code' }
                    $cursor++
                }
                continue
            }
            if ($innerState -eq 'Character') {
                if ($current -eq '\') {
                    $cursor += [Math]::Min(2, $Content.Length - $cursor)
                }
                else {
                    if ($current -eq "'") { $innerState = 'Code' }
                    $cursor++
                }
                continue
            }
            if ($current -eq '/' -and $following -eq '/') {
                $innerState = 'LineComment'
                $cursor += 2
                continue
            }
            if ($current -eq '/' -and $following -eq '*') {
                $innerState = 'BlockComment'
                $cursor += 2
                continue
            }
            if ($current -eq '"') { $innerState = 'String'; $cursor++; continue }
            if ($current -eq "'") { $innerState = 'Character'; $cursor++; continue }
            if ($current -eq '(') { $depth++ }
            elseif ($current -eq ')') { $depth-- }
            $cursor++
        }
        if ($depth -ne 0) {
            throw "Unterminated $matchedMacro invocation at line $macroLine."
        }
        $argumentsLength = ($cursor - 1) - $argumentStart
        $arguments = if ($argumentsLength -gt 0) {
            $Content.Substring($argumentStart, $argumentsLength)
        }
        else {
            ''
        }
        $results.Add([pscustomobject]@{
                Kind      = $matchedMacro
                Line      = $macroLine
                Arguments = $arguments
            })
        $index = $cursor
    }
    return $results.ToArray()
}

function Split-UnrealMacroArgumentList {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Arguments
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $builder = [System.Text.StringBuilder]::new()
    $depth = 0
    $state = 'Code'
    for ($index = 0; $index -lt $Arguments.Length; $index++) {
        $character = $Arguments[$index]
        $next = if ($index + 1 -lt $Arguments.Length) { $Arguments[$index + 1] } else { [char]0 }
        if ($state -eq 'LineComment') {
            if ($character -eq "`n") { $state = 'Code'; [void]$builder.Append(' ') }
            continue
        }
        if ($state -eq 'BlockComment') {
            if ($character -eq '*' -and $next -eq '/') { $state = 'Code'; $index++ }
            continue
        }
        if ($state -eq 'String') {
            [void]$builder.Append($character)
            if ($character -eq '\' -and $index + 1 -lt $Arguments.Length) {
                $index++
                [void]$builder.Append($Arguments[$index])
            }
            elseif ($character -eq '"') { $state = 'Code' }
            continue
        }
        if ($state -eq 'Character') {
            [void]$builder.Append($character)
            if ($character -eq '\' -and $index + 1 -lt $Arguments.Length) {
                $index++
                [void]$builder.Append($Arguments[$index])
            }
            elseif ($character -eq "'") { $state = 'Code' }
            continue
        }
        if ($character -eq '/' -and $next -eq '/') { $state = 'LineComment'; $index++; continue }
        if ($character -eq '/' -and $next -eq '*') { $state = 'BlockComment'; $index++; continue }
        if ($character -eq '"') { $state = 'String'; [void]$builder.Append($character); continue }
        if ($character -eq "'") { $state = 'Character'; [void]$builder.Append($character); continue }
        if ($character -eq '(') { $depth++ }
        elseif ($character -eq ')') { $depth-- }
        if ($character -eq ',' -and $depth -eq 0) {
            $parts.Add($builder.ToString().Trim())
            [void]$builder.Clear()
            continue
        }
        [void]$builder.Append($character)
    }
    if ($builder.Length -gt 0 -or $Arguments.Length -gt 0) {
        $parts.Add($builder.ToString().Trim())
    }
    return $parts.ToArray()
}

function Test-UnrealCategorySpecifier {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath
    )

    $publicSpecifiers = @{
        UFUNCTION = @(
            'BlueprintCallable', 'BlueprintPure', 'BlueprintImplementableEvent',
            'BlueprintNativeEvent', 'BlueprintGetter', 'BlueprintSetter', 'CallInEditor')
        UPROPERTY = @(
            'BlueprintReadOnly', 'BlueprintReadWrite', 'BlueprintGetter', 'BlueprintSetter',
            'BlueprintAssignable', 'BlueprintCallable', 'EditAnywhere', 'EditDefaultsOnly',
            'EditInstanceOnly', 'VisibleAnywhere', 'VisibleDefaultsOnly', 'VisibleInstanceOnly')
    }
    $sourceRoot = Join-Path $PluginPath 'Source'
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object {
            $relative = [System.IO.Path]::GetRelativePath($sourceRoot, $_.FullName).Replace('\', '/')
            -not $relative.StartsWith('ThirdParty/', [System.StringComparison]::OrdinalIgnoreCase) -and
            $script:CopyrightExtensions -ccontains $_.Extension
        })
    foreach ($file in $files) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        foreach ($macro in Get-UnrealMacroInvocation -Content $content) {
            $parts = @(Split-UnrealMacroArgumentList -Arguments $macro.Arguments)
            $specifierNames = @($parts | ForEach-Object {
                    if ($_ -match '^\s*([A-Za-z_][0-9A-Za-z_]*)') { $Matches[1] }
                })
            $detected = @($publicSpecifiers[$macro.Kind] | Where-Object { $specifierNames -ccontains $_ })
            if ($detected.Count -eq 0) {
                continue
            }
            $categoryParts = @($parts | Where-Object { $_ -match '^\s*Category\s*=' })
            $hasValidCategory = $categoryParts.Count -eq 1 -and
                $categoryParts[0] -cmatch '^\s*Category\s*=\s*"[^"\r\n]+"\s*$'
            if (-not $hasValidCategory) {
                $relative = [System.IO.Path]::GetRelativePath($PluginPath, $file.FullName).Replace('\', '/')
                throw "Missing direct non-empty Category in $($macro.Kind) at '${relative}:$($macro.Line)'. Public specifiers: $($detected -join ', ')."
            }
        }
    }
}

function ConvertTo-SalesPluginDescriptor {
    param(
        [Parameter(Mandatory)]
        [object]$SourceDescriptor,

        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string]$EngineVersion,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $descriptor = ($SourceDescriptor | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100
    Set-JsonObjectProperty -Object $descriptor -Name EngineVersion -Value "$EngineVersion.0"
    Set-JsonObjectProperty -Object $descriptor -Name Installed -Value $true
    Set-JsonObjectProperty -Object $descriptor -Name SupportedTargetPlatforms -Value @('Win64')
    Set-JsonObjectProperty -Object $descriptor -Name CreatedBy -Value ([string]$Configuration.publisher.name)
    Set-JsonObjectProperty -Object $descriptor -Name CreatedByURL -Value ([string]$Configuration.publisher.url)
    Set-JsonObjectProperty -Object $descriptor -Name DocsURL -Value ([string]$Configuration.documentationUrl)
    Set-JsonObjectProperty -Object $descriptor -Name SupportURL -Value ([string]$Configuration.supportUrl)
    Set-JsonObjectProperty -Object $descriptor -Name IsBetaVersion -Value $false
    Set-JsonObjectProperty -Object $descriptor -Name IsExperimentalVersion -Value $false
    Set-JsonObjectProperty -Object $descriptor -Name CanContainContent `
        -Value ($Configuration.content.mode -ceq 'pack')

    $modules = @(@($descriptor.Modules) |
            Where-Object { @($Configuration.distributionModules) -ccontains [string]$_.Name })
    foreach ($module in $modules) {
        [void]$module.PSObject.Properties.Remove('PlatformDenyList')
        Set-JsonObjectProperty -Object $module -Name PlatformAllowList -Value @('Win64')
    }
    Set-JsonObjectProperty -Object $descriptor -Name Modules -Value $modules

    $pluginsProperty = Get-JsonObjectProperty -Object $descriptor -Name 'Plugins'
    $sourcePlugins = if ($null -eq $pluginsProperty) { @() } else { @($pluginsProperty.Value) }
    $plugins = @($sourcePlugins |
            Where-Object { @($Configuration.enabledPluginDependencies) -ccontains [string]$_.Name })
    foreach ($plugin in $plugins) {
        Set-JsonObjectProperty -Object $plugin -Name Enabled -Value $true
    }
    if ($plugins.Count -eq 0) {
        [void]$descriptor.PSObject.Properties.Remove('Plugins')
    }
    else {
        Set-JsonObjectProperty -Object $descriptor -Name Plugins -Value $plugins
    }
    [void]$descriptor.PSObject.Properties.Remove('MarketplaceURL')
    if ($null -eq $Configuration.listingId) {
        [void]$descriptor.PSObject.Properties.Remove('FabURL')
    }
    else {
        Set-JsonObjectProperty -Object $descriptor -Name FabURL `
            -Value "com.epicgames.launcher://ue/Fab/product/$($Configuration.listingId)"
    }
    $json = $descriptor | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $DestinationPath,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
    $bytes = [System.IO.File]::ReadAllBytes($DestinationPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "Sales descriptor must be UTF-8 without BOM: $DestinationPath"
    }
    $validated = Read-PluginDescriptor -DescriptorPath $DestinationPath
    Assert-SalesPluginDescriptor -Descriptor $validated -Configuration $Configuration -EngineVersion $EngineVersion
    return $validated
}

function Assert-SalesPluginDescriptor {
    param(
        [Parameter(Mandatory)]
        [object]$Descriptor,

        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string]$EngineVersion
    )

    if ([string]$Descriptor.EngineVersion -cne "$EngineVersion.0") { throw 'Sales descriptor EngineVersion mismatch.' }
    if ($Descriptor.Installed -ne $true) { throw 'Sales descriptor Installed must be true.' }
    Assert-JsonArrayProperty -Object $Descriptor -Name 'Modules' -Description 'Sales descriptor Modules'
    Assert-JsonArrayProperty -Object $Descriptor -Name 'SupportedTargetPlatforms' `
        -Description 'Sales descriptor SupportedTargetPlatforms'
    Assert-JsonArrayProperty -Object $Descriptor -Name 'Plugins' `
        -Description 'Sales descriptor Plugins' -Optional
    $platforms = @($Descriptor.SupportedTargetPlatforms)
    if ($platforms.Count -ne 1 -or [string]$platforms[0] -cne 'Win64') {
        throw 'Sales descriptor SupportedTargetPlatforms must be exactly ["Win64"].'
    }
    if ([string]$Descriptor.CreatedBy -cne [string]$Configuration.publisher.name -or
        [string]$Descriptor.CreatedByURL -cne [string]$Configuration.publisher.url -or
        [string]$Descriptor.DocsURL -cne [string]$Configuration.documentationUrl -or
        [string]$Descriptor.SupportURL -cne [string]$Configuration.supportUrl) {
        throw 'Sales descriptor publisher or support metadata mismatch.'
    }
    if ($Descriptor.IsBetaVersion -ne $false -or $Descriptor.IsExperimentalVersion -ne $false) {
        throw 'Sales descriptor beta and experimental flags must be false.'
    }
    if ($Descriptor.CanContainContent -ne ($Configuration.content.mode -ceq 'pack')) {
        throw 'Sales descriptor CanContainContent mismatch.'
    }
    $modules = @($Descriptor.Modules)
    Assert-ExactStringSet -Actual @($modules | ForEach-Object { [string]$_.Name }) `
        -Expected @($Configuration.distributionModules) -Description 'Sales descriptor modules'
    foreach ($module in $modules) {
        Assert-JsonArrayProperty -Object $module -Name 'PlatformAllowList' `
            -Description "Sales descriptor module PlatformAllowList: $($module.Name)"
        $allowList = @($module.PlatformAllowList)
        if ($allowList.Count -ne 1 -or [string]$allowList[0] -cne 'Win64' -or
            $null -ne (Get-JsonObjectProperty -Object $module -Name 'PlatformDenyList')) {
            throw "Sales descriptor module platform policy mismatch: $($module.Name)"
        }
    }
    $pluginsProperty = Get-JsonObjectProperty -Object $Descriptor -Name 'Plugins'
    $plugins = if ($null -eq $pluginsProperty) { @() } else { @($pluginsProperty.Value) }
    Assert-ExactStringSet -Actual @($plugins | ForEach-Object { [string]$_.Name }) `
        -Expected @($Configuration.enabledPluginDependencies) -Description 'Sales descriptor dependencies'
    foreach ($plugin in $plugins) {
        if ($plugin.Enabled -ne $true) { throw "Sales dependency must be enabled: $($plugin.Name)" }
    }
    if (@($Configuration.enabledPluginDependencies).Count -eq 0 -and
        $null -ne (Get-JsonObjectProperty -Object $Descriptor -Name 'Plugins')) {
        throw 'Sales descriptor must omit Plugins when there are no enabled dependencies.'
    }
    if ($null -ne (Get-JsonObjectProperty -Object $Descriptor -Name 'MarketplaceURL')) {
        throw 'Sales descriptor must not contain MarketplaceURL.'
    }
    if ($null -eq $Configuration.listingId) {
        if ($null -ne (Get-JsonObjectProperty -Object $Descriptor -Name 'FabURL')) {
            throw 'Sales descriptor must omit FabURL when listingId is null.'
        }
    }
    elseif ([string]$Descriptor.FabURL -cne
        "com.epicgames.launcher://ue/Fab/product/$($Configuration.listingId)") {
        throw 'Sales descriptor FabURL mismatch.'
    }
}

function Get-SafeTreeFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    if (-not [System.IO.Directory]::Exists($Root)) {
        throw "Directory is missing: $Root"
    }
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $rootInfo = [System.IO.DirectoryInfo]::new($resolvedRoot)
    Assert-NoReparsePoint -Item $rootInfo
    $directories = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
    $directories.Enqueue($rootInfo)
    $files = [System.Collections.Generic.List[object]]::new()
    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        foreach ($childDirectory in $directory.EnumerateDirectories()) {
            Assert-NoReparsePoint -Item $childDirectory
            $directories.Enqueue($childDirectory)
        }
        foreach ($file in $directory.EnumerateFiles()) {
            Assert-NoReparsePoint -Item $file
            $resolvedFile = [System.IO.Path]::GetFullPath($file.FullName)
            if (-not (Test-IsDescendantPath -Root $resolvedRoot -Candidate $resolvedFile)) {
                throw "File resolves outside the allowed root: $resolvedFile"
            }
            $files.Add([pscustomobject]@{
                    FullName     = $resolvedFile
                    RelativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $resolvedFile).Replace('\', '/')
                    Length       = $file.Length
                })
        }
    }
    return $files.ToArray()
}

function Get-OrdinalSortedTreeFile {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    [object[]]$files = @(Get-SafeTreeFile -Root $Root)
    $comparison = [System.Comparison[object]]{
        param($left, $right)
        return [System.StringComparer]::Ordinal.Compare(
            [string]$left.RelativePath,
            [string]$right.RelativePath)
    }
    [System.Array]::Sort(
        $files,
        [System.Collections.Generic.Comparer[object]]::Create($comparison))
    return $files
}

function Copy-FabPluginAllowList {
    param(
        [Parameter(Mandatory)]
        [string]$PluginPath,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $resolvedPluginPath = [System.IO.Path]::GetFullPath($PluginPath)
    Assert-FabAbsoluteDirectoryPathChain -Path $resolvedPluginPath
    $resolvedDestination = [System.IO.Path]::GetFullPath($DestinationRoot)
    $validatedDirectories = [System.Collections.Generic.List[object]]::new()
    $validatedFiles = [System.Collections.Generic.List[object]]::new()

    foreach ($configuredDirectory in @($Configuration.includeDirectories)) {
        $sourceDirectory = [System.IO.Path]::GetFullPath((Join-Path $resolvedPluginPath $configuredDirectory))
        if (-not (Test-IsDescendantPath -Root $resolvedPluginPath -Candidate $sourceDirectory)) {
            throw "Included directory is unsafe: $configuredDirectory"
        }
        Assert-FabPathChain -Root $resolvedPluginPath -Candidate $sourceDirectory
        if (-not [System.IO.Directory]::Exists($sourceDirectory)) {
            throw "Included directory is missing: $configuredDirectory"
        }
        $validatedDirectories.Add([pscustomobject]@{
                ConfiguredPath = $configuredDirectory
                SourcePath     = $sourceDirectory
            })
    }
    foreach ($configuredFile in @($Configuration.includeFiles)) {
        $sourceFilePath = [System.IO.Path]::GetFullPath((Join-Path $resolvedPluginPath $configuredFile))
        if (-not (Test-IsDescendantPath -Root $resolvedPluginPath -Candidate $sourceFilePath)) {
            throw "Included file is unsafe: $configuredFile"
        }
        Assert-FabPathChain -Root $resolvedPluginPath -Candidate $sourceFilePath
        if (-not [System.IO.File]::Exists($sourceFilePath)) {
            throw "Included file is missing: $configuredFile"
        }
        $validatedFiles.Add([pscustomobject]@{
                ConfiguredPath = $configuredFile
                SourcePath     = $sourceFilePath
            })
    }

    [System.IO.Directory]::CreateDirectory($resolvedDestination) | Out-Null
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $totalBytes = 0L

    foreach ($validatedDirectory in $validatedDirectories) {
        foreach ($sourceFile in Get-SafeTreeFile -Root $validatedDirectory.SourcePath) {
            $configuredDirectory = [string]$validatedDirectory.ConfiguredPath
            $relative = "$configuredDirectory/$($sourceFile.RelativePath)".Trim('/')
            if (-not $seen.Add($relative)) {
                throw "Case-insensitive staging path collision: $relative"
            }
            $totalBytes += $sourceFile.Length
            if ($totalBytes -gt $script:MaximumPackageBytes) {
                throw 'Staging exceeds the 15 GiB limit.'
            }
            $destinationFile = Join-Path $resolvedDestination $relative
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destinationFile)) | Out-Null
            [System.IO.File]::Copy($sourceFile.FullName, $destinationFile, $false)
        }
    }
    foreach ($validatedFile in $validatedFiles) {
        $configuredFile = [string]$validatedFile.ConfiguredPath
        $sourceFilePath = [string]$validatedFile.SourcePath
        $sourceFile = [System.IO.FileInfo]::new($sourceFilePath)
        if (-not $seen.Add($configuredFile)) {
            throw "Case-insensitive staging path collision: $configuredFile"
        }
        $totalBytes += $sourceFile.Length
        if ($totalBytes -gt $script:MaximumPackageBytes) {
            throw 'Staging exceeds the 15 GiB limit.'
        }
        $destinationFile = Join-Path $resolvedDestination $configuredFile
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destinationFile)) | Out-Null
        [System.IO.File]::Copy($sourceFilePath, $destinationFile, $false)
    }
}

function Copy-SafeDirectoryTree {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    if ([System.IO.Directory]::Exists($DestinationRoot)) {
        throw "Destination must not already exist: $DestinationRoot"
    }
    [System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null
    foreach ($sourceFile in Get-SafeTreeFile -Root $SourceRoot) {
        $destinationFile = Join-Path $DestinationRoot $sourceFile.RelativePath
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destinationFile)) | Out-Null
        [System.IO.File]::Copy($sourceFile.FullName, $destinationFile, $false)
    }
}

function Get-TotalFileSize {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [long[]]$Lengths,

        [long]$MaximumBytes = $script:MaximumPackageBytes
    )

    $total = 0L
    foreach ($length in $Lengths) {
        if ($length -lt 0) { throw 'File length cannot be negative.' }
        if ($total -gt $MaximumBytes - $length) {
            throw "Package exceeds the maximum size of $MaximumBytes bytes."
        }
        $total += $length
    }
    return $total
}

function Assert-ContentLayout {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $contentRoot = Join-Path $PluginRoot 'Content'
    if ($Configuration.content.mode -ceq 'none') {
        if ([System.IO.Directory]::Exists($contentRoot) -or [System.IO.File]::Exists($contentRoot)) {
            throw 'Content must not be staged when content.mode is none.'
        }
        return
    }
    if (-not [System.IO.Directory]::Exists($contentRoot)) {
        throw 'Content directory is required in pack mode.'
    }
    $topFiles = @([System.IO.Directory]::EnumerateFiles($contentRoot))
    $topDirectories = @([System.IO.Directory]::EnumerateDirectories($contentRoot))
    if ($topFiles.Count -ne 0 -or $topDirectories.Count -ne 1 -or
        [System.IO.Path]::GetFileName($topDirectories[0]) -cne [string]$Configuration.pluginName) {
        throw "Content must contain exactly one top-level '$($Configuration.pluginName)' directory and no files."
    }
    foreach ($file in Get-SafeTreeFile -Root $contentRoot) {
        $relative = $file.RelativePath
        if ($relative.Length -gt 140) {
            throw "Content-relative path exceeds 140 characters: $relative"
        }
        $segments = @($relative.Split('/'))
        for ($index = 0; $index -lt $segments.Count; $index++) {
            $segment = $segments[$index]
            $isFile = $index -eq $segments.Count - 1
            $pattern = if ($isFile) { '^[0-9A-Za-z_]+(?:\.[0-9A-Za-z_]+)*$' } else { '^[0-9A-Za-z_]+$' }
            if ($segment -cnotmatch $pattern) {
                throw "Content path segment contains spaces, non-ASCII, or unsupported characters: $relative"
            }
        }
    }
}

function Assert-FilterPluginConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $filterPath = Join-Path $PluginRoot 'Config\FilterPlugin.ini'
    if (-not [System.IO.File]::Exists($filterPath)) {
        throw 'Config/FilterPlugin.ini is required.'
    }
    $sectionCount = 0
    $inFilterSection = $false
    $actualEntries = [System.Collections.Generic.List[string]]::new()
    foreach ($rawLine in [System.IO.File]::ReadAllLines($filterPath)) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $inFilterSection = $line -ceq '[FilterPlugin]'
            if ($inFilterSection) { $sectionCount++ }
            continue
        }
        if ($inFilterSection) { $actualEntries.Add($line) }
    }
    if ($sectionCount -ne 1) {
        throw '[FilterPlugin] section must occur exactly once.'
    }
    Assert-UniqueStringSet -Values $actualEntries.ToArray() -PropertyName 'FilterPlugin entries' -CaseSensitive

    $expectedEntries = [System.Collections.Generic.List[string]]::new()
    foreach ($customPath in @($Configuration.customDistributionPaths)) {
        $fullPath = Join-Path $PluginRoot $customPath
        if ([System.IO.File]::Exists($fullPath)) {
            $expectedEntries.Add("/$customPath")
        }
        elseif ([System.IO.Directory]::Exists($fullPath)) {
            $expectedEntries.Add("/$customPath/...")
        }
        else {
            throw "customDistributionPaths target is missing: $customPath"
        }
    }
    Assert-ExactStringSet -Actual $actualEntries.ToArray() -Expected $expectedEntries.ToArray() `
        -Description 'FilterPlugin entries'

    $standardTopLevel = @('Config', 'Content', 'Resources', 'Source', "$($Configuration.pluginName).uplugin")
    foreach ($itemPath in [System.IO.Directory]::EnumerateFileSystemEntries($PluginRoot)) {
        $name = [System.IO.Path]::GetFileName($itemPath)
        if ($standardTopLevel -ccontains $name) { continue }
        $declared = @($Configuration.customDistributionPaths | Where-Object {
                $_ -ceq $name -or $_.StartsWith("$name/", [System.StringComparison]::Ordinal)
            }).Count -gt 0
        if (-not $declared) {
            throw "Non-standard top-level item is not declared in customDistributionPaths: $name"
        }
    }
}

function Assert-RequiredPackageFile {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    foreach ($requiredPath in @($Configuration.requiredPackageFiles)) {
        $fullPath = Join-Path $PluginRoot $requiredPath
        if (-not [System.IO.File]::Exists($fullPath)) {
            throw "Required package file is missing or not a regular file: $requiredPath"
        }
        $file = [System.IO.FileInfo]::new($fullPath)
        Assert-NoReparsePoint -Item $file
        if ($file.Length -eq 0) {
            throw "Required package file is empty: $requiredPath"
        }
    }
}

function Assert-NoForbiddenPackageFile {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $files = @(Get-SafeTreeFile -Root $PluginRoot)
    [void](Get-TotalFileSize -Lengths @($files | ForEach-Object { [long]$_.Length }))
    foreach ($file in $files) {
        $relative = $file.RelativePath
        $withTopLevel = "$($Configuration.pluginName)/$relative"
        if ($withTopLevel.Length -gt 170) {
            throw "ZIP path exceeds 170 characters: $withTopLevel"
        }
        $segments = @($relative.Split('/'))
        if ((Test-ContainsStringOrdinalIgnoreCase -Values $script:ForbiddenTopLevelDirectories -Value $segments[0]) -or
            (Test-ContainsStringOrdinalIgnoreCase -Values $segments -Value '.git') -or
            (Test-ContainsStringOrdinalIgnoreCase -Values $segments -Value '.github') -or
            (Test-ContainsStringOrdinalIgnoreCase -Values $segments -Value '.vs') -or
            @($segments | Where-Object { $script:ForbiddenPathElements -ccontains $_ }).Count -gt 0 -or
            (Test-ContainsStringOrdinalIgnoreCase -Values $script:ForbiddenNames -Value $file.RelativePath) -or
            (Test-ContainsStringOrdinalIgnoreCase -Values $script:ForbiddenNames `
                -Value ([System.IO.Path]::GetFileName($relative))) -or
            $relative.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase) -or
            @($script:ForbiddenExtensions | Where-Object {
                    $relative.EndsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0) {
            throw "Built-in forbidden package path is present: $relative"
        }
        foreach ($pattern in @($Configuration.CompiledForbiddenPatterns)) {
            if ($pattern.IsMatch($relative)) {
                throw "Configured forbidden package path is present: $relative"
            }
        }
    }
}

function Assert-ThirdPartyLicenseSet {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    foreach ($licenseSet in @($Configuration.thirdPartyLicenseSets)) {
        $licenseRoot = Join-Path $PluginRoot $licenseSet.root
        $files = @(Get-SafeTreeFile -Root $licenseRoot)
        foreach ($file in $files) {
            if ($file.Length -eq 0) {
                throw "Third-party license file is empty: $($licenseSet.root)/$($file.RelativePath)"
            }
        }
        Assert-ExactStringSet -Actual @($files.RelativePath) -Expected @($licenseSet.files) `
            -Description "Third-party license allowlist at $($licenseSet.root)"
    }
}

function Assert-FabPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string]$EngineVersion
    )

    $descriptorPath = Join-Path $PluginRoot $Configuration.descriptorFile
    $descriptor = Read-PluginDescriptor -DescriptorPath $descriptorPath
    Assert-SalesPluginDescriptor -Descriptor $descriptor -Configuration $Configuration -EngineVersion $EngineVersion
    Assert-ContentLayout -PluginRoot $PluginRoot -Configuration $Configuration
    Assert-FilterPluginConfiguration -PluginRoot $PluginRoot -Configuration $Configuration
    Assert-RequiredPackageFile -PluginRoot $PluginRoot -Configuration $Configuration
    Assert-NoForbiddenPackageFile -PluginRoot $PluginRoot -Configuration $Configuration
    Assert-ThirdPartyLicenseSet -PluginRoot $PluginRoot -Configuration $Configuration
}

function Write-ReleaseLog {
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $line = "[$([DateTimeOffset]::UtcNow.ToString('O'))] $Message"
    [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-Information $line -InformationAction Continue
}

function ConvertTo-CmdQuotedArgument {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Contains('"') -or $Value.Contains("`r") -or $Value.Contains("`n")) {
        throw 'A cmd.exe argument contains an unsupported quote or newline.'
    }
    return '"' + $Value.Replace('%', '%%') + '"'
}

function Invoke-UatProcess {
    param(
        [Parameter(Mandatory)]
        [string]$RunUatPath,

        [Parameter(Mandatory)]
        [string]$PluginDescriptorPath,

        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [int]$TimeoutSeconds = 1800
    )

    $commandParts = @(
        'call',
        (ConvertTo-CmdQuotedArgument -Value $RunUatPath),
        'BuildPlugin',
        (ConvertTo-CmdQuotedArgument -Value "-Plugin=$PluginDescriptorPath"),
        (ConvertTo-CmdQuotedArgument -Value "-Package=$PackagePath"),
        (ConvertTo-CmdQuotedArgument -Value '-TargetPlatforms=Win64'),
        '-Rocket'
    )
    $command = [string]::Join(' ', $commandParts)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Join-Path $env:SystemRoot 'System32\cmd.exe')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = "/d /s /v:off /c `"$command`""
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $lines = [System.Collections.Generic.List[string]]::new()
    $timedOut = $false
    $started = $false
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) {
            throw 'Failed to start UAT process.'
        }
        $started = $true
        $stdoutEnded = $false
        $stderrEnded = $false
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        while (-not ($process.HasExited -and $stdoutEnded -and $stderrEnded)) {
            if (-not $stdoutEnded -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stdoutEnded = $true
                }
                else {
                    $lines.Add($line)
                    Write-ReleaseLog -LogPath $LogPath -Message $line
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
            }
            if (-not $stderrEnded -and $stderrTask.IsCompleted) {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stderrEnded = $true
                }
                else {
                    $lines.Add($line)
                    Write-ReleaseLog -LogPath $LogPath -Message "STDERR: $line"
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
            }
            if (-not $process.HasExited -and $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                $process.Kill($true)
            }
            if (-not $process.HasExited) {
                [void]$process.WaitForExit(25)
            }
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            Command  = "cmd.exe /d /s /v:off /c $command"
            ExitCode = $process.ExitCode
            TimedOut = $timedOut
            Lines     = $lines.ToArray()
        }
    }
    finally {
        $stopwatch.Stop()
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Invoke-UatBuildPlugin {
    param(
        [Parameter(Mandatory)]
        [string]$EngineRoot,

        [Parameter(Mandatory)]
        [string]$StagedPluginRoot,

        [Parameter(Mandatory)]
        [string]$BuildInputPluginRoot,

        [Parameter(Mandatory)]
        [string]$BuildOutputRoot,

        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string]$EngineVersion,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [int]$TimeoutSeconds = 1800,

        [System.Collections.IDictionary]$BuildReport
    )

    Copy-SafeDirectoryTree -SourceRoot $StagedPluginRoot -DestinationRoot $BuildInputPluginRoot
    [System.IO.Directory]::CreateDirectory($BuildOutputRoot) | Out-Null
    $runUat = Join-Path $EngineRoot 'Engine\Build\BatchFiles\RunUAT.bat'
    $inputDescriptor = Join-Path $BuildInputPluginRoot $Configuration.descriptorFile
    $result = Invoke-UatProcess -RunUatPath $runUat -PluginDescriptorPath $inputDescriptor `
        -PackagePath $BuildOutputRoot -LogPath $LogPath -TimeoutSeconds $TimeoutSeconds

    $warningLines = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $BuildReport) {
        $BuildReport['command'] = $result.Command
        $BuildReport['exitCode'] = $result.ExitCode
        $BuildReport['timedOut'] = $result.TimedOut
        $BuildReport['warnings'] = @()
    }
    if ($result.TimedOut) {
        throw "UAT BuildPlugin timed out after $TimeoutSeconds seconds."
    }
    if ($result.ExitCode -ne 0) {
        throw "UAT BuildPlugin failed with exit code $($result.ExitCode)."
    }
    $escapedStagedPath = [regex]::Escape([System.IO.Path]::GetFullPath($StagedPluginRoot))
    $escapedInputPath = [regex]::Escape([System.IO.Path]::GetFullPath($BuildInputPluginRoot))
    foreach ($line in @($result.Lines)) {
        $hasError = (
            $line -match '(?i)\bfatal error\b' -or
            $line -match '(?i)\berror C\d+' -or
            $line -match '(?i)Log(?:Compile|Class|Blueprint|UObjectGlobals):\s*Error\b' -or
            $line -match '(?i)AutomationTool exiting with ExitCode\s*[=:]?\s*(?!0\b)-?\d+')
        foreach ($pattern in @($Configuration.CompiledBuildLogFailPatterns)) {
            if ($pattern.IsMatch($line)) { $hasError = $true }
        }
        if ($hasError) {
            throw "UAT BuildPlugin log contains a failure pattern: $line"
        }
        $hasWarning = $line -match '(?i)\bwarning C\d+' -or
            $line -match '(?i)Log(?:Compile|Class|Blueprint|UObjectGlobals):\s*Warning\b'
        if ($hasWarning) {
            $warningLines.Add($line)
            if ($null -ne $BuildReport) {
                $BuildReport['warnings'] = $warningLines.ToArray()
            }
            if ($line -match $escapedStagedPath -or $line -match $escapedInputPath) {
                throw "UAT BuildPlugin reported a plugin-origin warning: $line"
            }
        }
    }

    $outputDescriptors = @(Get-ChildItem -LiteralPath $BuildOutputRoot -Recurse -File -Filter '*.uplugin')
    if ($outputDescriptors.Count -ne 1) {
        throw "BuildPlugin output must contain exactly one descriptor; found $($outputDescriptors.Count)."
    }
    $outputDlls = @(Get-ChildItem -LiteralPath $BuildOutputRoot -Recurse -File -Filter '*.dll' |
            Where-Object { $_.FullName.Replace('\', '/') -match '/Binaries/Win64/' })
    if ($outputDlls.Count -eq 0) {
        throw 'BuildPlugin output must contain at least one Binaries/Win64 DLL.'
    }
    $outputDescriptor = Read-PluginDescriptor -DescriptorPath $outputDescriptors[0].FullName
    if ([string]$outputDescriptor.EngineVersion -cne "$EngineVersion.0") {
        throw 'BuildPlugin output descriptor EngineVersion mismatch.'
    }
    return [pscustomobject]@{
        command  = $result.Command
        exitCode = $result.ExitCode
        timedOut = $result.TimedOut
        warnings = $warningLines.ToArray()
    }
}

function Assert-SafeZipEntryName {
    param(
        [Parameter(Mandatory)]
        [string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($EntryName) -or $EntryName.Contains('\') -or
        $EntryName.StartsWith('/') -or $EntryName.StartsWith('//') -or
        $EntryName -match '^[A-Za-z]:' -or $EntryName.Contains(':')) {
        throw "Unsafe ZIP entry path: $EntryName"
    }
    $segments = @($EntryName.TrimEnd('/').Split('/'))
    if ($segments.Count -eq 0 -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
        throw "Unsafe ZIP entry path segments: $EntryName"
    }
}

function Register-ZipCasePath {
    param(
        [Parameter(Mandatory)]
        [string]$EntryName,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, object]]$Paths
    )

    $trimmed = $EntryName.TrimEnd('/')
    $segments = @($trimmed.Split('/'))
    $current = ''
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = if ($current.Length -eq 0) { $segments[$index] } else { "$current/$($segments[$index])" }
        $isLast = $index -eq $segments.Count - 1
        $kind = if ($isLast -and -not $EntryName.EndsWith('/')) { 'file' } else { 'directory' }
        if ($Paths.ContainsKey($current)) {
            $existing = $Paths[$current]
            if ([string]$existing.Path -cne $current -or [string]$existing.Kind -cne $kind) {
                throw "Case-insensitive or file/directory ZIP path collision: '$($existing.Path)' and '$current'"
            }
        }
        else {
            $Paths.Add($current, [pscustomobject]@{ Path = $current; Kind = $kind })
        }
    }
}

function New-DeterministicFabZip {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot,

        [Parameter(Mandatory)]
        [string]$PluginName,

        [Parameter(Mandatory)]
        [string]$ZipPath
    )

    if ([System.IO.File]::Exists($ZipPath)) {
        throw "Temporary ZIP already exists: $ZipPath"
    }
    if (-not $PSCmdlet.ShouldProcess($ZipPath, 'Create deterministic Fab ZIP')) {
        return
    }
    Add-Type -AssemblyName System.IO.Compression
    $files = @(Get-OrdinalSortedTreeFile -Root $PluginRoot)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in $files) {
                $entryName = "$PluginName/$($file.RelativePath)"
                Assert-SafeZipEntryName -EntryName $entryName
                if (-not $seen.Add($entryName)) {
                    throw "Case-insensitive duplicate ZIP entry: $entryName"
                }
                $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entryStream = $entry.Open()
                $inputStream = [System.IO.File]::OpenRead($file.FullName)
                try {
                    $inputStream.CopyTo($entryStream)
                }
                finally {
                    $inputStream.Dispose()
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Test-ZipEntryForbidden {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [object]$Configuration
    )

    $segments = @($RelativePath.Split('/'))
    if ((Test-ContainsStringOrdinalIgnoreCase -Values $script:ForbiddenTopLevelDirectories -Value $segments[0]) -or
        (Test-ContainsStringOrdinalIgnoreCase -Values $segments -Value '.git') -or
        (Test-ContainsStringOrdinalIgnoreCase -Values $segments -Value '.github') -or
        (Test-ContainsStringOrdinalIgnoreCase -Values $segments -Value '.vs') -or
        @($segments | Where-Object { $script:ForbiddenPathElements -ccontains $_ }).Count -gt 0 -or
        (Test-ContainsStringOrdinalIgnoreCase -Values $script:ForbiddenNames -Value $RelativePath) -or
        (Test-ContainsStringOrdinalIgnoreCase -Values $script:ForbiddenNames `
            -Value ([System.IO.Path]::GetFileName($RelativePath))) -or
        $RelativePath.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase) -or
        @($script:ForbiddenExtensions | Where-Object {
                $RelativePath.EndsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0) {
        return $true
    }
    foreach ($pattern in @($Configuration.CompiledForbiddenPatterns)) {
        if ($pattern.IsMatch($RelativePath)) { return $true }
    }
    return $false
}

function Assert-FabZipDirectly {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [object]$Configuration,

        [Parameter(Mandatory)]
        [string]$EngineVersion
    )

    Add-Type -AssemblyName System.IO.Compression
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $casePaths = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        $topLevels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $relativeFiles = [System.Collections.Generic.List[string]]::new()
        $lengths = [System.Collections.Generic.List[long]]::new()
        $descriptorEntry = $null
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName
            Assert-SafeZipEntryName -EntryName $entryName
            Register-ZipCasePath -EntryName $entryName -Paths $casePaths
            if (-not $seen.Add($entryName)) {
                throw "Case-insensitive duplicate ZIP entry: $entryName"
            }
            $segments = @($entryName.TrimEnd('/').Split('/'))
            [void]$topLevels.Add($segments[0])
            $isDirectory = $entryName.EndsWith('/')
            if ($segments[0] -cne [string]$Configuration.pluginName -or
                ($segments.Count -lt 2 -and -not $isDirectory)) {
                throw "ZIP entry is outside the plugin top-level directory: $entryName"
            }
            if ($entryName.Length -gt 170) {
                throw "ZIP path exceeds 170 characters: $entryName"
            }
            if ($segments.Count -eq 1) {
                continue
            }
            $relative = [string]::Join('/', $segments[1..($segments.Count - 1)])
            if (Test-ZipEntryForbidden -RelativePath $relative -Configuration $Configuration) {
                throw "Forbidden ZIP entry is present: $entryName"
            }
            if ($isDirectory) { continue }
            $relativeFiles.Add($relative)
            $lengths.Add($entry.Length)
            if ($relative -ceq [string]$Configuration.descriptorFile) { $descriptorEntry = $entry }
        }
        if ($topLevels.Count -ne 1 -or -not $topLevels.Contains([string]$Configuration.pluginName)) {
            throw "ZIP must contain exactly one '$($Configuration.pluginName)' top-level directory."
        }
        [void](Get-TotalFileSize -Lengths $lengths.ToArray())
        foreach ($requiredFile in @($Configuration.requiredPackageFiles)) {
            if ($relativeFiles -cnotcontains $requiredFile) {
                throw "Required ZIP file is missing: $requiredFile"
            }
        }
        if ($null -eq $descriptorEntry) {
            throw 'ZIP descriptor is missing.'
        }
        $reader = [System.IO.StreamReader]::new($descriptorEntry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
        try {
            $descriptor = $reader.ReadToEnd() | ConvertFrom-Json -Depth 100
        }
        finally {
            $reader.Dispose()
        }
        Assert-SalesPluginDescriptor -Descriptor $descriptor -Configuration $Configuration -EngineVersion $EngineVersion
    }
    finally {
        $archive.Dispose()
    }
}

function Expand-FabZipSafely {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    if ([System.IO.Directory]::Exists($DestinationRoot)) {
        throw "ZIP extraction destination already exists: $DestinationRoot"
    }
    [System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null
    $resolvedRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $casePaths = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $totalBytes = 0L
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            Assert-SafeZipEntryName -EntryName $entry.FullName
            Register-ZipCasePath -EntryName $entry.FullName -Paths $casePaths
            if (-not $seen.Add($entry.FullName)) {
                throw "Case-insensitive duplicate ZIP entry: $($entry.FullName)"
            }
            if (-not $entry.FullName.EndsWith('/')) {
                if ($totalBytes -gt $script:MaximumPackageBytes - $entry.Length) {
                    throw 'ZIP extraction exceeds the 15 GiB limit.'
                }
                $totalBytes += $entry.Length
            }
            $destination = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $entry.FullName))
            if (-not (Test-IsDescendantPath -Root $resolvedRoot -Candidate $destination)) {
                throw "ZIP entry escapes the extraction root: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/')) {
                [System.IO.Directory]::CreateDirectory($destination) | Out-Null
                continue
            }
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null
            $inputStream = $entry.Open()
            $outputStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew)
            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $inputStream.Dispose()
                $outputStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-FabFileManifest {
    param(
        [Parameter(Mandatory)]
        [string]$PluginRoot
    )

    return @(Get-OrdinalSortedTreeFile -Root $PluginRoot | ForEach-Object {
            $stream = [System.IO.File]::OpenRead($_.FullName)
            $algorithm = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hash = $algorithm.ComputeHash($stream)
            }
            finally {
                $algorithm.Dispose()
                $stream.Dispose()
            }
            [pscustomobject]@{
                path   = $_.RelativePath
                size   = $_.Length
                sha256 = [System.Convert]::ToHexString($hash).ToLowerInvariant()
            }
        })
}

function Assert-FabManifestsEqual {
    param(
        [Parameter(Mandatory)]
        [object[]]$Expected,

        [Parameter(Mandatory)]
        [object[]]$Actual
    )

    $expectedJson = $Expected | ConvertTo-Json -Depth 10 -Compress
    $actualJson = $Actual | ConvertTo-Json -Depth 10 -Compress
    if ($expectedJson -cne $actualJson) {
        throw 'Staged and extracted SHA-256 manifests do not match.'
    }
}

function Invoke-ReleaseGate {
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ReleaseLog -LogPath $Context.LogPath -Message "GATE START: $Name"
    try {
        $result = & $Action
        $stopwatch.Stop()
        $Context.Report.gates.Add([ordered]@{
                name                 = $Name
                status               = 'PASS'
                diagnostics          = @()
                durationMilliseconds = $stopwatch.ElapsedMilliseconds
            })
        Write-ReleaseLog -LogPath $Context.LogPath -Message "GATE PASS: $Name"
        return $result
    }
    catch {
        $stopwatch.Stop()
        $Context.Report.gates.Add([ordered]@{
                name                 = $Name
                status               = 'FAIL'
                diagnostics          = @($_.Exception.Message)
                durationMilliseconds = $stopwatch.ElapsedMilliseconds
            })
        Write-ReleaseLog -LogPath $Context.LogPath -Message "GATE FAIL: $Name - $($_.Exception.Message)"
        throw
    }
}

function Write-ReleaseReport {
    param(
        [Parameter(Mandatory)]
        [object]$Report,

        [Parameter(Mandatory)]
        [string]$ReportPath
    )

    $json = $Report | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $ReportPath,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
}

function Complete-ReportTiming {
    param(
        [Parameter(Mandatory)]
        [object]$Report,

        [Parameter(Mandatory)]
        [DateTimeOffset]$StartedAt
    )

    $completedAt = [DateTimeOffset]::UtcNow
    $Report.completedAtUtc = $completedAt.ToString('O')
    $Report.durationSeconds = [Math]::Round(($completedAt - $StartedAt).TotalSeconds, 3)
}

function Invoke-FabPluginReleaseCore {
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

        [switch]$KeepWorkingDirectory,

        [scriptblock]$AfterZipCreated
    )

    $startedAt = [DateTimeOffset]::UtcNow
    $requestedEngineRoot = $EngineRoot
    $requestedOutputDirectory = $OutputDirectory
    $zipInspectionHook = $AfterZipCreated
    $resolvedPluginPath = [System.IO.Path]::GetFullPath($PluginPath).TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $resolvedPluginPath 'FabPluginRelease.json'
    }
    $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $sessionRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
        "fab-plugin-release-tools\$([guid]::NewGuid().ToString('D'))")
    [System.IO.Directory]::CreateDirectory($sessionRoot) | Out-Null
    $sessionLogPath = Join-Path $sessionRoot 'release.log'
    [System.IO.File]::WriteAllText($sessionLogPath, '', [System.Text.UTF8Encoding]::new($false))

    $fallbackName = [System.IO.Path]::GetFileName($resolvedPluginPath)
    $fallbackOutput = Join-Path $PSScriptRoot "artifacts\$fallbackName\UE$EngineVersion"
    $report = [ordered]@{
        toolVersion      = $script:ToolVersion
        status           = 'RUNNING'
        startedAtUtc     = $startedAt.ToString('O')
        completedAtUtc   = $null
        durationSeconds  = $null
        pluginPath       = $resolvedPluginPath
        configPath       = $resolvedConfigPath
        pluginName       = $null
        versionName      = $null
        repositoryHead   = $null
        repositoryBranch = $null
        repositoryRemote = $null
        engineRoot       = $null
        engineVersion    = $EngineVersion
        platforms        = @('Win64')
        outputZip        = $null
        zipSize          = $null
        zipSha256        = $null
        manifestFileCount = $null
        gates            = [System.Collections.Generic.List[object]]::new()
        urls             = [System.Collections.Generic.List[object]]::new()
        build            = [ordered]@{
            command  = $null
            exitCode = $null
            timedOut = $false
            warnings = @()
        }
        workingDirectory = if ($KeepWorkingDirectory) { $sessionRoot } else { $null }
    }
    $context = [pscustomobject]@{
        LogPath      = $sessionLogPath
        OutputPath   = $fallbackOutput
        Report       = $report
        FinalZipPath = $null
        HashPath     = $null
        ReportPath   = $null
    }

    try {
        $preflight = Invoke-ReleaseGate -Context $context `
            -Name '1. Environment, Git, configuration, engine, and URL preflight' -Action {
            if (-not $IsWindows) {
                throw 'fab-plugin-release-tools supports Windows only.'
            }
            if ($PSVersionTable.PSVersion -lt [version]'7.4.0') {
                throw "PowerShell 7.4 or later is required. Current: $($PSVersionTable.PSVersion)"
            }
            $configuration = Import-FabPluginReleaseConfiguration `
                -ConfigPath $resolvedConfigPath -EngineVersion $EngineVersion
            $resolvedOutput = if ([string]::IsNullOrWhiteSpace($requestedOutputDirectory)) {
                Join-Path $PSScriptRoot "artifacts\$($configuration.pluginName)\UE$EngineVersion"
            }
            else {
                [System.IO.Path]::GetFullPath($requestedOutputDirectory)
            }
            if ($resolvedOutput.TrimEnd('\', '/').Equals(
                    $resolvedPluginPath,
                    [System.StringComparison]::OrdinalIgnoreCase) -or
                (Test-IsDescendantPath -Root $resolvedPluginPath -Candidate $resolvedOutput)) {
                throw 'OutputDirectory must not be the plugin root or any directory below it.'
            }
            [System.IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
            $context.OutputPath = $resolvedOutput
            $git = Get-GitRepositoryInformation -PluginPath $resolvedPluginPath
            $resolvedEngine = Resolve-FabEngineRoot -EngineVersion $EngineVersion -EngineRoot $requestedEngineRoot
            $urlResults = @(
                Test-FabHttpsUrl -Url ([string]$configuration.documentationUrl)
                Test-FabHttpsUrl -Url ([string]$configuration.supportUrl)
            )
            [pscustomobject]@{
                Configuration = $configuration
                Git           = $git
                EngineRoot    = $resolvedEngine
                UrlResults    = $urlResults
            }
        }
        $configuration = $preflight.Configuration
        $report.pluginName = [string]$configuration.pluginName
        $report.repositoryHead = $preflight.Git.Head
        $report.repositoryBranch = $preflight.Git.Branch
        $report.repositoryRemote = $preflight.Git.Remote
        $report.engineRoot = $preflight.EngineRoot
        foreach ($urlResult in @($preflight.UrlResults)) { $report.urls.Add($urlResult) }

        $sourceDescriptor = Invoke-ReleaseGate -Context $context `
            -Name '2. Source repository static validation' -Action {
            $descriptorPath = Join-Path $resolvedPluginPath $configuration.descriptorFile
            $descriptor = Read-PluginDescriptor -DescriptorPath $descriptorPath
            Assert-SourcePluginDescriptor -Descriptor $descriptor -Configuration $configuration
            Test-SourceCopyright -PluginPath $resolvedPluginPath `
                -ExpectedNotice ([string]$configuration.publisher.copyrightNotice)
            Test-UnrealCategorySpecifier -PluginPath $resolvedPluginPath
            $descriptor
        }
        $report.versionName = [string]$sourceDescriptor.VersionName

        $stagedPluginRoot = Join-Path $sessionRoot "staged\$($configuration.pluginName)"
        $buildInputPluginRoot = Join-Path $sessionRoot "build-input\$($configuration.pluginName)"
        $buildOutputRoot = Join-Path $sessionRoot 'build-output'
        $extractedRoot = Join-Path $sessionRoot 'extracted'

        Invoke-ReleaseGate -Context $context -Name '3. Allowlist sales staging' -Action {
            Copy-FabPluginAllowList -PluginPath $resolvedPluginPath `
                -DestinationRoot $stagedPluginRoot -Configuration $configuration
        }
        Invoke-ReleaseGate -Context $context -Name '4. Sales descriptor normalization' -Action {
            $stagedDescriptorPath = Join-Path $stagedPluginRoot $configuration.descriptorFile
            [void](ConvertTo-SalesPluginDescriptor -SourceDescriptor $sourceDescriptor `
                    -Configuration $configuration -EngineVersion $EngineVersion `
                    -DestinationPath $stagedDescriptorPath)
        }
        Invoke-ReleaseGate -Context $context -Name '5. Complete staged package validation' -Action {
            Assert-FabPackage -PluginRoot $stagedPluginRoot `
                -Configuration $configuration -EngineVersion $EngineVersion
        }
        $buildResult = Invoke-ReleaseGate -Context $context -Name '6. UAT BuildPlugin' -Action {
            Invoke-UatBuildPlugin -EngineRoot $preflight.EngineRoot `
                -StagedPluginRoot $stagedPluginRoot -BuildInputPluginRoot $buildInputPluginRoot `
                -BuildOutputRoot $buildOutputRoot -Configuration $configuration `
                -EngineVersion $EngineVersion -LogPath $context.LogPath -BuildReport $report.build
        }
        $report.build.command = $buildResult.command
        $report.build.exitCode = $buildResult.exitCode
        $report.build.timedOut = $buildResult.timedOut
        $report.build.warnings = @($buildResult.warnings)

        $temporaryZip = Join-Path $sessionRoot 'candidate.zip'
        Invoke-ReleaseGate -Context $context -Name '7. Deterministic ZIP creation' -Action {
            New-DeterministicFabZip -PluginRoot $stagedPluginRoot `
                -PluginName ([string]$configuration.pluginName) -ZipPath $temporaryZip
        }
        Invoke-ReleaseGate -Context $context -Name '8. Direct ZIP structure validation' -Action {
            if ($null -ne $zipInspectionHook) {
                & $zipInspectionHook $temporaryZip
            }
            Assert-FabZipDirectly -ZipPath $temporaryZip `
                -Configuration $configuration -EngineVersion $EngineVersion
        }
        Invoke-ReleaseGate -Context $context -Name '9. Safe ZIP extraction' -Action {
            Expand-FabZipSafely -ZipPath $temporaryZip -DestinationRoot $extractedRoot
        }
        $extractedPluginRoot = Join-Path $extractedRoot $configuration.pluginName
        Invoke-ReleaseGate -Context $context -Name '10. Extracted package revalidation' -Action {
            Assert-FabPackage -PluginRoot $extractedPluginRoot `
                -Configuration $configuration -EngineVersion $EngineVersion
        }
        $stagedManifest = @(Invoke-ReleaseGate -Context $context `
            -Name '11. SHA-256 manifest comparison' -Action {
            $expectedManifest = @(Get-FabFileManifest -PluginRoot $stagedPluginRoot)
            $actualManifest = @(Get-FabFileManifest -PluginRoot $extractedPluginRoot)
            Assert-FabManifestsEqual -Expected $expectedManifest -Actual $actualManifest
            $expectedManifest
        })

        Invoke-ReleaseGate -Context $context -Name '12. Artifact finalization' -Action {
            $zipName = "$($configuration.pluginName)_$($sourceDescriptor.VersionName)_UE${EngineVersion}_Win64.zip"
            $finalZip = Join-Path $context.OutputPath $zipName
            $hashPath = "$finalZip.sha256"
            $reportPath = "$finalZip.report.json"
            $finalLog = "$finalZip.log"
            foreach ($artifactPath in @($finalZip, $hashPath, $reportPath, $finalLog)) {
                if ([System.IO.File]::Exists($artifactPath)) {
                    throw "Refusing to overwrite an existing release artifact: $artifactPath"
                }
            }
            [System.IO.File]::Move($temporaryZip, $finalZip)
            $context.FinalZipPath = $finalZip
            $context.HashPath = $hashPath
            $context.ReportPath = $reportPath
            [System.IO.File]::Move($context.LogPath, $finalLog)
            $context.LogPath = $finalLog
            $zipHash = (Get-FileHash -LiteralPath $finalZip -Algorithm SHA256).Hash.ToLowerInvariant()
            [System.IO.File]::WriteAllText(
                $hashPath,
                "$zipHash  $zipName" + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false))
            $report.outputZip = $finalZip
            $report.zipSize = ([System.IO.FileInfo]::new($finalZip)).Length
            $report.zipSha256 = $zipHash
            $report.manifestFileCount = $stagedManifest.Count
        }

        $report.status = 'PASS'
        Complete-ReportTiming -Report $report -StartedAt $startedAt
        Write-ReleaseReport -Report $report -ReportPath $context.ReportPath
        Write-ReleaseLog -LogPath $context.LogPath -Message 'Release pipeline completed successfully.'
    }
    catch {
        $originalError = $_
        $report.status = 'FAIL'
        Complete-ReportTiming -Report $report -StartedAt $startedAt
        [System.IO.Directory]::CreateDirectory($context.OutputPath) | Out-Null
        foreach ($artifactPath in @($context.FinalZipPath, $context.HashPath, $context.ReportPath)) {
            if (-not [string]::IsNullOrWhiteSpace($artifactPath) -and [System.IO.File]::Exists($artifactPath)) {
                [System.IO.File]::SetAttributes($artifactPath, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($artifactPath)
            }
        }
        $report.outputZip = $null
        $report.zipSize = $null
        $report.zipSha256 = $null
        $failureId = [guid]::NewGuid().ToString('N')
        $failureBase = Join-Path $context.OutputPath "FabPluginRelease_FAILED_UE${EngineVersion}_$failureId"
        $failureLog = "$failureBase.log"
        if ([System.IO.File]::Exists($context.LogPath)) {
            if ([System.IO.Path]::GetFullPath($context.LogPath) -cne [System.IO.Path]::GetFullPath($failureLog)) {
                [System.IO.File]::Move($context.LogPath, $failureLog)
            }
        }
        else {
            [System.IO.File]::WriteAllText($failureLog, '', [System.Text.UTF8Encoding]::new($false))
        }
        $context.LogPath = $failureLog
        Write-ReleaseLog -LogPath $context.LogPath -Message "Release pipeline failed: $($originalError.Exception.Message)"
        $failureReport = "$failureBase.report.json"
        Write-ReleaseReport -Report $report -ReportPath $failureReport
        throw $originalError
    }
    finally {
        if (-not $KeepWorkingDirectory) {
            Remove-SessionDirectory -SessionRoot $sessionRoot -Confirm:$false
        }
    }
}

function Invoke-FabPluginRelease {
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

    $arguments = @{
        PluginPath           = $PluginPath
        EngineVersion        = $EngineVersion
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
    Invoke-FabPluginReleaseCore @arguments
}

Export-ModuleMember -Function Invoke-FabPluginRelease
