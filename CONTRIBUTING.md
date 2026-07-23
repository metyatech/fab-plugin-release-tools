# Contributing

Open an issue before a large behavioral or schema change. Keep changes focused,
add Pester coverage for every changed contract, and update documentation in the
same pull request.

Run the canonical verification command before submitting:

```powershell
pwsh .\Build.ps1 -Task Bootstrap
pwsh .\Build.ps1 -Task Verify
```

Pull requests must pass CI and must not include generated ZIPs, reports, logs,
or test results.
