<#
    The command reference's table of contents: which group each exported command
    is listed under on docs/command-reference.html, and in what order.

    THIS IS THE ONLY PLACE THE GROUPING IS WRITTEN DOWN. The page is generated
    from it by tools/New-HDTCommandReference.ps1, which takes everything else -
    synopsis, syntax, parameters, examples, notes - from the module's own
    comment-based help. Edit this file to move a command between groups; edit
    the help to change what a command's entry says.

    A command that is exported and not listed here fails
    tests/contract/CommandReference.Contract.Tests.ps1, which is what stops the
    page going quietly stale the next time somebody adds a command. The page
    drifted to 32 commands behind the module before that test existed.
#>
@{
    Category = @(
        @{
            Id      = 'workspace-and-share'
            Title   = 'Workspace & deployment share'
            Blurb   = 'Create, read, edit and publish a deployment share, its folders, its ACL and its deployment account.'
            Command = @(
                'New-HDTWorkspace'
                'Import-HDTWorkspaceDocument'
                'Save-HDTWorkspaceDocument'
                'Set-HDTWorkspaceProperty'
                'Get-HDTWorkspacePath'
                'Add-HDTWorkspaceFolder'
                'Remove-HDTWorkspaceFolder'
                'Move-HDTWorkspaceFolder'
                'Get-HDTWorkspaceShareName'
                'New-HDTWorkspaceShare'
                'Get-HDTShareAccessRule'
                'Test-HDTShareAcl'
                'Get-HDTShareCredential'
                'Set-HDTShareCredential'
                'Get-HDTShareContentFolder'
            )
        }
        @{
            Id      = 'rules-and-variables'
            Title   = 'Rules & variables'
            Blurb   = 'Author rules.yaml, resolve deployment variables from all five sources, and read where every value came from.'
            Command = @(
                'Import-HDTRuleDocument'
                'Save-HDTRuleDocument'
                'Add-HDTRule'
                'Set-HDTRule'
                'Remove-HDTRule'
                'Resolve-HDTVariable'
                'Get-HDTVariableMap'
                'Get-HDTVariableProvenance'
                'Export-HDTVariableProvenance'
                'Write-HDTVariableLog'
                'Get-HDTMachineOverride'
                'Import-HDTBootstrapRuleDocument'
                'Resolve-HDTBootstrapRule'
            )
        }
        @{
            Id      = 'machine-facts-and-network'
            Title   = 'Machine facts, network & host checks'
            Blurb   = 'Gather what a machine is, read or set its IPv4 configuration, and judge names, accounts and elevation.'
            Command = @(
                'Get-HDTMachineFact'
                'Get-HDTPresentDevice'
                'Export-HDTDeviceInventory'
                'Export-HDTMachineFact'
                'Get-HDTNetworkConfiguration'
                'Get-HDTUsableAddress'
                'Set-HDTStaticAddress'
                'Get-HDTTimeZone'
                'Test-HDTComputerName'
                'Split-HDTAccountName'
                'Test-HDTElevation'
            )
        }
        @{
            Id      = 'task-sequence-authoring'
            Title   = 'Task sequence authoring'
            Blurb   = 'Create task sequences and edit their steps, groups, conditions and partition tables without reformatting the file.'
            Command = @(
                'Import-HDTSequenceDocument'
                'Save-HDTSequenceDocument'
                'Test-HDTTaskSequence'
                'Get-HDTSequenceTemplate'
                'New-HDTTaskSequence'
                'Set-HDTTaskSequenceProperty'
                'Remove-HDTTaskSequence'
                'Set-HDTSequenceVariable'
                'Add-HDTStep'
                'Copy-HDTStep'
                'Move-HDTStep'
                'Get-HDTStepNeighbourTarget'
                'Remove-HDTStep'
                'Set-HDTStepProperty'
                'Set-HDTStepPropertyList'
                'Set-HDTStepCondition'
                'Set-HDTStepFlag'
                'Add-HDTStepPartition'
                'Expand-HDTStepPartition'
                'Set-HDTStepPartition'
                'Move-HDTStepPartition'
                'Remove-HDTStepPartition'
            )
        }
        @{
            Id      = 'step-types-and-templates'
            Title   = 'Step types, templates & descriptions'
            Blurb   = 'Discover the step types this engine can run, and get the YAML and the one-line description for each.'
            Command = @(
                'Get-HDTStepType'
                'Import-HDTStepModule'
                'Get-HDTStepDescription'
                'Get-HDTGroupTemplate'
                'Get-HDTGatherStepTemplate'
                'Get-HDTGatherStepDescription'
                'Get-HDTValidateStepTemplate'
                'Get-HDTValidateStepDescription'
                'Get-HDTDiskPartitionStepTemplate'
                'Get-HDTDiskPartitionStepDescription'
                'Get-HDTApplyImageStepTemplate'
                'Get-HDTApplyImageStepDescription'
                'Get-HDTApplyUnattendStepTemplate'
                'Get-HDTApplyUnattendStepDescription'
                'Get-HDTConfigureBootStepTemplate'
                'Get-HDTConfigureBootStepDescription'
                'Get-HDTInstallApplicationsStepTemplate'
                'Get-HDTInstallApplicationsStepDescription'
                'Get-HDTInstallRolesStepTemplate'
                'Get-HDTInstallRolesStepDescription'
                'Get-HDTInstallCertificateStepTemplate'
                'Get-HDTInstallCertificateStepDescription'
                'Get-HDTEnableBitLockerStepTemplate'
                'Get-HDTEnableBitLockerStepDescription'
                'Get-HDTCommandLineStepTemplate'
                'Get-HDTCommandLineStepDescription'
                'Get-HDTPowerShellStepTemplate'
                'Get-HDTPowerShellStepDescription'
                'Get-HDTSetVariableStepTemplate'
                'Get-HDTSetVariableStepDescription'
                'Get-HDTTattooStepTemplate'
                'Get-HDTTattooStepDescription'
                'Get-HDTRestartStepTemplate'
                'Get-HDTRestartStepDescription'
                'Get-HDTNoOpStepTemplate'
                'Get-HDTNoOpStepDescription'
                'Get-HDTApplyDriversStepTemplate'
                'Get-HDTApplyDriversStepDescription'
            )
        }
        @{
            Id      = 'step-implementations'
            Title   = 'Step implementations'
            Blurb   = 'The step types themselves: what each one does to a machine when the engine dispatches it.'
            Command = @(
                'Invoke-HDTStep'
                'Test-HDTStepApplicable'
                'Invoke-HDTGatherStep'
                'Invoke-HDTValidateStep'
                'Invoke-HDTDiskPartitionStep'
                'Invoke-HDTApplyImageStep'
                'Invoke-HDTApplyUnattendStep'
                'Invoke-HDTConfigureBootStep'
                'Invoke-HDTInstallApplicationsStep'
                'Invoke-HDTInstallRolesStep'
                'Invoke-HDTInstallCertificateStep'
                'Invoke-HDTEnableBitLockerStep'
                'Invoke-HDTCommandLineStep'
                'Invoke-HDTPowerShellStep'
                'Test-HDTPowerShellStepApplicable'
                'Invoke-HDTSetVariableStep'
                'Invoke-HDTTattooStep'
                'Invoke-HDTRestartStep'
                'Invoke-HDTNoOpStep'
                'New-HDTStepResult'
                'Invoke-HDTApplyDriversStep'
            )
        }
        @{
            Id      = 'operating-systems-and-drivers'
            Title   = 'Operating systems, drivers & selection profiles'
            Blurb   = 'Import operating system sources and vendor driver packs into the share''s catalog, edit them, group the drivers by model, and name the folders a boot image or a driver step draws from.'
            Command = @(
                'Get-HDTOperatingSystem'
                'Import-HDTOperatingSystem'
                'Set-HDTOperatingSystemProperty'
                'Save-HDTOperatingSystemDocument'
                'Remove-HDTOperatingSystem'
                'Get-HDTDriverGroup'
                'Import-HDTDriver'
                'Get-HDTDriver'
                'Get-HDTDriverMatch'
                'Get-HDTDriverCoverage'
                'Set-HDTDriverState'
                'New-HDTDriverFolder'
                'Rename-HDTDriverFolder'
                'Remove-HDTDriverFolder'
                'Copy-HDTDriverPackage'
                'Get-HDTSelectionProfile'
                'New-HDTSelectionProfile'
                'Set-HDTSelectionProfile'
                'Remove-HDTSelectionProfile'
                'Expand-HDTSelectionProfile'
                'Save-HDTSelectionProfileDocument'
            )
        }
        @{
            Id      = 'applications'
            Title   = 'Applications & Windows features'
            Blurb   = 'Fill the application catalog, order an install by dependency, detect what is installed, list server features.'
            Command = @(
                'Get-HDTApplication'
                'Import-HDTApplication'
                'Set-HDTApplication'
                'Remove-HDTApplication'
                'Resolve-HDTApplicationOrder'
                'Test-HDTApplicationDetection'
                'Get-HDTFeatureCatalog'
            )
        }
        @{
            Id      = 'disks-and-imaging'
            Title   = 'Disks & imaging'
            Blurb   = 'Turn a named layout into real partitions, and choose the one disk to wipe and the one image to apply.'
            Command = @(
                'Get-HDTDiskLayout'
                'ConvertTo-HDTDiskLayout'
                'New-HDTDiskLayoutPlan'
                'Select-HDTTargetDisk'
                'Resolve-HDTImageIndex'
                'Resolve-HDTDeployRoot'
            )
        }
        @{
            Id      = 'boot-image-and-winpe'
            Title   = 'Boot image & WinPE'
            Blurb   = 'Declare what goes into WinPE - components, content, drivers, certificates, start commands - then build wim and iso.'
            Command = @(
                'Get-HDTBootImage'
                'Update-HDTBootImage'
                'New-HDTBuildProgress'
                'Show-HDTBuildProgressWindow'
                'Show-HDTBootImageWindow'
                'Get-HDTAdkPath'
                'Get-HDTAdkComponent'
                'Get-HDTBootImageComponent'
                'Add-HDTBootImageComponent'
                'Remove-HDTBootImageComponent'
                'Add-HDTBootImageContent'
                'Remove-HDTBootImageContent'
                'Add-HDTBootImageStartCommand'
                'Move-HDTBootImageStartCommand'
                'Remove-HDTBootImageStartCommand'
                'Add-HDTBootImageCertificate'
                'Remove-HDTBootImageCertificate'
                'Set-HDTBootImageClientCertificate'
                'Get-HDTBootImageCertificatePassword'
                'Set-HDTBootImageCertificatePassword'
                'Test-HDTBootImageCertificatePassword'
                'Set-HDTBootImageDriver'
                'Set-HDTBootImageBackground'
                'Set-HDTBootImageTimeZone'
                'New-HDTBootImageUnattend'
                'Set-HDTBootImageUnattend'
                'New-HDTBootIso'
            )
        }
        @{
            Id      = 'transport-pxe-and-media'
            Title   = 'Transport: PXE, media & content providers'
            Blurb   = 'How a booted machine reaches the content: WDS, a TFTP payload, bootstrap.json, and the provider behind it.'
            Command = @(
                'Get-HDTBootstrapConfiguration'
                'Import-HDTBootImageToWds'
                'New-HDTPxePayload'
                'New-HDTContentProvider'
                'New-HDTSmbContentProvider'
                'New-HDTLocalContentProvider'
            )
        }
        @{
            Id      = 'execution-and-resume'
            Title   = 'Execution engine, state & resume'
            Blurb   = 'Run a sequence, checkpoint it to state.json, and survive the reboots through autologon and boot reconciliation.'
            Command = @(
                'Invoke-HDTTaskSequence'
                'New-HDTExecutionContext'
                'Test-HDTStepCondition'
                'New-HDTRunState'
                'Import-HDTRunState'
                'Save-HDTRunState'
                'Update-HDTRunStateStep'
                'Test-HDTRunStateAbandoned'
                'Set-HDTAutoLogon'
                'Get-HDTAutoLogonState'
                'Clear-HDTAutoLogon'
                'Copy-HDTResumeAgent'
                'Remove-HDTResumeAgent'
                'Invoke-HDTBootReconciliation'
                'Get-HDTFinishAction'
                'Get-HDTMachineEnding'
                'Resolve-HDTErrorMessage'
            )
        }
        @{
            Id      = 'logging-and-reporting'
            Title   = 'Logging & reporting'
            Blurb   = 'Write the deployment log in both formats, move and copy it, read it back, render it as a report.'
            Command = @(
                'Write-HDTLog'
                'New-HDTLogContext'
                'Get-HDTLogPath'
                'Set-HDTLogPath'
                'Get-HDTLogDestination'
                'Copy-HDTLog'
                'Get-HDTRunLogRecord'
                'ConvertTo-HDTReport'
                'Write-HDTStatus'
                'Remove-HDTMonitorRun'
            )
        }
        @{
            Id      = 'technician-ui'
            Title   = 'Technician UI in WinPE'
            Blurb   = 'What the WinPE payload calls to ask a technician, show progress and report a failure.'
            Command = @(
                'Show-HDTWizardShell'
                'Show-HDTWizard'
                'Import-HDTWizardDocument'
                'Get-HDTWizardPage'
                'Get-HDTWizardField'
                'Get-HDTWizardSeed'
                'Get-HDTWizardFocus'
                'Get-HDTWizardSelection'
                'Test-HDTWizardAnswerChanged'
                'Get-HDTWizardHarvest'
                'Get-HDTWizardSkip'
                'Get-HDTWizardSequence'
                'Get-HDTWizardComputerName'
                'Get-HDTWizardCredential'
                'Get-HDTWizardApplication'
                'Test-HDTAdminPassword'
                'Get-HDTWizardSummary'
                'Start-HDTWizardDeployment'
                'Start-HDTProgressDisplay'
                'Start-HDTBootStatus'
                'Get-HDTDeploymentFailure'
                'Show-HDTDeploymentFailure'
                'Start-HDTCommandPrompt'
                'Hide-HDTShellWindow'
                'Set-HDTWindowForeground'
            )
        }
        @{
            Id      = 'admin-console'
            Title   = 'Admin console'
            Blurb   = 'Open the console on one or more shares. The windows build themselves from helpers that are not commands.'
            Command = @(
                'Show-HDTConsole'
                'Start-HDTConsole'
                'Show-HDTSequenceEditor'
                'Show-HDTDriverWindow'
                'Show-HDTSelectionProfileWindow'
                'Get-HDTConsoleLogPath'
            )
        }
        @{
            Id      = 'services-and-module'
            Title   = 'Injected services, hosts & module plumbing'
            Blurb   = 'The thin adapters a step reaches hardware through, the UI hosts, and the module''s own build helpers.'
            Command = @(
                'New-HDTServiceCatalog'
                'New-HDTDiskService'
                'New-HDTImageService'
                'New-HDTBootImageService'
                'New-HDTBitLockerService'
                'New-HDTFeatureService'
                'New-HDTWdsService'
                'New-HDTSmbService'
                'New-HDTCimProvider'
                'New-HDTRegistryService'
                'New-HDTLsaService'
                'New-HDTFileSystem'
                'New-HDTEnvironmentProvider'
                'New-HDTProcessService'
                'New-HDTScriptInvoker'
                'New-HDTPowerService'
                'New-HDTClock'
                'New-HDTConsoleHost'
                'New-HDTWizardHost'
                'New-HDTConsoleScreen'
                'New-HDTProgressHost'
                'New-HDTConsoleProgressHost'
                'New-HDTBootStatusHost'
                'New-HDTConsoleBootStatusHost'
                'Get-HDTModuleVersion'
                'Update-HDTModuleVersion'
                'Write-HDTModuleBundle'
                'Resolve-HDTBundleLine'
            )
        }
        @{
            Id      = 'other'
            Title   = 'Other'
            Blurb   = 'Commands not covered by a group above.'
            Command = @(
                'Install-HDTAdk'
            )
        }
    )
}
