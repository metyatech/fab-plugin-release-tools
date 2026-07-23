# Configuration

`FabPluginRelease.json` is a strict, schema-versioned contract. Unknown fields
are rejected at every object level. Paths are normalized internally to `/` and
must be relative, non-empty, free of wildcards, `.` and `..`, drive prefixes,
UNC prefixes, and trailing whitespace. Path arrays reject case-insensitive
duplicates.

The authoritative machine-readable definition is
[`FabPluginRelease.schema.json`](../FabPluginRelease.schema.json). A complete
example is in
[`examples/RuntimeAssetImport/FabPluginRelease.json`](../examples/RuntimeAssetImport/FabPluginRelease.json).

## Root properties

| Property | Type | Required | Allowed values and failure conditions |
| --- | --- | --- | --- |
| `schemaVersion` | integer | yes | Must be exactly `1`. |
| `pluginName` | string | yes | Starts with an ASCII letter or digit; remaining characters are ASCII letters, digits, or `_`. |
| `descriptorFile` | relative path | yes | Must exactly equal `<pluginName>.uplugin`. |
| `engineVersions` | string array | yes | Non-empty, unique `5.x` values; the requested engine must be present. |
| `platforms` | string array | yes | Version 1 requires exactly `["Win64"]`. |
| `distributionModules` | string array | yes | Non-empty and case-insensitively unique. Only these modules ship. |
| `enabledPluginDependencies` | string array | yes | Case-insensitively unique; use `[]` when there are no dependencies. |
| `publisher` | object | yes | Strict object described below. |
| `listingId` | string or null | yes | Lowercase UUID, or `null` when no listing is assigned. |
| `documentationUrl` | URL string | yes | Absolute HTTPS URL that returns HTTP 200-399 after redirects. |
| `supportUrl` | URL string | yes | Absolute HTTPS URL that returns HTTP 200-399 after redirects. |
| `content` | object | yes | Strict object described below. |
| `includeDirectories` | relative path array | yes | Only these directory trees are staged. Parent/child overlaps are rejected. |
| `includeFiles` | relative path array | yes | Only these files are staged. A file already under an included directory is rejected. |
| `requiredPackageFiles` | relative path array | yes | Each path must be a non-empty regular staged file. |
| `customDistributionPaths` | relative path array | yes | Exact non-standard paths represented in `Config/FilterPlugin.ini`. |
| `thirdPartyLicenseSets` | object array | yes | Exact license-file allowlists described below; use `[]` if none. |
| `forbiddenPackagePatterns` | regex string array | yes | Additional plugin-relative forbidden paths. Every regex must compile. |
| `buildLogFailPatterns` | regex string array | yes | Additional UAT log failure patterns. Every regex must compile. |

## `publisher`

| Property | Type | Required | Rule |
| --- | --- | --- | --- |
| `name` | string | yes | Non-empty descriptor publisher name. |
| `url` | URL string | yes | Absolute HTTPS publisher URL. |
| `copyrightNotice` | string | yes | Exact first non-empty line required in publisher source files. |

Example:

```json
{
  "name": "metyatech",
  "url": "https://github.com/metyatech",
  "copyrightNotice": "// Copyright (c) 2026 metyatech. All rights reserved."
}
```

## `content`

Use pack mode for a content plugin:

```json
{ "mode": "pack", "packFolder": "MyPlugin" }
```

`packFolder` must exactly match `pluginName`. `Content` must contain that one
directory and no other top-level item. All content segments must use ASCII
letters, digits, and underscores; file extensions may use dots. Paths longer
than 140 characters relative to `Content` fail.

Use none mode for a code-only plugin:

```json
{ "mode": "none" }
```

`packFolder` is forbidden and `Content` must not be staged in none mode.

## `thirdPartyLicenseSets`

Each object has exactly two required properties:

- `root`: plugin-relative directory to enumerate recursively.
- `files`: exact root-relative list of every allowed regular license file.

Missing, extra, empty, case-mismatched, or reparse-point license files fail.
The tool never guesses which third-party licenses should ship.

## `FilterPlugin.ini`

The file must contain one `[FilterPlugin]` section. Each custom file is written
as `/<path>` and each custom directory as `/<path>/...`. The configured and
actual sets must match exactly, including case, with no duplicates.

## Common failures

- A new JSON field was added without a schema-version change.
- A path is absolute, contains `..`, contains a wildcard, or differs only by case.
- `includeDirectories` overlap or `includeFiles` repeats directory content.
- The requested Unreal Engine version is not in `engineVersions`.
- A regex does not compile.
- A third-party license tree contains any unlisted file.
- The source descriptor's enabled dependencies differ from the configuration.
