# The text the console and the WinPE windows show, in the language of the
# file name.
#
# ONE BLOCK PER WINDOW, so a translator works through a screen at a time and
# can see when one is finished. Inside a block the key is
# <control>.<property>: the control name the markup uses, and the property
# the text goes into - Text for a label, Content for a button, Header for a
# tab.
#
# EDIT THIS RATHER THAN THE MARKUP. A string lives here once, so the same
# sentence cannot exist twice and drift.
#
# TO TRANSLATE: copy this file to the culture you want - de-de.psd1 - and
# translate the values. Anything you leave out falls back to this file
# rather than to a blank label, so a half-finished language is usable.
# Save it UTF-8 WITH a byte order mark: PowerShell 5.1 reads a .psd1 as
# ANSI without one, and the file will not parse.

@{

    # WORDS THAT BELONG TO NO ONE WINDOW. Merged under every page, so a page
    # block only has to carry what is its own - and a verb is spelled the same
    # way on every screen. A page may still override any of these by naming
    # the same control.
    Common = @{

        'HDTBackButton.Content' = 'Back'
        'HDTCancelButton.Content' = 'Cancel'
        'HDTCloseButton.Content' = 'Close'
        'HDTNextButton.Content' = 'Next'
        'HDTOpenCmdButton.Content' = 'Open CMD'
        'HDTSaveButton.Content' = 'Save'
    }

    # The main window: Show-HDTConsole. MDT's Deployment Workbench - a tree of
    # what the share holds on the left, the selected row's fields on the right.
    Console = @{

        'HDTShareText.Text' = 'Deployment share'
        'HDTConsoleDeployRootLabel.Text' = 'Deploy root'
        'HDTConsoleOpenedFromLabel.Text' = 'Opened from'
        'HDTConsoleTreeLabel.Text' = 'Deployment share'
        'HDTNewSequenceMenuItem.Header' = 'New Task Sequence'
        'HDTRemoveSequenceMenuItem.Header' = 'Remove Task Sequence'
        'HDTConsoleDetailLabel.Text' = 'Details'
        'HDTConsoleCommandLabel.Text' = 'Command'
        'HDTApplyButton.Content' = 'Apply'
    }

    # What the boot image build is doing while it does it:
    # Show-HDTBuildProgressWindow.
    BuildProgress = @{

        'HDTBuildTitleText.Text' = 'Updating Boot Image'
        'HDTBuildStepText.Text' = 'Starting...'
        'HDTBuildCloseButton.Content' = 'Close'
    }

    # MDT's New Task Sequence wizard, as one dialog: ShowNewSequence.
    NewSequence = @{

        'HDTNewSequenceTitleText.Text' = 'New Task Sequence'
        'HDTNewSequenceIdLabel.Text' = 'Task sequence ID'
        'HDTNewSequenceIdHint.Text' = 'Short, no spaces. It is the folder name under TaskSequences and what a rule or a boot image names to select this sequence.'
        'HDTNewSequenceNameLabel.Text' = 'Task sequence name'
        'HDTNewSequenceNameHint.Text' = 'What the console and the deployment wizard show. The id is what selects it.'
        'HDTNewSequenceTemplateLabel.Text' = 'Template'
        'HDTNewSequenceTemplateHint.Text' = 'The sequence is copied from this file, comments and all. A shop with its own standard build adds one to the Templates folder.'
        'HDTNewSequenceImageLabel.Text' = 'Operating system'
        'HDTNewSequenceImageHint.Text' = 'The images this share holds. Leave it empty to decide later - the sequence carries the choice as a variable either way.'
        'HDTNewSequenceFullNameLabel.Text' = 'Full name'
        'HDTNewSequenceFullNameHint.Text' = 'The registered owner written into the answer file - a person or a team, not a computer name. Written as HDTFullName.'
        'HDTNewSequenceOrgLabel.Text' = 'Organization'
        'HDTNewSequenceOrgHint.Text' = 'The registered organisation written into the answer file. Written as HDTOrgName.'
        'HDTNewSequencePasswordLabel.Text' = 'Administrator password'
        'HDTNewSequenceCreateButton.Content' = 'Create'
    }

    # One volume's eight fields, over the task sequence editor:
    # ShowPartitionProperties.
    PartitionProperties = @{

        'HDTVolumeNameLabel.Text' = 'Volume name'
        'HDTVolumeNameBox.ToolTip' = 'What the volume is called - System, Windows, Recovery.'
        'HDTVolumeTypeLabel.Text' = 'Partition type'
        'HDTVolumeTypeBox.ToolTip' = 'A word, never a GUID. Logical and Extended are refused: this engine creates basic partitions.'
        'HDTVolumeSizeLabel.Text' = 'Size'
        'HDTVolumeSizeBox.ToolTip' = 'How much - 260, 1, 60. What of is the list beside it.'
        'HDTVolumeUnitBox.ToolTip' = 'MB, GB, TB, a percentage of what is left, raw bytes, or all of the rest.'
        'HDTVolumeFileSystemLabel.Text' = 'File system'
        'HDTVolumeFileSystemBox.ToolTip' = 'Left as the engine''s default, the type decides - FAT32 for an ESP, NTFS otherwise.'
        'HDTVolumeVariableLabel.Text' = 'Variable'
        'HDTVolumeVariableBox.ToolTip' = 'A variable to publish this volume''s drive letter into - MDT''s VolumeLetterVariable. The engine''s own are HDTSystemVolume, HDTOSVolume and HDTRecoveryVolume.'
        'HDTVolumeQuickFormatCheck.Content' = 'Quick format'
        'HDTVolumeQuickFormatCheck.ToolTip' = 'Unticked writes quickFormat: false. Ticked is the engine''s default and writes nothing.'
        'HDTVolumeBootableCheck.Content' = 'Make this a boot partition'
        'HDTVolumeBootableCheck.ToolTip' = 'One partition at most. The engine makes the first one bootable when no row claims it.'
        'HDTVolumeOkButton.Content' = 'OK'
    }

    # The task sequence editor: ShowEditor. The tree on the left, and one tab
    # per step type on the right.
    SequenceEditor = @{

        'HDTEditorTitleText.Text' = 'Task Sequence'
        'HDTEditorPathText.Text' = '(document)'

        # THE GLYPH IS PART OF THE CAPTION, not decoration beside it: the arrow
        # is what says Add opens a menu, and a translation that drops it loses
        # the affordance rather than a character.
        'HDTAddButton.Content' = 'Add  ▾'
        'HDTRemoveButton.Content' = 'Remove'
        'HDTUpButton.Content' = '↑  Up'
        'HDTDownButton.Content' = '↓  Down'
        'HDTCopyButton.Content' = 'Copy'
        'HDTPasteButton.Content' = 'Paste'

        'HDTEditorStepsLabel.Text' = 'Steps'
        'HDTStepNameLabel.Text' = 'Name'
        'HDTStepNameBox.ToolTip' = 'What this step is called. Every command refers to it by this name, so renaming it rewrites those references in the document.'

        'HDTPropertyTab.Header' = 'Properties'
        'HDTPropertyApplyButton.Content' = 'Apply properties'
        'HDTPropertyRevertButton.Content' = 'Revert'

        'HDTImageTab.Header' = 'Operating System'
        'HDTImageOsLabel.Text' = 'Operating system'
        'HDTImageOsHint.Text' = 'The images this share holds. Importing one makes it appear here; an image the sequence names but the share does not have is shown as missing rather than replaced.'
        'HDTImageIndexLabel.Text' = 'Image index'
        'HDTImageIndexHint.Text' = 'Which edition inside the image. The list is what os.yaml recorded off the media; 1 is the first image in the WIM, which is what the engine applies when a step names none.'
        'HDTImageDestinationLabel.Text' = 'Destination'
        'HDTImageDestinationHint.Text' = 'Which volume the image is written to. %HDTOSVolume% is the one the partition step published - never a guess at C:, which in WinPE is frequently the content disk.'
        'HDTImageTimeoutLabel.Text' = 'Time limit'
        'HDTImageTimeoutUnitText.Text' = 'minutes'
        'HDTImageTimeoutHint.Text' = 'Minutes before the step is treated as hung and the attempt fails. 0 means no limit.'
        'HDTImageApplyButton.Content' = 'Apply'
        'HDTImageRevertButton.Content' = 'Revert'

        'HDTValidateTab.Header' = 'Validation'
        'HDTValidateApplyButton.Content' = 'Apply checks'
        'HDTValidateRevertButton.Content' = 'Revert'

        'HDTDiskTab.Header' = 'Disk'
        'HDTDiskNumberLabel.Text' = 'Disk number'
        'HDTDiskNumberBox.ToolTip' = 'The disk to lay out. Empty lets the engine select one, and it refuses to guess when more than one qualifies.'
        'HDTDiskStyleLabel.Text' = 'Disk type'
        'HDTDiskStyleBox.ToolTip' = 'GPT, MBR, or let the firmware decide - which is what most sequences should keep.'
        'HDTDiskWipeCheck.Content' = 'Wipe the disk first'
        'HDTDiskWipeCheck.ToolTip' = 'Clears an existing partition table. A disk carrying data is refused without this.'

        'HDTPartitionListLabel.Text' = 'Volume'
        'HDTPartitionAddButton.ToolTip' = 'New volume'
        'HDTPartitionEditButton.ToolTip' = 'Edit this volume'
        'HDTPartitionRemoveButton.ToolTip' = 'Delete this volume'
        'HDTPartitionUpButton.ToolTip' = 'Move it one place earlier on the disk'
        'HDTPartitionDownButton.ToolTip' = 'Move it one place later on the disk'
        'HDTPartitionNameHeader.Text' = 'Name'
        'HDTPartitionTypeHeader.Text' = 'Type'
        'HDTPartitionSizeHeader.Text' = 'Size'
        'HDTPartitionFormatHeader.Text' = 'Format'
        'HDTPartitionQuickHeader.Text' = 'Quick'
        'HDTPartitionBootHeader.Text' = 'Boot'
        'HDTPartitionVariableHeader.Text' = 'Variable'

        'HDTOptionsTab.Header' = 'Options'
        'HDTDisableCheck.Content' = 'Disable this step'
        'HDTContinueCheck.Content' = 'Continue on error'
        'HDTConditionLabel.Text' = 'Conditions'
        'HDTConditionHint.Text' = 'This step runs only when the expression below is true. Leave it empty and the step always runs.'
        'HDTConditionVariableBox.ToolTip' = 'The variable to test'
        'HDTConditionBuildButton.Content' = 'Build'
        'HDTConditionBuildButton.ToolTip' = 'Write this into the box below'
        'HDTConditionApplyButton.Content' = 'Apply condition'
        'HDTConditionClearButton.Content' = 'Clear'
        'HDTRunInLabel.Text' = 'Runs in'
        'HDTRunInText.Text' = 'any phase'

        'HDTEditorCloseButton.Content' = 'Close'
    }

    # The Windows PE window: Show-HDTBootImageWindow.
    BootImage = @{

        'HDTBootImageTitleText.Text' = 'Windows PE'
        'HDTBootImageGeneral.Header' = 'General'
        'HDTBootImageImageNameLabel.Text' = 'Image name'
        'HDTBootImageImageNameHint.Text' = 'What the .wim and the .iso are called, and what WDS lists. Letters, digits, dot, dash and underscore.'
        'HDTBootImageArchitectureLabel.Text' = 'Architecture'
        'HDTBootImageArchitectureHint.Text' = 'It also decides which optional components the Features tab can offer - the ADK ships a separate cab set per architecture.'
        'HDTBootImageLanguageLabel.Text' = 'Language'
        'HDTBootImageLanguageHint.Text' = 'en-us unless the language packs for another are installed beside the ADK. A component with no pack for this language is added without one.'
        'HDTBootImageScratchSpaceLabel.Text' = 'Scratch space'
        'HDTBootImageScratchSpaceHint.Text' = 'The writable RAM disk inside WinPE. Raise it when a deployment copies large content into X: - the default is enough for the engine itself.'
        'HDTBootImageAnswerFileLabel.Text' = 'Answer file'
        'HDTBootImageUnattendBrowseButton.Content' = 'Browse'
        'HDTBootImageUnattendTemplateButton.Content' = 'Use template'
        'HDTBootImageUnattendOpenButton.Content' = 'Open'
        'HDTBootImageAnswerFileHint.Text' = 'A WinPE answer file, copied into the image and handed to wpeinit. This is where the WinPE firewall, the display resolution and the page file are set. Empty means wpeinit runs with no answer file, which is the ordinary case. Use template writes this module''s own onto the share; Open edits the one named above.'
        'HDTBootImageCustomBackgroundFileLabel.Text' = 'Custom background file'
        'HDTBootImageBackgroundBrowseButton.Content' = 'Browse'
        'HDTBootImageCustomBackgroundFileHint.Text' = 'The picture WinPE shows behind everything. It must be a .jpg - it is copied in as \Windows\System32\winpe.jpg, and anything else is carried into the image and never shown. Empty keeps the one WinPE ships.'
        'HDTBootImageTimeZoneLabel.Text' = 'Time zone'
        'HDTBootImageBootPromptLabel.Text' = 'Boot prompt'
        'HDTBootImagePromptForKeyCheck.Content' = 'Stop at "Press any key to boot from CD or DVD"'
        'HDTBootImageBootPromptHint.Text' = 'Off boots straight into WinPE, which is what an unattended deployment needs.'
        'HDTBootImageCertificateAuthoritiesLabel.Text' = 'Certificate authorities'
        'HDTCertificateBrowseButton.Content' = 'Browse'
        'HDTCertificateAddButton.Content' = 'Add'
        'HDTCertificateRemoveButton.Content' = 'Remove'
        'HDTBootImageCertificateAuthoritiesHint.Text' = 'Root and subordinate CAs, into LocalMachine\Root before the network starts. Public certificates only - WinPE otherwise trusts Microsoft''s roots and nothing of yours.'
        'HDTBootImageMachineCertificateLabel.Text' = 'Machine certificate'
        'HDTClientCertificateBrowseButton.Content' = 'Browse'
        'HDTClientCertificatePasswordButton.Content' = 'Set password'
        'HDTBootImageMachineCertificateHint.Text' = 'A .pfx the machine authenticates WITH, into LocalMachine\My before the network starts - for an 802.1X port, or an endpoint that asks for a client certificate. The password is stored in Control\, never here.'
        'HDTBootImageMachineCertificateHint2.Text' = 'The Welcome screen''s Skip settings live in workspace.yaml under bootImage.skip and are not on this window: no command sets them yet, and a control with nothing behind it is worse than none.'
        'HDTBootImageFeatures.Header' = 'Features'
        'HDTBootImageMachineCertificateHint3.Text' = 'Every optional component the installed ADK has a cab for, for the architecture on the General tab. Ticking one adds it to workspace.yaml; the image is only rebuilt when Update runs.'
        'HDTBootImageDrivers.Header' = 'Drivers'
        'HDTBootImageMachineCertificateHint4.Text' = 'Which drivers go INTO THE BOOT IMAGE - storage and network, so WinPE can see the disk and reach the share. This is not what the deployed OS gets; that is the sequence''s own driver step.'
        'HDTBootImageDriverGroupLabel.Text' = 'Driver group'
        'HDTBootImageDriverGroupHint.Text' = 'A folder under Drivers\ on the share - MDT''s selection profile, by another name. Empty means no drivers are injected and WinPE uses what Microsoft ships.'
        'HDTBootImageCustomisations.Header' = 'Customisations'
        'HDTBootImageExtraContentLabel.Text' = 'Extra content'
        'HDTBootImageSourceOnThisMachine.Text' = 'Source, on this machine or the share'
        'HDTBootImageWhereItLandsInsideLabel.Text' = 'Where it lands inside the image'
        'HDTContentSourceBox.ToolTip' = 'A file or folder on this machine, or on the share.'
        'HDTContentBrowseButton.Content' = 'Browse'
        'HDTContentDestinationBox.ToolTip' = '\Tools\BGInfo, for example. Rooted at the image, and no ''..''.'
        'HDTContentAddButton.Content' = 'Add'
        'HDTContentRemoveButton.Content' = 'Remove'
        'HDTBootImageStartCommandsLabel.Text' = 'Start commands'
        'HDTBootImageStartCommandsHint.Text' = 'Lines for startnet.cmd, in this order - after WinPE has a network, and before the deployment starts. This is what launches the tools added above. A .cmd or .bat is run with call, so control comes back and the deployment still starts.'
        'HDTStartCommandBox.ToolTip' = 'A line for startnet.cmd - X:\Tools\BGInfo\bginfo.exe /nolicprompt, for example.'
        'HDTStartCommandFirstCheck.Content' = 'Run first'
        'HDTStartCommandFirstCheck.ToolTip' = 'Put it at the top of the list instead of the bottom.'
        'HDTStartCommandUpButton.ToolTip' = 'Run this one place earlier'
        'HDTStartCommandDownButton.ToolTip' = 'Run this one place later'
        'HDTStartCommandAddButton.Content' = 'Add'
        'HDTStartCommandRemoveButton.Content' = 'Remove'
        'HDTBootImageUpdateButton.Content' = 'Update Boot Image'
        'HDTBootImageUpdateButton.ToolTip' = 'Rebuilds the .wim and the .iso from what is saved. Minutes.'
        'HDTBootImageSaveButton.Content' = 'Save'
        'HDTBootImageCloseButton.Content' = 'Close'
    }
}
