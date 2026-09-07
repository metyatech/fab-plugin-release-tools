# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-FabPortalPathWithin {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Parent
    )

    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    return $pathFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($parentFull + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FabPortalChromeDefaultUserDataDirectory {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        [void]$candidates.Add((Join-Path $env:APPDATA 'Google\Chrome\User Data'))
    }
    return @($candidates | Select-Object -Unique)
}

function Resolve-FabPortalChromeUserDataDir {
    param(
        [string]$UserDataDir,

        [string]$WorkspaceRoot = $PSScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($UserDataDir)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; specify -UserDataDir explicitly.'
        }
        $UserDataDir = Join-Path $env:LOCALAPPDATA 'metyatech\FabPortalAutomation\ChromeProfile'
    }
    $resolved = [System.IO.Path]::GetFullPath($UserDataDir)
    foreach ($defaultDirectory in Get-FabPortalChromeDefaultUserDataDirectory) {
        if (Test-FabPortalPathWithin -Path $resolved -Parent $defaultDirectory) {
            throw "The Fab profile must not be the default Chrome user-data directory or a descendant: $resolved"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot) -and
        (Test-FabPortalPathWithin -Path $resolved -Parent $WorkspaceRoot)) {
        throw "The Fab profile must not be inside the repository workspace: $resolved"
    }
    if ([System.IO.File]::Exists($resolved)) {
        throw "The Fab profile path is a file, not a directory: $resolved"
    }
    return $resolved
}

function Get-FabPortalChromeExecutable {
    param([string]$ChromePath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ChromePath)) {
        [void]$candidates.Add($ChromePath)
    }
    else {
        foreach ($environmentName in @('ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')) {
            $base = [Environment]::GetEnvironmentVariable($environmentName)
            if (-not [string]::IsNullOrWhiteSpace($base)) {
                [void]$candidates.Add((Join-Path $base 'Google\Chrome\Application\chrome.exe'))
            }
        }
        $command = Get-Command 'chrome.exe' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) {
            [void]$candidates.Add($command.Source)
        }
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        $resolved = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
    }
    if ([string]::IsNullOrWhiteSpace($ChromePath)) {
        throw 'Google Chrome was not found in the standard Windows locations. Specify -ChromePath.'
    }
    throw "The specified Chrome executable does not exist: $ChromePath"
}

