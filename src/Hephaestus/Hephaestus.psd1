@{
    RootModule           = 'Hephaestus.psm1'
    ModuleVersion        = '0.6.1'
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
        'Clear-HDTAutoLogon',
        'Add-HDTBootImageComponent',
        'Add-HDTBootImageContent',
        'Add-HDTBootImageStartCommand',
        'Remove-HDTBootImageComponent',
        'Remove-HDTBootImageContent',
        'Move-HDTBootImageStartCommand',
        'Remove-HDTBootImageStartCommand',
        'Set-HDTBootImageBackground',
        'Set-HDTBootImageDriver',
        'Set-HDTBootImageUnattend',
        'Set-HDTBootImageTimeZone',
        'Get-HDTTimeZone',
        'New-HDTBootImageUnattend',
        'Add-HDTBootImageCertificate',
        'Remove-HDTBootImageCertificate',
        'Set-HDTBootImageClientCertificate',
        'Set-HDTBootImageCertificatePassword',
        'Get-HDTBootImageCertificatePassword',
        'Test-HDTBootImageCertificatePassword',
        'Set-HDTWorkspaceProperty',
        'Add-HDTWorkspaceFolder',
        'Remove-HDTWorkspaceFolder',
        'Save-HDTWorkspaceDocument',
        'Write-HDTModuleBundle',
        'Resolve-HDTBundleLine',
        'Get-HDTAdkComponent',
        'Get-HDTAdkPath',
        'Get-HDTApplication',
        'Get-HDTBootImage',
        'Get-HDTBootImageComponent',
        'Get-HDTBootstrapConfiguration',
        'ConvertTo-HDTDiskLayout',
        'ConvertTo-HDTReport',
        'Copy-HDTLog',
        'Copy-HDTResumeAgent',
        'Export-HDTMachineFact',
        'Export-HDTVariableProvenance',
        'Get-HDTAutoLogonState',
        'Get-HDTDriverGroup',
        'Get-HDTDiskLayout',
        'Get-HDTLogDestination',
        'Get-HDTLogPath',
        'Get-HDTMachineFact',
        'Get-HDTMachineOverride',
        'Get-HDTModuleVersion',
        'Get-HDTNetworkConfiguration',
        'Get-HDTOperatingSystem',
        'Get-HDTRunLogRecord',
        'Get-HDTShareAccessRule',
        'Get-HDTShareCredential',
        'Get-HDTNoOpStepDescription',
        'Get-HDTSetVariableStepDescription',
        'Get-HDTPowerShellStepDescription',
        'Get-HDTCommandLineStepDescription',
        'Get-HDTRestartStepDescription',
        'Get-HDTValidateStepDescription',
        'Get-HDTDiskPartitionStepDescription',
        'Get-HDTEnableBitLockerStepDescription',
        'Get-HDTInstallApplicationsStepDescription',
        'Get-HDTInstallRolesStepDescription',
        'Get-HDTTattooStepDescription',
        'Get-HDTApplyImageStepDescription',
        'Get-HDTApplyUnattendStepDescription',
        'Get-HDTConfigureBootStepDescription',
        'Get-HDTNoOpStepTemplate',
        'Get-HDTSetVariableStepTemplate',
        'Get-HDTPowerShellStepTemplate',
        'Get-HDTCommandLineStepTemplate',
        'Get-HDTRestartStepTemplate',
        'Get-HDTValidateStepTemplate',
        'Get-HDTDiskPartitionStepTemplate',
        'Get-HDTEnableBitLockerStepTemplate',
        'Get-HDTInstallApplicationsStepTemplate',
        'Get-HDTInstallRolesStepTemplate',
        'Get-HDTTattooStepTemplate',
        'Get-HDTApplyImageStepTemplate',
        'Get-HDTApplyUnattendStepTemplate',
        'Get-HDTConfigureBootStepTemplate',
        'Get-HDTStepDescription',
        'Get-HDTSequenceTemplate',
        'Get-HDTGatherStepDescription',
        'Get-HDTGatherStepTemplate',
        'Invoke-HDTGatherStep',
        'Get-HDTInstallCertificateStepDescription',
        'Get-HDTInstallCertificateStepTemplate',
        'Invoke-HDTInstallCertificateStep',
        'Get-HDTStepNeighbourTarget',
        'Get-HDTStepType',
        'Get-HDTGroupTemplate',
        'Get-HDTUsableAddress',
        'Get-HDTVariableMap',
        'Get-HDTWizardCredential',
        'Get-HDTWizardField',
        'Get-HDTWizardHarvest',
        'Get-HDTDeploymentFailure',
        'Get-HDTFinishAction',
        'Get-HDTWizardApplication',
        'Get-HDTWizardComputerName',
        'Get-HDTWizardPage',
        'Get-HDTWizardSelection',
        'Get-HDTWizardSequence',
        'Get-HDTWizardSkip',
        'Get-HDTWizardSummary',
        'Get-HDTWorkspacePath',
        'Get-HDTVariableProvenance',
        'Hide-HDTShellWindow',
        'Import-HDTApplication',
        'Remove-HDTApplication',
        'Import-HDTBootImageToWds',
        'Import-HDTOperatingSystem',
        'Import-HDTRuleDocument',
        'Import-HDTBootstrapRuleDocument',
        'Import-HDTRunState',
        'Import-HDTSequenceDocument',
        'Import-HDTStepModule',
        'Import-HDTWizardDocument',
        'Import-HDTWorkspaceDocument',
        'Install-HDTAdk',
        'Invoke-HDTNoOpStep',
        'Invoke-HDTSetVariableStep',
        'Invoke-HDTPowerShellStep',
        'Invoke-HDTCommandLineStep',
        'Invoke-HDTRestartStep',
        'Invoke-HDTValidateStep',
        'Invoke-HDTDiskPartitionStep',
        'Invoke-HDTEnableBitLockerStep',
        'Invoke-HDTInstallApplicationsStep',
        'Invoke-HDTInstallRolesStep',
        'Invoke-HDTTattooStep',
        'Invoke-HDTApplyImageStep',
        'Invoke-HDTApplyUnattendStep',
        'Invoke-HDTConfigureBootStep',
        'Invoke-HDTBootReconciliation',
        'Invoke-HDTStep',
        'Invoke-HDTTaskSequence',
        'New-HDTBootImageService',
        'New-HDTCimProvider',
        'New-HDTBootIso',
        'New-HDTBuildProgress',
        'New-HDTClock',
        'New-HDTContentProvider',
        'New-HDTDiskLayoutPlan',
        'New-HDTDiskService',
        'New-HDTEnvironmentProvider',
        'New-HDTExecutionContext',
        'New-HDTBitLockerService',
        'New-HDTFeatureService',
        'New-HDTFileSystem',
        'New-HDTImageService',
        'New-HDTLocalContentProvider',
        'New-HDTLogContext',
        'New-HDTLsaService',
        'New-HDTPowerService',
        'New-HDTProcessService',
        'New-HDTPxePayload',
        'New-HDTRegistryService',
        'New-HDTRunState',
        'New-HDTScriptInvoker',
        'New-HDTSmbContentProvider',
        'New-HDTSmbService',
        'New-HDTWizardHost',
        'New-HDTWdsService',
        'New-HDTServiceCatalog',
        'New-HDTStepResult',
        'New-HDTTaskSequence',
        'Remove-HDTOperatingSystem',
        'Remove-HDTTaskSequence',
        'Set-HDTOperatingSystemProperty',
        'Set-HDTTaskSequenceProperty',
        'New-HDTWorkspace',
        'New-HDTWorkspaceShare',
        'Get-HDTWorkspaceShareName',
        'Resolve-HDTApplicationOrder',
        'Resolve-HDTErrorMessage',
        'Resolve-HDTDeployRoot',
        'Resolve-HDTBootstrapRule',
        'Resolve-HDTImageIndex',
        'Resolve-HDTVariable',
        'Save-HDTRunState',
        'Select-HDTTargetDisk',
        'Set-HDTApplication',
        'Set-HDTAutoLogon',
        'Set-HDTLogPath',
        'Set-HDTShareCredential',
        'Set-HDTSequenceVariable',
        'Set-HDTStaticAddress',
        'Show-HDTDeploymentFailure',
        'Show-HDTWizard',
        'Start-HDTConsole',
        'Show-HDTWizardShell',
        'New-HDTBootStatusHost',
        'New-HDTConsoleBootStatusHost',
        'New-HDTConsoleProgressHost',
        'New-HDTProgressHost',
        'Split-HDTAccountName',
        'Start-HDTCommandPrompt',
        'Start-HDTBootStatus',
        'Start-HDTProgressDisplay',
        'Start-HDTWizardDeployment',
        'Test-HDTApplicationDetection',
        'Test-HDTComputerName',
        'Test-HDTRunStateAbandoned',
        'Test-HDTShareAcl',
        'Test-HDTPowerShellStepApplicable',
        'Test-HDTStepApplicable',
        'Test-HDTStepCondition',
        'Test-HDTTaskSequence',
        'Update-HDTBootImage',
        'Update-HDTModuleVersion',
        'Update-HDTRunStateStep',
        'Write-HDTLog',
        'Write-HDTStatus',
        'Write-HDTVariableLog',
        'Add-HDTStep',
        'Add-HDTStepPartition',
        'Set-HDTStepPartition',
        'Remove-HDTStepPartition',
        'Move-HDTStepPartition',
        'Copy-HDTStep',
        'Move-HDTStep',
        'Remove-HDTStep',
        'Save-HDTOperatingSystemDocument',
        'Save-HDTSequenceDocument',
        'Set-HDTStepCondition',
        'Set-HDTStepFlag',
        'Set-HDTStepProperty',
        'Set-HDTStepPropertyList',

        # AUTHORING RULES.YAML, the same way and for the same reasons. Position
        # is semantics in a rules document - first match wins per variable - so
        # Add-HDTRule takes -After and -First rather than only appending.
        'Add-HDTRule',
        'Remove-HDTResumeAgent',
        'Remove-HDTRule',
        'Save-HDTRuleDocument',
        'Set-HDTRule',

        # THE ADMIN CONSOLE, FOLDED IN. The WPF console is not a module, it is one
        # command: everything the window does has to run an actual HDT command, and
        # if the command does not exist the window cannot do it. Shipping it beside
        # the engine rather than beside a second manifest is what makes that true -
        # one Import-Module puts the console and the commands it invokes in the
        # same session.
        'Show-HDTBootImageWindow',
        'Show-HDTBuildProgressWindow',
        'Test-HDTElevation',
        'Get-HDTFeatureCatalog',
        'New-HDTConsoleHost',
        'New-HDTConsoleScreen',
        'Show-HDTConsole',
        'Show-HDTSequenceEditor'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags = @('MDT', 'Deployment', 'OSD', 'WinPE')

            # WHERE TO REPORT A BUG. A Gallery page with no project link is a
            # dead end for anybody who hit one.
            ProjectUri = 'https://github.com/itamartz/HDT'
        }

        # WHICH SOURCE TREE THE VERSION ABOVE STANDS FOR, written by
        # ./build.ps1 -Task version and read by nothing else.
        #
        # LayoutHash IS THE SORTED LIST OF FILE PATHS and SourceHash is that
        # list with each file's own hash beside it, so the build can tell a
        # module that gained a command from one whose commands were edited: the
        # first takes the minor, the second takes the patch. Hephaestus.psd1 and
        # Hephaestus.bundle.ps1 are excluded from both - this file is what the
        # bump writes to, and the bundle is regenerated by every build, so
        # counting either would make the build bump for its own output for ever.
        #
        # EMPTY MEANS "NO BASELINE YET": the next run records the tree it finds
        # and leaves the version alone, because there is nothing to compare
        # against and bumping on that would move the number for a tree nobody
        # touched.
        HDT = @{
            SourceHash = '5640D3A193EB49F1EBA7123ACFD0AF99A909698C1BA419AAED0AC62F8D73E3A5'
            LayoutHash = '5C4B51D657BD00861BB717D1FFB3E571562AEDA2242A032D6C1B95BEC75B2CD6'
        }
    }
}
