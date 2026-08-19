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

## Fab submission preflight

Portal Technical Information is kept separate from `FabPluginRelease.json`.
Each product repository carries a root `FabSubmissionMetadata.json`, which is
validated against [the submission metadata schema](FabSubmissionMetadata.schema.json)
and cross-checked against the plugin descriptor, release configuration, and
distribution source modules:

```powershell
pwsh .\Test-FabPluginSubmission.ps1 `
  -PluginPath ..\RuntimeAssetImportPlugin
```

On success, the command writes `FabTechnicalInformation.txt` under
`artifacts/<PluginName>/submission/`. The text is formatted for direct copying
into Fab's Technical Information fields. An optional `-PackageZipPath` reports
standalone license-related files as Review Required warnings and reports `.tps`
Third Party Software metadata separately; it never changes the meaning of
`thirdPartyLicenseSets` or fails a package solely because a license file exists.

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
compose-agentsmd
pwsh .\Build.ps1 -Task Bootstrap
```

`compose-agentsmd` synchronizes the repository's generated `AGENTS.md` from
`agent-ruleset.json`. Run it after cloning or when the selected rules source
changes; do not edit `AGENTS.md` by hand.

Add a `FabPluginRelease.json` file to the root of each plugin repository. Start
from [the Runtime Asset Import example](examples/RuntimeAssetImport/FabPluginRelease.json)
and adapt its explicit allowlists. Every property is documented in
[Configuration](docs/CONFIGURATION.md).

Documentation and support URLs must not contain user information. URL checks
use the configured URL for the request, but reports omit user information, the
entire query, and the fragment from both requested and redirected URLs. Reports
also omit user information, query, and fragment from absolute HTTP(S) Git
remote URLs; SCP-style remotes such as `git@github.com:owner/repo.git` are kept
unchanged.

## Release a product

The preferred product-level command reads every version in
`FabPluginRelease.json.engineVersions`, builds them in numeric Unreal minor
version order, runs submission preflight for every generated ZIP, and creates
one atomic `FabSubmission` bundle:

```powershell
pwsh .\Invoke-FabProductRelease.ps1 `
  -PluginPath ..\ServerManageToolPlugin
```

The product repository must also contain `FabListingFields.json` unless
`-ListingFieldsPath` is supplied. The file is validated by
[FabListingFields.schema.json](FabListingFields.schema.json). It contains the
listing copy, prices, booleans, ordered tags, per-engine metadata, and ordered
PNG/JPEG media. Existing listing files may retain additional useful metadata.
The required `subcategory` property is always an array: use `[]` when Fab has
no distinct subcategory below the selected category, or list the actual
subcategory values when Fab exposes them.
The engine versions, platforms, documentation URL, and support URL are
cross-checked against `FabPluginRelease.json`; media files must be regular
files below the plugin root. The first media file is the thumbnail and all
remaining files are gallery images.
An optional lowercase `listing_id` identifies an existing Fab listing for
browser automation. When present it takes precedence over `FabPluginRelease.json`
`listingId`; conflicting non-null values fail, and no ID is derived from the
listing title. `public_release_sha256` is an optional SHA-256 cross-check for a
single-engine legacy `project_file_link`.

Optional parameters are `-EngineRoot`, `-ListingFieldsPath`,
`-OutputDirectory`, `-KeepWorkingDirectory`, and `-PublishProjectFiles`.
`-OutputDirectory` is the artifact root; the default is this repository's
`artifacts` directory. Each run stages under
`<artifactRoot>/<pluginName>/.sessions/<guid>/` on the same volume as the final
bundle, so repeated runs do not collide with the lower-level release's
intentional no-overwrite behavior. Failed runs retain only reports and logs
under `<artifactRoot>/<pluginName>/failures/<guid>/`; a previous good bundle is
restored if finalization fails.

For a local validated bundle:

```powershell
pwsh .\Invoke-FabProductRelease.ps1 -PluginPath <path>
```

Without `-PublishProjectFiles`, project file links must be supplied in
`project_file_links` for every engine version. The legacy singular
`project_file_link` is accepted only for a one-version product. Missing links
leave `portalReady` false and are shown as PENDING in
`SubmissionChecklist.txt`; configured links are fetched unauthenticated with
bounded HTTPS redirects and streamed SHA-256 verification against the locally
generated ZIP. A failed transfer or hash mismatch fails the release; no URL is
invented.

For a portal-ready bundle with public project files:

```powershell
pwsh .\Invoke-FabProductRelease.ps1 `
  -PluginPath <path> `
  -PublishProjectFiles
