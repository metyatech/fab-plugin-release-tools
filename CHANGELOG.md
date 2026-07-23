# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog and the project uses Semantic Versioning.

## [Unreleased]

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
