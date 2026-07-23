# Fab Plugin Release Tools

Fab Plugin Release Tools is a Windows-only PowerShell pipeline for preparing
Unreal Engine code plugins for Fab. One command validates the repository and
configuration, stages only approved files, runs a real UAT `BuildPlugin`, makes
a deterministic submission ZIP, opens and validates that ZIP, safely extracts
it, and proves the extracted files match the staged files by SHA-256.

The tool automates known technical requirements and a real compile. It does not
guarantee acceptance by Fab's human review. Product descriptions, media,
third-party software declarations in the portal, pricing, and other portal-only
submission work remain manual.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7.4 or later
- Git on `PATH`
- An installed matching Unreal Engine version with UAT
- A clean plugin Git repository with an `origin` remote

## Install

Clone this repository and bootstrap the pinned development dependencies:

```powershell
git clone https://github.com/metyatech/fab-plugin-release-tools.git
Set-Location fab-plugin-release-tools
pwsh .\Build.ps1 -Task Bootstrap
```

Add a `FabPluginRelease.json` file to the root of each plugin repository. Start
from [the Runtime Asset Import example](examples/RuntimeAssetImport/FabPluginRelease.json)
and adapt its explicit allowlists. Every property is documented in
[Configuration](docs/CONFIGURATION.md).

## Release a plugin

```powershell
pwsh .\Invoke-FabPluginRelease.ps1 `
  -PluginPath ..\ServerManageToolPlugin `
  -EngineVersion 5.8
```

Required parameters:

- `-PluginPath`: plugin repository root. It must exactly equal the Git root.
- `-EngineVersion`: Unreal Engine `5.x` version allowed by the configuration.

Optional parameters:

- `-EngineRoot`: engine root, or a parent containing `UE_<version>`.
- `-ConfigPath`: defaults to `<PluginPath>\FabPluginRelease.json`.
- `-OutputDirectory`: defaults to
  `artifacts\<pluginName>\UE<EngineVersion>` in this tool repository.
- `-KeepWorkingDirectory`: retain the GUID session directory for diagnostics.

The engine root is resolved in this order: `-EngineRoot`,
`FAB_PLUGIN_RELEASE_ENGINE_ROOT`, matching Epic Games Launcher manifests, then
`C:\Program Files\Epic Games\UE_<version>`. Ambiguous results are rejected.

The process exits `0` on success and `1` on failure. Its final console line is
always `FAB PLUGIN RELEASE: PASS` or `FAB PLUGIN RELEASE: FAIL`.

## Release gates

The command runs these gates in order and stops at the first failure:

1. Windows, PowerShell, Git, strict JSON configuration, Unreal Engine, and URL preflight
2. source descriptor, copyright, and Unreal API Category static validation
3. allowlist-only staging with reparse-point and size protection
4. sales descriptor normalization
5. complete staged package validation
6. real UAT `BuildPlugin` against a separate staging copy
7. deterministic ZIP creation
8. direct ZIP structure and descriptor validation
9. zip-slip-safe extraction
10. identical package validation on extracted content
11. staged/extracted byte-size and SHA-256 manifest comparison
12. atomic artifact finalization

There is no build-skip or validation-skip option.

## Outputs and failure behavior

A successful release writes:

- `<PluginName>_<VersionName>_UE<version>_Win64.zip`
- the same filename plus `.sha256`
- the same filename plus `.report.json`
- the same filename plus `.log`

On failure, the final ZIP and checksum are absent or removed, while a uniquely
named JSON report and log are retained. Session files are deleted unless
`-KeepWorkingDirectory` is used.

## Development

```powershell
pwsh .\Build.ps1 -Task Bootstrap
pwsh .\Build.ps1 -Task Test
pwsh .\Build.ps1 -Task Analyze
pwsh .\Build.ps1 -Task Verify
git config core.hooksPath .githooks
```

`Verify` is the canonical local and CI check. It runs Pester 5.9.0 and
PSScriptAnalyzer 1.25.0 without mutating tracked files. The repository hook
formats only staged PowerShell files and restages them before a commit.

## Migration note

Moving an existing plugin from a repository-specific `PackageForFab.ps1` to
this tool is separate work. Creating this repository does not modify Runtime
Asset Import or any other plugin repository.

## Versioning and release

This project uses Semantic Versioning. Breaking changes include incompatible
CLI parameters, configuration schema changes, package layout changes, or
different validation semantics. Releases are created from a verified clean
`master` commit and use a Git tag matching `FabPluginReleaseTools.psd1`.

## License

[MIT](LICENSE)
