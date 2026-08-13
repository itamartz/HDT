@{
    RootModule           = 'HDTTestTools.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'b5d9ae60-03f1-4c7a-9ee1-c2dc7be42dc4'
    Author               = 'Itamartz'
    CompanyName          = 'Hephaestus Deployment Toolkit'
    Copyright            = '(c) 2026 Itamartz. All rights reserved.'
    Description          = 'Shared build and test helpers for the Hephaestus Deployment Toolkit.'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'Get-HDTAutoLogonArtifact',
        'Get-HDTFunctionNameViolation',
        'Get-HDTMdtDependency',
        'Get-HDTSourceFile',
        'Get-HDTScriptCompatibilityViolation',
        'Get-HDTSourceFunction',
        'New-HDTPesterConfiguration',
        'Test-HDTFunctionName',
        'Test-HDTModuleAvailable',
        'Test-HDTScriptCompatibility'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags = @('HDT', 'Testing', 'Build')
        }
    }
}
