function Get-HDTConsoleBootImageField {
    <#
        .SYNOPSIS
            Which controls on the Windows PE window need the boot image
            rebuilt when they change, and which take effect on their own.

        .DESCRIPTION
            THE DIFFERENCE NOBODY ON THAT WINDOW COULD SEE. Pick a time zone,
            press Save, read a success footer - and the deployed machine still
            comes up in the old zone, because the zone is written by dism into
            the mounted WIM and nothing had been mounted. The document is right
            and the image is stale, and the two look identical from the desk.

            THAT IS TRUE OF NEARLY EVERY FIELD ON THE WINDOW, not just the time
            zone. Update-HDTBootImage reads the whole bootImage block off
            workspace.yaml at build time - name, architecture, language, scratch
            space, boot prompt, answer file, background, time zone,
            certificates, components, drivers, extra content, start commands -
            and every one of them is baked in. Marking only the field somebody
            complained about would leave eleven more to be found the same way.

            SO THE CLASSIFICATION IS DATA AND THE WINDOW READS IT. A field added
            to that window tomorrow has to appear here, or
            tests/contract/ConsoleBootImageField.Contract.Tests.ps1 fails - it
            sweeps the controls off the BUILT WINDOW rather than off a list
            somebody remembered to update.

            THREE EFFECTS, AND THE THIRD IS NOT A COP-OUT.

            Rebuild  the value goes into the .wim, so the image carries the old
                     one until Update Boot Image runs.

            Share    the value is read live off the share when a machine
                     deploys, so the next run picks it up and no image has to be
                     built. rules.yaml is the only one on this window.

            None     not a stored setting at all: a box that stages what an Add
                     button commits, a per-build option read the instant the
                     build starts, a read-only footer, a display list.

            AND GETTING Share WRONG WOULD BE WORSE THAN SAYING NOTHING. A notice
            raised by editing rules.yaml would be a lie, and a marker that lies
            once is one people stop reading - at which point the true ones stop
            working too.

            THE TWO THAT LOOK ALIKE AND ARE NOT. rules.yaml and
            bootstrap-rules.yaml sit in the same control on adjacent tabs and
            are written in the same grammar. rules.yaml is read off the share.
            bootstrap-rules.yaml is COPIED INTO THE IMAGE - Update-HDTBootImage
            step 12b - precisely because WinPE reads it before the share is
            reachable, to decide which share that is. Editing it and not
            rebuilding is how a lab whose deployRoot had moved went on sending
            every machine to the old address.

            THE CLIENT CERTIFICATE PASSWORD IS BAKED TOO, though it is the one
            value on the window that is written the moment it is typed rather
            than at Save. It goes to Control\certificate-password.json, and the
            build reads it there and carries an obfuscated copy into the image -
            so changing it needs a rebuild like every other certificate setting.

            IT READS NOTHING AND SHOWS NOTHING. This is a table.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per control:

              Name    the x:Name on HDTBootImage.xaml
              Effect  'Rebuild', 'Share' or 'None'
              Reason  why, for the ones that claim a rebuild

        .EXAMPLE
            Get-HDTConsoleBootImageField | Where-Object { $_.Effect -eq 'Rebuild' }

        .EXAMPLE
            $baked = @(Get-HDTConsoleBootImageField | Where-Object { $_.Effect -eq 'Rebuild' })
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE REASON NAMES THE STEP THAT BAKES IT, so the next person to argue with
    # a row can go and read the line rather than trusting this file.
    $field = @(
        @{ Name = 'HDTBootImageNameBox'; Effect = 'Rebuild'
            Reason = 'names the .wim and the .iso the build writes'
        }
        @{ Name = 'HDTBootImageArchitectureBox'; Effect = 'Rebuild'
            Reason = 'decides which ADK cab set and which WinPE base image is mounted'
        }
        @{ Name = 'HDTBootImageLanguageBox'; Effect = 'Rebuild'
            Reason = 'decides which language packs are added to the mounted image'
        }
        @{ Name = 'HDTBootImageScratchBox'; Effect = 'Rebuild'
            Reason = 'dism sets the scratch space on the mounted image'
        }
        @{ Name = 'HDTBootImagePromptForKeyCheck'; Effect = 'Rebuild'
            Reason = 'decides which efisys boot sector oscdimg writes into the ISO'
        }
        @{ Name = 'HDTBootImageUnattendBox'; Effect = 'Rebuild'
            Reason = 'the answer file is copied into the image as X:\Unattend.xml'
        }
        @{ Name = 'HDTBootImageBackgroundBox'; Effect = 'Rebuild'
            Reason = 'the picture is copied in as \Windows\System32\winpe.jpg'
        }
        @{ Name = 'HDTBootImageTimeZoneBox'; Effect = 'Rebuild'
            Reason = 'dism writes the zone into the image, and it is stamped into bootstrap.json'
        }
        @{ Name = 'HDTCertificateList'; Effect = 'Rebuild'
            Reason = 'the root and subordinate CAs are copied in and imported before the network starts'
        }
        @{ Name = 'HDTClientCertificateBox'; Effect = 'Rebuild'
            Reason = 'the .pfx is copied into the image and imported before the network starts'
        }
        @{ Name = 'HDTClientCertificatePasswordButton'; Effect = 'Rebuild'
            Reason = 'the build reads it from Control\ and carries an obfuscated copy into the image'
        }
        @{ Name = 'HDTComponentList'; Effect = 'Rebuild'
            Reason = 'each optional component is a cab added to the mounted image'
        }
        @{ Name = 'HDTSelectionProfileBox'; Effect = 'Rebuild'
            Reason = 'the profile decides which drivers are injected into the mounted image'
        }
        @{ Name = 'HDTContentList'; Effect = 'Rebuild'
            Reason = 'extra content is copied into the mounted image'
        }
        @{ Name = 'HDTStartCommandList'; Effect = 'Rebuild'
            Reason = 'the start commands are written into the image as startnet.cmd'
        }
        @{ Name = 'HDTBootstrapRulesBox'; Effect = 'Rebuild'
            Reason = 'bootstrap-rules.yaml is copied into the image, because WinPE reads it before the share is reachable'
        }

        # -- read live off the share, so the next deployment picks it up ------
        @{ Name = 'HDTRulesBox'; Effect = 'Share'; Reason = '' }

        # -- not a stored setting --------------------------------------------
        #
        # A BOX THAT STAGES WHAT AN Add BUTTON COMMITS. Typing a path is not the
        # change; pressing Add is, and the list it lands in is classified above.
        @{ Name = 'HDTCertificateBox'; Effect = 'None'; Reason = '' }
        @{ Name = 'HDTContentSourceBox'; Effect = 'None'; Reason = '' }
        @{ Name = 'HDTContentDestinationBox'; Effect = 'None'; Reason = '' }
        @{ Name = 'HDTStartCommandBox'; Effect = 'None'; Reason = '' }
        @{ Name = 'HDTStartCommandFirstCheck'; Effect = 'None'; Reason = '' }

        # A PER-BUILD OPTION, read the instant Update is pressed and stored
        # nowhere. It cannot go stale, because there is nothing to go stale
        # against.
        @{ Name = 'HDTBootImagePerDriverCheck'; Effect = 'None'; Reason = '' }

        # OUTPUT, NOT INPUT. The footer echoes the commands a press ran, and the
        # two lists below it show what has been chosen elsewhere.
        @{ Name = 'HDTBootImageCommandText'; Effect = 'None'; Reason = '' }
        @{ Name = 'HDTSelectionProfileFolderList'; Effect = 'None'; Reason = '' }
        @{ Name = 'HDTRuleHelpList'; Effect = 'None'; Reason = '' }
    )

    return [pscustomobject[]] @(
        foreach ($one in $field) {
            [pscustomobject] @{
                Name   = [string] $one.Name
                Effect = [string] $one.Effect
                Reason = [string] $one.Reason
            }
        }
    )
}
