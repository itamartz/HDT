@{
    RootModule           = 'HDT.Console.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'b7a3f0d2-6c41-4a1e-9e28-3f5b0d7c4a91'
    Author               = 'Itamartz'
    CompanyName          = 'Hephaestus Deployment Toolkit'
    Copyright            = '(c) 2026 Itamartz. All rights reserved.'
    Description          = 'HDT admin console - the Deployment Workbench equivalent. A thin WPF client over the Hephaestus module (DESIGN 12).'

    # THE CONSOLE RUNS ON AN ADMINISTRATOR'S DESKTOP, NOT IN WinPE, so pwsh 7 is
    # available to it and the wizard's constraint does not apply here. It is
    # still written in Windows PowerShell 5.1 syntax and declares 5.1, for two
    # reasons: the repository's syntax contract covers everything under src/, and
    # C1's pages are meant to be shared with the WinPE wizard later, where 5.1 is
    # not negotiable. A page that has to be rewritten to move is not a shared page.
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # Explicit, never a wildcard - the export list is a contract (DESIGN 15.1).
    FunctionsToExport    = @(
        'Add-HDTConsoleStep',
        'Copy-HDTConsoleStep',
        'Move-HDTConsoleStep',
        'Remove-HDTConsoleStep',
        'Get-HDTConsoleEditorState',
        'Get-HDTConsoleSequenceEditor',
        'Get-HDTConsoleStepCatalog',
        'Get-HDTConsoleStepChange',
        'Get-HDTConsoleStepOption',
        'Get-HDTConsoleSetting',
        'Get-HDTConsoleTheme',
        'Get-HDTConsoleTreeNode',
        'Get-HDTConsoleWorkspace',
        'New-HDTConsoleHost',
        'New-HDTConsoleScreen',
        'Save-HDTConsoleSequence',
        'Save-HDTConsoleSetting',
        'Set-HDTConsoleStepCondition',
        'Set-HDTConsoleStepFlag',
        'Set-HDTConsoleStepProperty',
        'Show-HDTConsole',
        'Show-HDTSequenceEditor'
    )

    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags = @('MDT', 'Deployment', 'OSD', 'WPF', 'Console')
        }
    }
}