function Assert-FabPortalListingUrl {
    param([Parameter(Mandatory)][string]$ListingUrl)

    $uri = $null
    if (-not [System.Uri]::TryCreate($ListingUrl, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or
        $uri.Host -notin @('www.fab.com', 'fab.com') -or
        -not $uri.AbsolutePath.StartsWith('/portal/listings/', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw 'ListingUrl must be a query-free HTTPS Fab portal listing URL.'
    }
    return $uri.AbsoluteUri
}

function Get-FabPortalChromeArgumentList {
    param(
        [Parameter(Mandatory)]
        [string]$UserDataDir,

        [Parameter(Mandatory)]
        [string]$ListingUrl,

        [ValidateSet('Automation', 'ManualLogin')]
        [string]$Mode = 'Automation'
    )

    $safeUrl = Assert-FabPortalListingUrl -ListingUrl $ListingUrl
    $arguments = [System.Collections.Generic.List[string]]::new()
    [void]$arguments.Add(('--user-data-dir="{0}"' -f $UserDataDir))
    if ($Mode -eq 'Automation') {
        [void]$arguments.Add('--remote-debugging-address=127.0.0.1')
        [void]$arguments.Add('--remote-debugging-port=0')
    }
    [void]$arguments.Add('--no-first-run')
    [void]$arguments.Add('--no-default-browser-check')
    [void]$arguments.Add('--new-window')
    [void]$arguments.Add($safeUrl)
    return $arguments.ToArray()
}

function Read-FabPortalDevToolsActivePort {
    param(
        [Parameter(Mandatory)][string]$UserDataDir,

        [switch]$RequireWebSocketPath
    )

    $path = Join-Path $UserDataDir 'DevToolsActivePort'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop)
    if ($lines.Count -lt 1 -or $lines.Count -gt 2) {
        throw "DevToolsActivePort is malformed: $path"
    }
    $port = 0
    if (-not [int]::TryParse($lines[0].Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "DevToolsActivePort contains an invalid port: $path"
    }
    $webSocketPath = if ($lines.Count -eq 2) { $lines[1].Trim() } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($webSocketPath) -and
        -not $webSocketPath.StartsWith('/devtools/', [System.StringComparison]::Ordinal)) {
        throw "DevToolsActivePort contains an invalid websocket path: $path"
    }
    if ($RequireWebSocketPath -and [string]::IsNullOrWhiteSpace($webSocketPath)) {
        throw "DevToolsActivePort is missing the browser websocket path: $path"
    }
    return [pscustomobject]@{
        Port           = $port
        WebSocketPath  = $webSocketPath
        Path           = $path
    }
}

function Get-FabPortalChromeProfileLockPath {
    param([Parameter(Mandatory)][string]$UserDataDir)

    return @('SingletonLock', 'SingletonCookie', 'SingletonSocket' | ForEach-Object {
        Join-Path $UserDataDir $_
    })
}

function Test-FabPortalChromeProfileLocked {
    param([Parameter(Mandatory)][string]$UserDataDir)

    return @(
        Get-FabPortalChromeProfileLockPath -UserDataDir $UserDataDir |
            Where-Object { Test-Path -LiteralPath $_ }
    ).Count -gt 0
}

function Remove-FabPortalStaleDevToolsActivePort {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][string]$UserDataDir,

        [scriptblock]$ProcessIdProvider
    )

    $path = Join-Path $UserDataDir 'DevToolsActivePort'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $false
    }
    if ($null -eq $ProcessIdProvider) {
        $ProcessIdProvider = { param($directory) Get-FabPortalChromeProcessIdsForUserDataDir -UserDataDir $directory }
    }
    $processIds = @(& $ProcessIdProvider $UserDataDir)
    if ($processIds.Count -gt 0) {
        throw 'Cannot remove DevToolsActivePort while a dedicated Chrome process is running.'
    }
    if (Test-FabPortalChromeProfileLocked -UserDataDir $UserDataDir) {
        throw 'Cannot remove DevToolsActivePort while the dedicated Chrome profile is locked.'
    }
    if (-not $PSCmdlet.ShouldProcess($path, 'Remove stale Chrome debug metadata')) {
        return $false
    }
    [System.IO.File]::Delete($path)
    return $true
}

function Test-FabPortalDevToolsActivePortFresh {
    param(
        [Parameter(Mandatory)][string]$UserDataDir,

        [Parameter(Mandatory)][DateTime]$NotBeforeUtc
    )

    $path = Join-Path $UserDataDir 'DevToolsActivePort'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.LastWriteTimeUtc -lt $NotBeforeUtc.ToUniversalTime()) {
        return $null
    }
    return Read-FabPortalDevToolsActivePort -UserDataDir $UserDataDir -RequireWebSocketPath
}

function Test-FabPortalChromeEndpoint {
    param(
        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 1000
    )

    try {
        $response = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/version" -f $Port) `
            -Method Get -TimeoutSec ([Math]::Max(1, [int][Math]::Ceiling($TimeoutMilliseconds / 1000)))
        $webSocketUrl = [string]$response.webSocketDebuggerUrl
        $browser = [string]$response.Browser
        if ([string]::IsNullOrWhiteSpace($webSocketUrl) -or
            -not ($webSocketUrl.StartsWith('ws://') -or $webSocketUrl.StartsWith('wss://')) -or
            [string]::IsNullOrWhiteSpace($browser)) {
            return $null
        }
        return [pscustomobject]@{
            Ready               = $true
            Browser             = $browser
            WebSocketDebuggerUrl = $webSocketUrl
            Metadata            = $response
        }
    }
    catch {
        return $null
    }
}

