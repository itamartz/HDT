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
