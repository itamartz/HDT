@{
    RootModule           = 'HDTFakes.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'a1f5c0f6-6d54-4a2e-9a67-0f4c1c9b7e21'
    Author               = 'Itamartz'
    CompanyName          = 'Hephaestus Deployment Toolkit'
    Copyright            = '(c) 2026 Itamartz. All rights reserved.'
    Description          = 'Hand-written service doubles for the Hephaestus Deployment Toolkit test suite.'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'New-HDTFakeBootImageService',
        'New-HDTFakeCimProvider',
        'New-HDTFakeClock',
        'New-HDTFakeContentProvider',
        'New-HDTFakeDiskService',
        'New-HDTFakeEnvironmentProvider',
        'New-HDTFakeFileSystem',
        'New-HDTFakeImageService',
        'New-HDTFakeLsaService',
        'New-HDTFakePowerService',
        'New-HDTFakeProcessService',
        'New-HDTFakeRandomNumberGenerator',
        'New-HDTFakeRegistryService',
        'New-HDTFakeScriptInvoker',
        'New-HDTFakeSmbService',
        'New-HDTFakeWdsService'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags = @('HDT', 'Testing', 'Fake')
        }
    }
}