function Get-FabPortalChromeProcessIdsForUserDataDir {
    param([Parameter(Mandatory)][string]$UserDataDir)

    $normalized = ([System.IO.Path]::GetFullPath($UserDataDir)).TrimEnd('\', '/').Replace('/', '\')
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction Stop)
    $ids = foreach ($process in $processes) {
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { continue }
        $normalizedCommandLine = $commandLine.Replace('/', '\')
        if ($normalizedCommandLine -match ('--user-data-dir="?' + [regex]::Escape($normalized) + '"?(?:\s|$)') -and
            $normalizedCommandLine -notmatch '(?:^|\s)--type=') {
            [int]$process.ProcessId
        }
    }
    return @($ids | Sort-Object -Unique)
}

function Get-FabPortalChromeSession {
    param(
        [Parameter(Mandatory)]
        [string]$UserDataDir,

        [scriptblock]$EndpointProbe,

        [scriptblock]$ProcessIdProvider
    )

    $activePort = Read-FabPortalDevToolsActivePort -UserDataDir $UserDataDir
    if ($null -eq $activePort) { return $null }
    if ($null -eq $EndpointProbe) {
        $EndpointProbe = { param($port) Test-FabPortalChromeEndpoint -Port $port }
    }
    if ($null -eq $ProcessIdProvider) {
        $ProcessIdProvider = { param($directory) Get-FabPortalChromeProcessIdsForUserDataDir -UserDataDir $directory }
    }
    $probe = & $EndpointProbe $activePort.Port
    if ($null -eq $probe -or -not $probe.Ready) {
        $processIds = @(& $ProcessIdProvider $UserDataDir)
        if ($processIds.Count -gt 0) {
            throw 'A dedicated Chrome process exists, but its CDP endpoint is not healthy.'
        }
        throw 'DevToolsActivePort exists, but the owning Chrome session cannot be proven.'
    }
    $processIds = @(& $ProcessIdProvider $UserDataDir)
    if ($processIds.Count -ne 1) {
        throw "The dedicated Chrome session is ambiguous; expected one matching process, found $($processIds.Count)."
    }
    return [pscustomobject]@{
        CdpEndpoint          = "http://127.0.0.1:$($activePort.Port)"
        ChromeProcessId      = [int]$processIds[0]
        UserDataDir           = [System.IO.Path]::GetFullPath($UserDataDir)
        Browser               = [string]$probe.Browser
        WebSocketDebuggerUrl  = [string]$probe.WebSocketDebuggerUrl
        Reused                = $true
        Launched              = $false
    }
}

function Wait-FabPortalChromeSession {
    param(
        [Parameter(Mandatory)]
        [string]$UserDataDir,

        [Parameter(Mandatory)]
        [int]$ProcessId,

        [double]$TimeoutSeconds = 30,

        [DateTime]$MetadataNotBeforeUtc = [DateTime]::MinValue,

        [scriptblock]$EndpointProbe,

        [scriptblock]$ProcessIdProvider
    )

    if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be greater than zero.' }
    if ($null -eq $EndpointProbe) {
        $EndpointProbe = { param($port) Test-FabPortalChromeEndpoint -Port $port }
    }
    if ($null -eq $ProcessIdProvider) {
        $ProcessIdProvider = { param($directory) Get-FabPortalChromeProcessIdsForUserDataDir -UserDataDir $directory }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $activePort = Test-FabPortalDevToolsActivePortFresh -UserDataDir $UserDataDir `
            -NotBeforeUtc $MetadataNotBeforeUtc
        if ($null -ne $activePort) {
            $probe = & $EndpointProbe $activePort.Port
            if ($null -ne $probe -and $probe.Ready) {
                $processIds = @(& $ProcessIdProvider $UserDataDir)
                if ($processIds.Count -ne 1) {
                    throw "The dedicated Chrome session is ambiguous; expected one matching process, found $($processIds.Count)."
                }
                if ([int]$processIds[0] -ne $ProcessId) {
                    throw 'The launched Chrome process does not own the discovered CDP endpoint.'
                }
                return [pscustomobject]@{
                    CdpEndpoint          = "http://127.0.0.1:$($activePort.Port)"
                    ChromeProcessId      = $ProcessId
                    UserDataDir           = [System.IO.Path]::GetFullPath($UserDataDir)
                    Browser               = [string]$probe.Browser
                    WebSocketDebuggerUrl  = [string]$probe.WebSocketDebuggerUrl
                    Reused                = $false
                    Launched              = $true
                }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out after $TimeoutSeconds seconds waiting for dedicated Chrome CDP readiness."
}

function Start-FabPortalChromeSession {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [string]$ListingUrl = 'https://www.fab.com/portal/listings/96fc1bdc-71ea-4b80-8c68-e08ae430a2a8/edit',

        [string]$UserDataDir,

        [string]$ChromePath,

        [ValidateSet('Automation', 'ManualLogin')]
        [string]$Mode = 'Automation',

        [int]$ReadyTimeoutSeconds = 30
    )

    $workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $resolvedUserDataDir = Resolve-FabPortalChromeUserDataDir -UserDataDir $UserDataDir `
        -WorkspaceRoot $workspaceRoot
    $safeListingUrl = Assert-FabPortalListingUrl -ListingUrl $ListingUrl
    $matchingProcesses = @(Get-FabPortalChromeProcessIdsForUserDataDir -UserDataDir $resolvedUserDataDir)
    if ($Mode -eq 'Automation') {
        if ($matchingProcesses.Count -gt 0) {
            $existing = Get-FabPortalChromeSession -UserDataDir $resolvedUserDataDir
            if ($null -ne $existing) { return $existing }
        }
    }
    if ($matchingProcesses.Count -gt 0) {
        throw 'A Chrome process already uses the dedicated profile; close it manually before starting another mode.'
    }
    $metadataBaselineUtc = [DateTime]::UtcNow
    if ($Mode -eq 'Automation') {
        if (-not $PSCmdlet.ShouldProcess((Join-Path $resolvedUserDataDir 'DevToolsActivePort'), 'Remove stale Chrome debug metadata')) {
            return $null
        }
        [void](Remove-FabPortalStaleDevToolsActivePort -UserDataDir $resolvedUserDataDir -Confirm:$false)
    }
    if (-not $PSCmdlet.ShouldProcess($resolvedUserDataDir, 'Launch dedicated Chrome')) {
        return $null
    }
    [System.IO.Directory]::CreateDirectory($resolvedUserDataDir) | Out-Null
    $chrome = Get-FabPortalChromeExecutable -ChromePath $ChromePath
    $arguments = Get-FabPortalChromeArgumentList -UserDataDir $resolvedUserDataDir `
        -ListingUrl $safeListingUrl -Mode $Mode
    $process = Start-Process -FilePath $chrome -ArgumentList $arguments -PassThru
    if ($Mode -eq 'ManualLogin') {
        return [pscustomobject]@{
            Mode                    = 'manual-login'
            UserDataDir             = $resolvedUserDataDir
            ChromeProcessId         = $process.Id
            RemoteDebuggingEnabled  = $false
            Launched                = $true
            Reused                  = $false
        }
    }
    return Wait-FabPortalChromeSession -UserDataDir $resolvedUserDataDir `
        -ProcessId $process.Id -TimeoutSeconds $ReadyTimeoutSeconds `
        -MetadataNotBeforeUtc $metadataBaselineUtc
}

Export-ModuleMember -Function @(
    'Assert-FabPortalListingUrl',
    'Get-FabPortalChromeDefaultUserDataDirectory',
    'Get-FabPortalChromeExecutable',
    'Get-FabPortalChromeProcessIdsForUserDataDir',
    'Get-FabPortalChromeSession',
    'Get-FabPortalChromeArgumentList',
    'Read-FabPortalDevToolsActivePort',
    'Remove-FabPortalStaleDevToolsActivePort',
    'Resolve-FabPortalChromeUserDataDir',
    'Start-FabPortalChromeSession',
    'Test-FabPortalChromeEndpoint',
    'Test-FabPortalPathWithin',
    'Test-FabPortalChromeProfileLocked',
    'Test-FabPortalDevToolsActivePortFresh',
    'Wait-FabPortalChromeSession')
