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
        'Copy-HDTLog',
        'Export-HDTMachineFact',
        'Export-HDTVariableProvenance',
        'Get-HDTLogPath',
        'Get-HDTMachineFact',
        'Get-HDTMachineOverride',
        'Get-HDTModuleVersion',
        'Get-HDTStepDescription',
        'Get-HDTStepType',
        'Get-HDTVariableMap',
        'Get-HDTVariableProvenance',
        'Import-HDTRuleDocument',
        'Import-HDTRunState',
        'Import-HDTSequenceDocument',
        'Import-HDTStepModule',
        'Invoke-HDTStep',
        'New-HDTCimProvider',
        'New-HDTClock',
        'New-HDTEnvironmentProvider',
        'New-HDTExecutionContext',
        'New-HDTFileSystem',
        'New-HDTLogContext',
        'New-HDTPowerService',
        'New-HDTProcessService',
        'New-HDTRegistryService',
        'New-HDTRunState',
        'New-HDTScriptInvoker',
        'New-HDTServiceCatalog',
        'New-HDTStepResult',
        'Resolve-HDTVariable',
        'Save-HDTRunState',
        'Test-HDTRunStateAbandoned',
        'Test-HDTStepApplicable',
        'Test-HDTStepCondition',
        'Update-HDTRunStateStep',
        'Write-HDTLog',
        'Write-HDTStatus',
        'Write-HDTVariableLog'
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