```

`gh` is required only for `-PublishProjectFiles`. The local repository must be
clean, pushed, and match a public `source_repository_url` on GitHub. The
command creates or resumes the draft `fab-v<VersionName>` GitHub Release,
uploads only validated ZIPs without overwriting conflicting assets, verifies
GitHub SHA-256 digests, publishes the release, and verifies each public
`browser_download_url` without authentication. The release tag and
`sourceCommit` marker are bound to the exact validated, pushed local HEAD;
existing releases that resolve to another source commit fail before any remote
release mutation. Matching assets are reused on retry. A successful
`portalReady` value means every current automation field, media item, package,
and public project file link has passed validation.

`FabPortalSubmission.json` is the sole structured input contract for future
Playwright Fab Portal automation. Its paths are forward-slash paths relative
to `FabSubmission`; it does not require source inspection or heuristic file
discovery.

## Release one engine version

`Invoke-FabPluginRelease.ps1` remains the lower-level single-engine command:

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

Copyright validation uses `publisher.copyrightNotice` as the required single
notice for every source file by default. A configuration may add
`sourceCopyrightOverrides` for specific files below `Source/`; each override
must provide an ordered array of at least two unique, single-line notices, and
the final notice must be the publisher notice. Only the UTF-8 BOM and blank or
whitespace-only lines before the first notice are ignored. Every notice in the
sequence must then occupy consecutive physical lines; a blank line inside the
sequence fails, while blank lines or code after the completed sequence are
allowed. Missing, shifted, or reordered notices fail the release.
Overrides do not skip copyright validation, and wildcard paths and directory
paths are forbidden. Override files must exist as regular non-reparse files,
match their actual case, and be in the existing copyright scope. Source
`.Build.cs` files are always checked, including under `Source/ThirdParty/`;
C/C++ files under `Source/ThirdParty/` remain excluded.
Override paths must use `/` separators; backslashes are rejected rather than
converted. Copyright validation also rejects case-insensitive collisions
between target relative paths instead of allowing one file to overwrite
another in the index.

This technical gate does not make a legal determination about copyright
ownership or licensing. Reviewers remain responsible for the legal accuracy of
the configured notices and third-party declarations. Existing third-party
notices must not be removed or replaced unconditionally, and a notice with
unknown provenance must not be added to an override speculatively.

## Content modes

The configuration supports three strict content modes:

- `plugin` is for code plugins whose required assets live directly under
  `Content` or in any number of subdirectories. For example:

  ```json
  { "mode": "plugin" }
  ```

  ```text
  MyPlugin/
  ├─ Content/
  │  ├─ DefaultMaterial.uasset
  │  └─ UI/
  │     └─ DefaultIcon.uasset
  ├─ Config/
  ├─ Source/
  └─ MyPlugin.uplugin
  ```

- `pack` remains the strict mode for a content product with exactly one
  `Content/<PluginName>/` pack directory.
- `none` is for plugins that ship no `Content` at all.

Fab's single-pack-folder rule for content products is distinct from the
natural `Content` layout of a code plugin. Choose the mode that matches the
product structure; do not move code-plugin assets just to create a pack
folder.

Every existing directory element from the volume or UNC share root through
`PluginPath` is checked before Git and again before staging. A junction,
symbolic link, mount point, or other reparse point anywhere in that absolute
chain is rejected. Each allowlisted target also receives a separate path-chain
check from `PluginPath` through the target. Descriptor properties documented as
arrays must be JSON arrays; a scalar string or object cannot substitute for a
one-element array.

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

## Fab Portal automation

`FabPortalSubmission.json` is the sole production input to the guarded portal
automation. Install its pinned Node dependency with `npm ci` from
`FabPortalAutomation`, then connect to an already authenticated dedicated
Chrome CDP endpoint:

```powershell
pwsh .\Invoke-FabPortalSubmission.ps1 `
  -ManifestPath <FabPortalSubmission.json> `
  -CdpEndpoint <http://127.0.0.1:port>
```

The default is read-only verification. Explicit `-SaveDraft` enables a guarded
draft save, and `-SaveDraft -SubmitForReview` additionally enables submission.
Pending approval listings cannot be modified; Cancel submission is never
invoked automatically. The automation never handles Cloudflare, credentials,
MFA, or browser storage. If a visible Cloudflare/security challenge appears,
the automation enters a manual handoff: browser operations stop, you complete
the challenge in the dedicated Chrome, then press Enter here to resume. Use
`q` followed by Enter to cancel the run. A bounded number of handoff cycles is
allowed; a challenge after staged mutations fails safely and requires a clean
restart. Verify, Save Draft, and Submit modes all require exactly one already-
open target listing page; the automation does not create a tab or navigate to
repair the initial target before the handoff.

A verify-only `PASS` reports that observation completed without a proven
mismatch; it does not imply write readiness. The run report records
`writeReady` and `writeBlockers` when review-locked status or unresolved
critical fields would block a future write.

Save and submit safety requires every manifest-owned critical field to be
readable and either already matching or backed by an approved writable locator,
including descriptions, taxonomy, tags, format/engine/platform, license,
prices, AI/content flags, activation, URLs, Technical Information text, media,
and every package Project File Link. An empty `subcategory` is legitimately
`NOT_APPLICABLE` when Fab exposes no distinct subcategory. Existing media whose
identity cannot be proven remains a write blocker.

Submit-for-review uses a scoped confirmation-dialog state machine when Fab
requires confirmation. `submitInvoked` records execution of the final submit
action, while `submitAccepted` is true only after the listing is read back in
the accepted `Pending approval` state. Cancel submission is never used.

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
