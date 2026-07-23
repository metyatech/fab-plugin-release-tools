@{
    RootModule        = 'FabPluginReleaseTools.psm1'
    ModuleVersion     = '0.1.1'
    GUID              = 'bcb11baa-afad-456f-9d90-5e64f4e5e0f8'
    Author            = 'metyatech'
    CompanyName       = 'metyatech'
    Copyright         = 'Copyright (c) 2026 metyatech. All rights reserved.'
    Description       = 'Validates, builds, packages, and revalidates Unreal Engine code plugins for Fab.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('Invoke-FabPluginRelease')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Fab', 'UnrealEngine', 'Plugin', 'Release')
            LicenseUri = 'https://github.com/metyatech/fab-plugin-release-tools/blob/master/LICENSE'
            ProjectUri = 'https://github.com/metyatech/fab-plugin-release-tools'
        }
    }
}
