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
        'HDTNewWorkspaceMenuItem.Header' = 'New Deployment Share'
        'HDTOpenWorkspaceMenuItem.Header' = 'Open Deployment Share'
        'HDTCloseWorkspaceMenuItem.Header' = 'Close Deployment Share'
        'HDTBootImageMenuItem.Header' = 'Windows PE'
        'HDTNewSequenceMenuItem.Header' = 'New Task Sequence'
        'HDTRemoveSequenceMenuItem.Header' = 'Remove Task Sequence'
        'HDTImportOperatingSystemMenuItem.Header' = 'Import Operating System'
        'HDTRemoveOperatingSystemMenuItem.Header' = 'Remove Operating System'
        'HDTNewFolderMenuItem.Header' = 'New Folder'
        'HDTDeleteFolderMenuItem.Header' = 'Delete Folder'
        'HDTMoveToFolderMenuItem.Header' = 'Move to Folder'

        # THE GLYPH IS PART OF THE CAPTION, as it is on the editor's toolbar -
        # the arrow is what says which way, and a translation that drops it
        # loses the affordance rather than a character.
        'HDTMoveFolderUpMenuItem.Header' = '↑ Move Up'
        'HDTMoveFolderDownMenuItem.Header' = '↓ Move Down'
        'HDTNewApplicationMenuItem.Header' = 'New Application'
        'HDTRemoveApplicationMenuItem.Header' = 'Remove Application'
        'HDTApplicationDependencyMenuItem.Header' = 'Depends On'
        'HDTApplicationDetectionMenuItem.Header' = 'Detection'
        # TWO LABELS FOR ONE ITEM. On the category it is New - Workbench's own
        # wording, and creating is why anybody opens that node. On a profile row
        # it is the manager, because that row already exists.
        'HDTSelectionProfileMenuItem.Header' = 'Selection Profiles'
        'HDTSelectionProfileMenuItem.NewHeader' = 'New Selection Profile'
        'HDTNewDriverFolderMenuItem.Header' = 'New Folder'
        'HDTImportDriverMenuItem.Header' = 'Import Drivers'
        'HDTRemoveDriverFolderMenuItem.Header' = 'Delete Driver Folder'
        # CLEAR, NOT DELETE. Nothing on the share reads a heartbeat, so this is
        # the one item on this menu that costs a record rather than a component.
        'HDTRemoveMonitorRunMenuItem.Header' = 'Clear Run'
        # THE DRIVER GRID'S COLUMNS. Enabled leads because it is the one thing
        # on the row that can be wrong - a pack imported and then half turned
        # off looks identical to one that was not, until this column says so.
        'HDTDriverStateColumn.Header' = 'Enabled'
        'HDTDriverNameColumn.Header' = 'Driver'
        'HDTDriverClassColumn.Header' = 'Class'
        'HDTDriverVendorColumn.Header' = 'Manufacturer'
        'HDTDriverVersionColumn.Header' = 'Version'
        'HDTDriverDateColumn.Header' = 'Date'
        'HDTConsoleDetailLabel.Text' = 'Details'
        'HDTConsoleCommandLabel.Text' = 'Command'
        'HDTApplyButton.Content' = 'Apply'
        'HDTReportButton.Content' = 'Open Report'
    }

    # THE TRANSPARENT PANEL THAT REPLACES THE WinPE CONSOLE, between
    # startnet.cmd and the first real window: Start-HDTBootStatus.
    #
    # ONLY TWO STRINGS, AND THE SECOND IS A PLACEHOLDER. Every line under them is
    # the payload's own account of itself, written at runtime - the same
    # sentences that go into the log - so there is nothing here to translate.
    # This is what is on screen for the fraction of a second before the first of
    # them arrives.
    BootStatus = @{

        'HDTBootStatusHeading.Text' = 'Hephaestus Deployment Toolkit'
        'HDTBootStatusCurrent.Text' = 'starting'
    }

    # What the boot image build is doing while it does it:
    # Show-HDTBuildProgressWindow.
    BuildProgress = @{

        'HDTBuildTitleText.Text' = 'Updating Boot Image'
        'HDTBuildStepText.Text' = 'Starting...'
        'HDTBuildCloseButton.Content' = 'Close'

        # IT WRITES AND THEN OPENS, which is why it is "Open Log" and not "Save
        # Log": the file is a by-product, and what somebody wants is to read it.
        'HDTBuildLogButton.Content' = 'Open Log'
        'HDTBuildLogButton.ToolTip' = 'Writes every line above to Boot\<image>.build.log and opens it. Works while the build is still running.'
    }

    # THE SAME WINDOW, RUNNING A DIFFERENT COMMAND. Importing a driver pack used
    # to run on the console's own thread: a 2.38 GB Dell pack froze it for 86
    # seconds and was reported as a crash. It now goes through the build progress
    # window, which needs its own words - a window headed 'Updating Boot Image'
    # while it expands a driver pack is a window that is lying, and an
    # administrator who cancels it because they think they clicked the wrong
    # thing has learned to distrust the screen.
    ImportProgress = @{

        'HDTBuildTitleText.Text' = 'Importing Drivers'
        'HDTBuildStepText.Text' = 'Starting...'
        'HDTBuildCloseButton.Content' = 'Close'
        'HDTBuildLogButton.Content' = 'Open Log'
        'HDTBuildLogButton.ToolTip' = 'Writes every line above to a log file and opens it. Works while the import is still running.'
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

        # Run Command Line - MDT's dialog for this step, minus the run-as
        # account HDT does not have. Start in is the reason the page exists:
        # the engine has always read workingDirectory and nothing in the
        # console could write one.
        'HDTCommandTab.Header' = 'Command'
        'HDTCommandLineLabel.Text' = 'Command line'
        'HDTCommandLineHint.Text' = 'Run through cmd.exe /c, so redirection, chaining and built-ins work as they do at a prompt. Anything typed here is logged only at Debug, because arguments routinely carry credentials.'
        'HDTCommandFileLabel.Text' = 'File'
        'HDTCommandArgumentsLabel.Text' = 'Arguments'
        'HDTCommandStartInLabel.Text' = 'Start in'
        'HDTCommandStartInHint.Text' = 'The working directory the command runs in, which is what a relative path in it resolves against. Empty means the process is given none - set one for any installer that reads a file beside itself.'
        'HDTCommandCodesLabel.Text' = 'Exit codes'
        'HDTCommandRebootLabel.Text' = 'reboot on'
        'HDTCommandCodesHint.Text' = 'Codes that mean the step worked, and codes that mean it wants a restart. Separate them with commas. A reboot code wins over a success code listing the same number. Left alone, success is 0 and reboot is 3010.'

        'HDTValidateTab.Header' = 'Validation'

        # The Applications page - MDT's Install Application dialog, which asks
        # which of the two answers this step is before it asks anything else.
        'HDTApplicationTab.Header' = 'Applications'
        'HDTApplicationVariableRadio.Content' = 'Install what the technician chose'
        'HDTApplicationVariableLabel.Text' = 'from'
        'HDTApplicationVariableHint.Text' = 'The variable the step reads at deployment time. HDTApplications is what the wizard''s application page and a rule in rules.yaml both write, so a step left on this setting installs whatever was chosen for that machine.'
        'HDTApplicationFixedRadio.Content' = 'Install these applications'
        'HDTApplicationFixedHint.Text' = 'A list this sequence names, the same for every machine that runs it. Ticking one also installs what it depends on - the engine works that out and orders them.'
        'HDTApplicationEmptyText.Text' = 'This share holds no applications. Import one and it appears here.'

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

        # The variables block, which the New Task Sequence window fills and
        # nothing could change until this tab existed.
        'HDTVariableButton.Content' = 'Variables'
        'HDTVariableButton.ToolTip' = 'What this task sequence sets before it runs'
        'HDTVariableTab.Header' = 'Variables'
        'HDTVariableHint.Text' = 'What this task sequence sets before it runs. A rule in rules.yaml wins over anything here.'
        'HDTVariableNameColumn.Header' = 'Variable'
        'HDTVariableValueColumn.Header' = 'Value'
        'HDTVariableHintColumn.Header' = 'What it does'
        'HDTVariableNameLabel.Text' = 'Variable'
        'HDTVariableValueLabel.Text' = 'Value'
        'HDTVariableSetButton.Content' = 'Set'
        'HDTVariableSetButton.ToolTip' = 'Adds it, or changes the one already there'
        'HDTVariableRemoveButton.Content' = 'Remove'
        'HDTVariableRemoveButton.ToolTip' = 'Takes the named variable out of the block'
        'HDTOptionsTab.Header' = 'Options'
        'HDTDisableCheck.Content' = 'Disable this step'
        'HDTContinueCheck.Content' = 'Continue on error'
        'HDTConditionLabel.Text' = 'Conditions'
        'HDTConditionHint.Text' = 'This step runs only when the expression below is true. Leave it empty and the step always runs.'
        'HDTConditionVariableBox.ToolTip' = 'The variable to test'
        'HDTConditionBuildButton.Content' = 'Build'
        'HDTConditionBuildButton.ToolTip' = 'Write this into the box below'
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
        'HDTBootImageSelectionProfileLabel.Text' = 'Selection profile'
        'HDTBootImageSelectionProfileHint.Text' = 'A named set of folders on the share, so one image can carry two vendors'' WinPE packs. Empty means no drivers are injected and WinPE uses what Microsoft ships.'
        'HDTBootImageProfileFolderLabel.Text' = 'This profile injects'
        'HDTSelectionProfileEditButton.Content' = 'Edit profiles...'

        # TWO LINES, AND THE NUMBERS ARE THE POINT. A technician deciding this
        # needs the cost, not the mechanism - the mechanism is in the markup
        # comment for whoever changes it next.
        'HDTBootImagePerDriverCheck.Content' = 'List every driver as it is injected'
        'HDTBootImagePerDriverHint.Text' = 'Slower - about 7 minutes for a seventy-driver pack against under a minute. Worth it when a machine has booted without its network card and you need to see which drivers actually went in.'
        'HDTSelectionProfileEditButton.ToolTip' = 'Create a profile, or change which folders one carries'
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
        # The Rules tab - MDT's CustomSettings.ini, in the place MDT put it.
        'HDTBootImageRules.Header' = 'Rules'
        'HDTBootImageRulesLabel.Text' = 'rules.yaml'
        'HDTBootImageRulesHint.Text' = 'Rules are read top to bottom and the first match wins per variable, so order matters.'
        # CLICK, NOT HOVER, AND THE TOOLTIP HAS TO SAY SO. Every other help dot
        # in this console IS the help - hover and read it. This one opens a
        # panel, which nothing on screen would otherwise tell anybody.
        'HDTRulesHelpButton.ToolTip' = 'Click to see what may be written here'
        'HDTBootstrapHelpButton.ToolTip' = 'Click to see what may be written here'
        'HDTRuleHelpTitleText.Text' = 'What may be written in a rule'
        'HDTRuleHelpCloseButton.Content' = 'Close'
        'HDTRulesReloadButton.Content' = 'Reload'
        'HDTRulesReloadButton.ToolTip' = 'Read the file again and lose what is typed here'
        'HDTRulesSaveButton.Content' = 'Save rules'
        'HDTRulesSaveButton.ToolTip' = 'Checked against the engine first; dark while the document will not parse'

        # The Bootstrap tab - MDT's Bootstrap.ini, as the facts it is built from.
        'HDTBootImageBootstrap.Header' = 'Bootstrap'

        # MDT's Bootstrap.ini proper: rules the machine walks before it has a share.
        'HDTBootstrapRulesLabel.Text' = 'Which share this image connects to, and the account that opens it'
        'HDTBootstrapRulesHint.Text' = 'Matched against the gathered facts before the share is reached. No rule matching means the share the image was built with.'
        'HDTBootstrapRulesReloadButton.Content' = 'Reload'
        'HDTBootstrapRulesReloadButton.ToolTip' = 'Read bootstrap-rules.yaml again and lose what is typed here'
        'HDTBootstrapRulesSaveButton.Content' = 'Save rules'
        'HDTBootstrapRulesSaveButton.ToolTip' = 'Dark while the document would not survive the next boot image build'
    }

    # The driver properties window: Show-HDTDriverWindow.
    DriverProperties = @{

        'HDTDriverEnabledCheck.Content' = 'Enable this driver'
        'HDTDriverEnabledHint.Text' = 'Disabled, it stays on the share and is skipped by every profile that includes this folder - which is how one bad driver is taken out of a vendor pack without deleting the pack.'
        'HDTDriverClassLabel.Text' = 'Class'
        'HDTDriverVendorLabel.Text' = 'Manufacturer'
        'HDTDriverVersionLabel.Text' = 'Version'
        'HDTDriverDateLabel.Text' = 'Date'
        'HDTDriverFileLabel.Text' = 'INF file'
        'HDTDriverCountLabel.Text' = 'PnP IDs'
        'HDTDriverPnpLabel.Text' = 'PnP IDs - the devices this driver claims'
        'HDTDriverPnpColumn.Header' = 'PnP ID'

        'HDTDriverDeleteButton.Content' = 'Delete driver'
        'HDTDriverDeleteButton.ToolTip' = 'Remove the .inf and the files beside it. There is no undo but the vendor download'
        'HDTDriverSaveButton.Content' = 'Save'
        'HDTDriverSaveButton.ToolTip' = 'Write the enabled state to Control\driver-state.yaml'
        'HDTDriverCloseButton.Content' = 'Close'
    }

    # The Selection Profiles window: Show-HDTSelectionProfileWindow.
    SelectionProfile = @{

        'HDTSelectionProfileTitleText.Text' = 'Selection profiles'
        'HDTSelectionProfileListLabel.Text' = 'Profiles'

        'HDTSelectionProfileNameLabel.Text' = 'Name'
        'HDTSelectionProfileNewButton.Content' = 'New'
        'HDTSelectionProfileNewButton.ToolTip' = 'Add a profile to this share'
        'HDTSelectionProfileRenameButton.Content' = 'Rename'
        'HDTSelectionProfileRenameButton.ToolTip' = 'Change what the picker shows. The id documents reference stays as it is'
        'HDTSelectionProfileDeleteButton.Content' = 'Delete'
        'HDTSelectionProfileDeleteButton.ToolTip' = 'Remove this profile. A boot image still pointing at it will build with no drivers'

        'HDTSelectionProfileIncludeLabel.Text' = 'Included folders'
        'HDTSelectionProfileIncludeHint.Text' = 'Tick a folder to include it and everything under it. A square means only some of what is under it is ticked.'

        'HDTSelectionProfileSaveButton.Content' = 'Save'
        'HDTSelectionProfileSaveButton.ToolTip' = 'Write the ticks to Control\selection-profiles.yaml'
        'HDTSelectionProfileCloseButton.Content' = 'Close'
    }

    # THE FIRST SCREEN IN WinPE: Show-HDTWizard on HDTWelcome.xaml. It is the
    # screen that finds the deployment share, so its text is the one thing that
    # CANNOT come from the share - it is read from the copy of this file inside
    # the boot image, at X:\HDT\Modules\Hephaestus\Strings.
    Welcome = @{

        'HDTWelcomeTitleText.Text' = 'Welcome to Hephaestus Deployment Toolkit'
        'HDTWelcomeSubtitleText.Text' = 'Configure the network and connect to the deployment share'

        'HDTWelcomeNetworkHeading.Text' = 'Network'
        'HDTUseDhcpRadio.Content' = 'Obtain an IP address automatically (DHCP)'
        'HDTUseStaticRadio.Content' = 'Use the following IP address'
        'HDTWelcomeIpAddressLabel.Text' = 'IP address'
        'HDTWelcomeSubnetMaskLabel.Text' = 'Subnet mask'
        'HDTWelcomeGatewayLabel.Text' = 'Default gateway'
        'HDTWelcomeDnsLabel.Text' = 'DNS servers'
        'HDTDnsHint.Text' = 'Separate several with a comma.'

        'HDTWelcomeShareHeading.Text' = 'Deployment share'
        'HDTWelcomeShareLabel.Text' = 'Share'
        'HDTDeployRootHint.Text' = 'This boot image carries no deployment share. Enter one to continue.'

        'HDTWelcomeAccountHeading.Text' = 'Deployment account'
        'HDTWelcomeUserIdLabel.Text' = 'User name'
        'HDTWelcomeUserDomainLabel.Text' = 'Domain'
        'HDTUserDomainHint.Text' = 'Leave blank if the account is local to the server.'
        'HDTWelcomePasswordLabel.Text' = 'Password'

        # TWO STATES OF ONE TOOLTIP. The toggle swaps between them while the
        # window is open, so the second cannot be applied to a property - the
        # host reads it from here by name. It is the only key in this file that
        # names a state rather than a property the control has.
        'HDTPasswordRevealToggle.ToolTip' = 'Show the password'
        'HDTPasswordRevealToggle.HideToolTip' = 'Hide the password'
    }

    # The one-pane wizard: HDTWizard.xaml. Its heading and body are written over
    # by whatever page is being shown, so what is here is what an empty one says.
    Wizard = @{

        'HDTBannerTitle.Text' = 'Hephaestus Deployment Toolkit'
        'HDTBannerSubtitle.Text' = 'Windows deployment'
        'HDTBodyHeading.Text' = 'Welcome'
        'HDTBodyText.Text' = 'This machine will be deployed from the HDT deployment share.'
    }

    # The multi-page shell: HDTWizardShell.xaml. The rail and the four buttons
    # are its own; every page inside it is parsed into its own name scope and
    # carries its own text.
    WizardShell = @{

        'HDTShellTitle.Text' = 'Hephaestus'
        'HDTShellSubtitle.Text' = 'Deployment Toolkit'
    }

    # The second page of the WinPE wizard: HDTWizardCredential.xaml.
    WizardCredential = @{

        'HDTCredentialTitleText.Text' = 'Connect to the deployment share'
        'HDTCredentialSubtitleText.Text' = 'Sign in with the deployment account'
        'HDTCredentialShareLabel.Text' = 'Deployment share'
        'HDTCredentialUserIdLabel.Text' = 'User name'
        'HDTCredentialUserDomainLabel.Text' = 'Domain'
        'HDTUserDomainHint.Text' = 'Leave blank if the account is local to the server.'
        'HDTCredentialPasswordLabel.Text' = 'Password'
    }

    # WHAT A TECHNICIAN READS WHEN IT DID NOT WORK: HDTFailure.xaml. Both of its
    # buttons override the shared word deliberately - a deployment that failed
    # is left with a machine to restart or shut down, not a dialog to cancel.
    Failure = @{

        'HDTFailureTitleText.Text' = 'Deployment failed'
        'HDTFailureSuccessText.Text' = 'Deployment completed successfully'
        'HDTFailureStepLabel.Text' = 'Step'
        'HDTFailureReasonLabel.Text' = 'Why'
        'HDTFailureLogLabel.Text' = 'Log'
        'HDTCancelButton.Content' = 'Shut down'
        'HDTNextButton.Content' = 'Restart'
        'HDTFinishButton.Content' = 'Finish'
    }

    # MDT's Import Operating System wizard, as one dialog:
    # ShowImportOperatingSystem.
    # MDT's New Deployment Share wizard, as one dialog:
    # Show-HDTConsole -> New-HDTConsoleHost.ShowNewWorkspace.
    NewWorkspace = @{

        'HDTNewWorkspaceTitleText.Text' = 'New Deployment Share'
        'HDTNewWorkspaceSubtitleText.Text' = 'A folder of YAML and content, published over SMB so a booted machine can reach it. The deploy root is this machine''s name and that share - a name rather than an address, because an address is a lease that moves.'
        'HDTNewWorkspacePathLabel.Text' = 'Folder'
        'HDTNewWorkspacePathBrowseButton.Content' = 'Browse'
        'HDTNewWorkspacePathHint.Text' = 'Where the share is created on this machine. It does not have to exist yet; what it must not do is already hold a workspace.yaml.'
        'HDTNewWorkspaceIdLabel.Text' = 'Id'
        'HDTNewWorkspaceIdHint.Text' = 'Carried into every boot image built here, and written into log and artifact names - so it is decided once. Letters, digits, underscore and hyphen.'
        'HDTNewWorkspaceNameLabel.Text' = 'Name'
        'HDTNewWorkspaceShareNameLabel.Text' = 'Share name'
        'HDTNewWorkspaceShareNameHint.Text' = 'The name the folder is published under, which is what makes it reachable. It ends in $ so it does not appear in network browsing - Control\ holds the deployment account, obfuscated rather than encrypted. Leave it empty to publish nothing and set the deploy root later.'
        'HDTNewWorkspaceDeployRootLabel.Text' = 'Deploy root'
        'HDTNewWorkspaceDeployRootHint.Text' = 'What a machine that has booted the image connects to. Filled in from the share name until you type your own - this machine''s name is only usually how clients reach it, and a file server behind a namespace or an alias is reached by something else.'
        'HDTNewWorkspaceCreateButton.Content' = 'Create'
    }

    # How an application is detected, as a type and the boxes that type takes:
    # Show-HDTConsole -> New-HDTConsoleHost.ShowApplicationDetection.
    ApplicationDetection = @{

        'HDTDetectionTitleText.Text' = 'Detection'
        'HDTDetectionTypeLabel.Text' = 'Detect by'
        'HDTDetectionSaveButton.Content' = 'Save'
    }

    # What an application has to be installed after, picked rather than typed:
    # Show-HDTConsole -> New-HDTConsoleHost.ShowApplicationDependency.
    ApplicationDependency = @{

        'HDTDependencyTitleText.Text' = 'Depends on'
        'HDTDependencyEmptyText.Text' = 'There is nothing else on this share to depend on yet. Add another application, and it will be offered here.'
        'HDTDependencySaveButton.Content' = 'Save'
    }

    # MDT's New Application wizard, as one dialog:
    # Show-HDTConsole -> New-HDTConsoleHost.ShowImportApplication.
    ImportApplication = @{

        'HDTImportAppTitleText.Text' = 'New Application'
        'HDTImportAppSourceLabel.Text' = 'Source folder'
        'HDTImportAppSourceBrowseButton.Content' = 'Browse'
        'HDTImportAppSourceHint.Text' = 'The folder holding the installer, not the installer itself. Everything in it is copied to the share, because an .msi usually needs its transform beside it.'
        'HDTImportAppInstallLabel.Text' = 'Install'
        'HDTImportAppInstallHint.Text' = 'What runs, silently, from inside that folder - it is the working directory, so %CD% is it and %~dp0 is not expanded. For an .msi: msiexec.exe /i <file> /qn /norestart.'
        'HDTImportAppPublisherLabel.Text' = 'Publisher'
        'HDTImportAppPublisherHint.Text' = 'Who makes it. It is what tells two entries called Reader apart, and part of the name and the id composed below.'
        'HDTImportAppNameLabel.Text' = 'Name'
        'HDTImportAppVersionLabel.Text' = 'Version'
        'HDTImportAppIdLabel.Text' = 'Id'
        'HDTImportAppIdHint.Text' = 'The folder name under Applications, and what a task sequence names to install it. Composed from the three above until you type your own; it cannot be changed afterwards from here.'
        'HDTImportAppImportButton.Content' = 'Add'
    }

    ImportOperatingSystem = @{

        'HDTImportOsTitleText.Text' = 'Import Operating System'
        'HDTImportOsSourceLabel.Text' = 'Image file'
        'HDTImportOsSourceBrowseButton.Content' = 'Browse'
        'HDTImportOsSourceHint.Text' = 'The .wim or .ffu itself, not the folder holding it - on Windows media, sources\install.wim. The image list is read out of it, so the catalog cannot disagree with the media.'
        'HDTImportOsIdLabel.Text' = 'Id'
        'HDTImportOsIdHint.Text' = 'The folder name under OperatingSystems, and what a task sequence names to select this media. Suggested from the source; it cannot be changed afterwards from here.'
        'HDTImportOsNameLabel.Text' = 'Name'
        'HDTImportOsDescriptionLabel.Text' = 'Description'
        'HDTImportOsImportButton.Content' = 'Import'
    }
}
