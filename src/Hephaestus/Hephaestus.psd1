@{
    RootModule           = 'Hephaestus.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '9be61a01-0b74-4832-867d-f2b7cb51cf85'
    Author               = 'Itamartz'
    CompanyName          = 'Hephaestus Deployment Toolkit'
    Copyright            = '(c) 2026 Itamartz. All rights reserved.'
    Description          = 'Hephaestus Deployment Toolkit - a PowerShell replacement for MDT.'

    # The engine runs inside WinPE, which only ships Windows PowerShell 5.1.
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # Explicit, never a wildcard - the export list is a contract (DESIGN 15.1).
    FunctionsToExport    = @(
        'Get-HDTMachineFact',
        'Get-HDTModuleVersion',
        'Get-HDTVariableMap',
        'New-HDTCimProvider',
        'New-HDTEnvironmentProvider',
        'New-HDTRegistryService',
        'New-HDTScriptInvoker'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags = @('MDT', 'Deployment', 'OSD', 'WinPE')
        }
    }
}
