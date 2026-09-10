# Copyright (c) 2026 metyatech. All rights reserved.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:submissionScript = Join-Path $repositoryRoot 'Invoke-FabPortalSubmission.ps1'

Describe 'Fab portal write entrypoint policy' {
    It 'rejects Save Draft before browser attachment' {
        $output = (& pwsh -NoProfile -File $submissionScript -SaveDraft 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        $exitCode | Should -Not -Be 0
        $output | Should -Match 'Fab Portal write automation is disabled'
    }

    It 'rejects Submit for review before browser attachment' {
        $output = (& pwsh -NoProfile -File $submissionScript -SubmitForReview 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        $exitCode | Should -Not -Be 0
        $output | Should -Match 'Fab Portal write automation is disabled'
    }

    It 'rejects combined write flags before browser attachment' {
        $output = (& pwsh -NoProfile -File $submissionScript -SaveDraft -SubmitForReview 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        $exitCode | Should -Not -Be 0
        $output | Should -Match 'Fab Portal write automation is disabled'
    }
}
