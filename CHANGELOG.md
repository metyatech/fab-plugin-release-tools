# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

## [0.7.8] - 2026-09-11

- Fail listing preparation early when `support_url` is not represented in the
  buyer-visible `long_description` required by Fab Portal support verification.

## [0.7.7] - 2026-09-11

- Stopped inferring an exact Fab `numberOfCppClasses` value from C++ source
  syntax; the field remains schema-validated seller-authored metadata.

## [0.7.6] - 2026-09-11

- Made R2 project-file publication content-addressed by package SHA-256.
- Allowed verified immutable republish links to atomically replace an existing
  complete `project_file_links` set without overwriting old R2 objects.

## [0.7.5] - 2026-09-11

- Made distributed-source Fab executable/installer review scanning
  case-insensitive for Source paths, ThirdParty paths, and source extensions.
- Added regression coverage for mixed-case Source, ThirdParty, C++, and
  Build.cs paths.

## [0.7.4] - 2026-09-11

- Added built-in rejection for known Fab-unsupported executable, installer, and
  archive formats in staged packages and direct ZIP entries.
- Added a distributed-source review-risk gate for executable and installer
  references, including `UnrealEditor.exe` literals.
- Kept `.dll` files allowed by the built-in unsupported-format rule for valid
  third-party compiled code-plugin dependencies.
- Fixed submission preflight failure handling so `FAB SUBMISSION CHECK: FAIL`
  is emitted reliably before exit code 1 regardless of the localized schema
  error text.

## [0.7.3] - 2026-09-11

- Added structured `descriptionLinks` metadata so Description source text stays
  human-readable while hyperlink semantics remain explicit.
- Validated actual persisted Fab Description anchors and exact HTTPS hrefs;
  literal Markdown link text does not satisfy hyperlink verification.
- Kept CDP backward compatible and retained interactive-browser observation as
  an offline, non-cryptographic verification transport.

## [0.7.2] - 2026-09-11

- Preserved meaningful paragraph, heading, and list-line structure when
  comparing Fab Description text.
- Rejected flattened one-line Portal descriptions while continuing to ignore
  harmless line-ending, spacing, and trailing-whitespace differences.
- Counted authored C++ class definitions across shipped headers and source files
  when validating Fab Technical Information metadata.

## [0.7.1] - 2026-09-11

- Aligned Draft verification with Fab field lifecycle ownership.
- Deferred activation to the Submit-for-review decision and treated
  short-description metadata as source-only when no distinct Draft field is
  exposed.
- Derived support verification from the buyer-visible Description and allowed
  Fab-generated tag extras while still requiring every desired tag.
- Kept CDP optional and added no Cloudflare bypass behavior.

## [0.7.0] - 2026-09-11

- Added strict, hash-bound `FabPortalObservation.json` support for interactive
  browser collection and offline central comparison.
- Kept CDP collection available while making it optional for read-only portal
  verification.

## [0.6.0] - 2026-09-10

- Added centralized Fab media technical validation and a hash-bound human
  media approval gate.
- Added guarded submission preparation, Cloudflare R2 project-file
  publication, authoritative listing ID synchronization, and the temporary
  Unreal Editor capture harness.

## [0.5.0] - 2026-09-02

- Added canonical Fab TPS declaration validation and submission artifact
  generation to the product release workflow.

## [0.4.1] - 2026-08-29

- Added `DeveloperTool` as a supported Fab submission code-module type.

## [0.4.0] - 2026-08-14

- Added independent Fab submission metadata schema and preflight validation.
- Added hardcoded plugin-location detection and package license inventory reporting.
- Added copy-ready `FabTechnicalInformation.txt` generation.

## [0.3.1] - 2026-07-30

### Fixed

- Require ordered copyright notices to occupy consecutive physical lines.
- Allow only forward slashes in `sourceCopyrightOverrides.path`.
- Reject case-insensitive collisions among copyright validation paths.

## [0.3.0] - 2026-07-30

### Added

- Added file-specific ordered copyright notice sequences while retaining the
  publisher notice as the default and requiring it as the final override
  notice.
- Added strict rejection of missing, unused, and case-mismatched overrides.
- Added the Runtime Asset Import example's Epic Games and metyatech sequence
  for its two Unreal template-derived files.

## [0.2.0] - 2026-07-29

### Added

- Added the `plugin` content mode for standard code-plugin Content layouts.
- Added `agent-ruleset.json` and generated `AGENTS.md` using the `generic`
  profile.

### Fixed

- Updated the Runtime Asset Import example to use its direct Content asset
  path and centralized documentation URL.

## [0.1.2] - 2026-07-23

### Fixed

- Rejected plugin paths with a reparse point anywhere between the volume or UNC share root and the plugin directory.

## [0.1.1] - 2026-07-23

### Fixed

- Redacted credentials, query strings, and fragments from report URLs and Git remotes.
- Rejected allowlisted paths whose parent chain contains a reparse point.
- Enforced JSON array types for source and sales plugin descriptors.
- Compared Windows Git repository paths without case sensitivity.
- Applied direct ZIP validation to empty directory entries.

## [0.1.0] - 2026-07-23

### Added

- Strict Fab plugin release configuration and schema.
- Source, package, Unreal Engine build, ZIP, and manifest validation pipeline.
- Pester and PSScriptAnalyzer verification with Windows GitHub Actions CI.
