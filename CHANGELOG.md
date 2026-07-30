# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

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
