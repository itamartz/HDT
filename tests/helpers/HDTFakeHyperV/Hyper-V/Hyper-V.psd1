@{
    RootModule        = 'Hyper-V.psm1'
    ModuleVersion     = '0.0.0'
    GUID              = 'c1f2a3b4-5d6e-4f70-8192-a3b4c5d6e7f9'
    Author            = 'HDT tests'
    CompanyName       = 'HDT'
    Copyright         = 'MIT'
    Description       = 'A fake Hyper-V module for tests/unit/New-HDTLabVirtualMachine.Tests.ps1. It records the calls the lab helpers make and touches no hypervisor. See Hyper-V.psm1 for why it has to carry this name.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-HDTFakeHyperVCall', 'Clear-HDTFakeHyperVCall', 'Set-HDTFakeHyperVVirtualMachine',
        'New-VM', 'Get-VM', 'Set-VM', 'Set-VMMemory', 'Add-VMHardDiskDrive',
        'Set-VMFirmware', 'Add-VMDvdDrive', 'Get-VMDvdDrive')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
