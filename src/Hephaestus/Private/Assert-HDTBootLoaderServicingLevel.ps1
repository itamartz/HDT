function Assert-HDTBootLoaderServicingLevel {
    <#
        .SYNOPSIS
            Refuses a Secure Boot bootloader swap whose boot image still carries
            an OS loader older than the serviced Windows the replacement boot
            managers came from. The decision only - the caller supplies both
            versions.

        .DESCRIPTION
            THE DEFECT THIS CLOSES, MEASURED ON HARDWARE (SPIKES S20.2).
            -BootLoaderPath as first shipped turned WORKING Secure Boot media
            into non-booting media, silently. Three Generation 2 Hyper-V runs on
            2026-09-07 settled it:

              swapped media (boot manager SVN 9.0), Secure Boot ON   FAIL 0xc0430001
              swapped media (the same ISO),         Secure Boot OFF  PASS
              unswapped ADK media (SVN 3.0),        Secure Boot ON   PASS

            0xc0430001 is STATUS_SECUREBOOT_ROLLBACK_DETECTED, and it arrives on
            Windows Boot Manager's own recovery screen - NOT the firmware's
            "Security Violation" screen the SVN floor produces. The firmware
            ACCEPTED the swapped boot manager. The boot manager then refused the
            next stage: the built boot.wim's winload.efi was 10.0.26100.1.

            SO THIS IS A DIFFERENT MECHANISM FROM THE ONE THE SWAP EXISTS FOR,
            and confusing the two costs a night. The SVN floor is the firmware
            checking a resource in the boot manager. This is the BOOT MANAGER
            checking the OS loader it is about to start, and winload.efi carries
            no BOOTMGRSECURITYVERSIONNUMBER resource at all - probed directly on
            2026-09-10, there is no such resource in winload.efi or winload.exe.
            It is gated on Secure Boot, which is exactly why the same ISO booted
            with Secure Boot off.

            THE FIRST RULE WRITTEN FOR THIS WAS WRONG, AND THE MEASUREMENT THAT
            SHOWS IT IS THE MACHINE RUNNING THE BUILD (SPIKES S20.3,
            2026-09-10). That rule compared the BUILD of the replacement boot
            manager against the BUILD of the image's OS loader and refused when
            the loader's was lower. Read off this build host:

              C:\Windows\Boot\EFI\bootmgfw.efi      10.0.28000.342   SVN 9.0
              C:\Windows\Boot\EFI\bootmgr.efi       10.0.28000.342   SVN 9.0
              C:\Windows\System32\Boot\winload.efi  10.0.26100.8655
              Confirm-SecureBootUEFI                True

            This host boots a 28000-series boot manager over a 26100-series OS
            loader, with Secure Boot on, every day. A boot manager therefore
            does NOT require an OS loader at its own build number: 28000 is the
            boot manager's servicing track and 26100 is the OS's, and the two
            are not comparable. The build rule was a FALSE REFUSAL of the exact
            configuration Windows itself ships.

            THE RULE, CORRECTED: A SAME-TRACK COMPARISON. The failing pair was
            28000.342 over 26100.1; the working pair is 28000.342 over
            26100.8655. What separates them is the OS loader's own servicing
            level, so that is what is compared - the winload.efi inside the boot
            image against the winload.efi of the SAME serviced Windows the
            replacement boot managers were taken from. Update-HDTBootImage now
            copies that loader into the mounted image and re-reads it, so the
            normal outcome of a swap is two equal versions and a pass. A refusal
            here means the replacement did not reach the file.

            TWO VERSIONS FROM DIFFERENT TRACKS ARE NOT ORDERED, THEY ARE
            REFUSED AS A CALLER DEFECT. 26100.8655 against 28000.342 has no
            answer - "lower" and "higher" mean nothing across tracks, which is
            precisely how the first rule went wrong. Both versions reaching this
            check come off ONE serviced Windows, so a pair from two tracks is
            code assembling them wrongly and not anything an administrator can
            correct.

            IT REFUSES A ROLLBACK AND NOT AN ADVANCE. The check the boot manager
            performs is on an OS loader BELOW the level it expects. Refusing one
            above it would be this function inventing a rule nobody measured.

            AN UNREADABLE VERSION IS A REFUSAL, not a pass. '0.0.0.0' is
            IFileSystem.GetVersion saying the file carries no version resource,
            and a real bootmgr.efi or winload.efi always carries one - so it
            means the probe found the wrong file, and "cannot prove it is safe"
            for a feature whose failure mode is unbootable media has to stop.

            ⚠ NONE OF THIS HAS BEEN PROVED ON HARDWARE. The injection and this
            corrected rule are reasoned from versions read on a running machine,
            not from a VM that booted. It is unproven until a Generation 2 VM
            with Secure Boot ON starts the built ISO - and every analyser on
            this host said the SVN-9.0 media was correct when it was not.

            PURE, so the whole decision is provable with nothing mounted
            (CLAUDE.md rule 5). It reads no file and writes nothing.

        .PARAMETER BootLoaderRow
            The rows Get-HDTBootLoaderSource produced for -Target Media or
            -Target Pxe - Name, Source, Destination, Version. Empty means no
            swap was asked for, and then there is nothing to refuse: the ADK's
            own matched pair is the control run that PASSED with Secure Boot on.

            Their versions are checked for READABILITY and nothing else. They
            are on the boot manager's own track and cannot be ordered against an
            OS loader's, which is the whole correction S20.3 records.

        .PARAMETER OsLoaderVersion
            The four-part file version of the winload.efi inside the boot image
            the swapped loaders will be asked to start - read back AFTER the
            injection, so it is what the shipped image carries.

        .PARAMETER OsLoaderPath
            Where that winload.efi was read from, for the message. An
            administrator holding a machine that will not start needs to know
            which file was compared, not just that a comparison failed.

        .PARAMETER ReplacementOsLoaderVersion
            The four-part file version of the winload.efi in the serviced
            Windows the replacement boot managers came from -
            '%SystemRoot%\System32\Boot\winload.efi' beside the
            '%SystemRoot%\Boot\EFI' that -BootLoaderPath names. This is the
            yardstick: same track as the image's loader by construction,
            because both files come off one Windows.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTBootLoaderServicingLevel -BootLoaderRow $row -OsLoaderVersion '10.0.26100.1' -OsLoaderPath $winload -ReplacementOsLoaderVersion '10.0.26100.8655'

            Throws: the image still carries the ADK's RTM loader under a
            serviced replacement, which is the pair that failed on hardware.

        .EXAMPLE
            Assert-HDTBootLoaderServicingLevel -BootLoaderRow $row -OsLoaderVersion '10.0.26100.8655' -OsLoaderPath $winload -ReplacementOsLoaderVersion '10.0.26100.8655'

            Returns: what the injection produces, and what this build host boots
            under a 10.0.28000.342 boot manager with Secure Boot on.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Compares two version strings and throws; it changes no state.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $BootLoaderRow,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $OsLoaderVersion,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $OsLoaderPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $ReplacementOsLoaderVersion
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NOTHING TO CHECK WHEN NOTHING IS SWAPPED. -BootLoaderPath is opt-in and
    # stays opt-in: a build that was not given a patched folder must behave
    # exactly as it did before any of this existed.
    if (@($BootLoaderRow).Count -eq 0) { return }

    # THE ONE SENTENCE THE REFUSALS BELOW END WITH. Written once because the
    # remedy is the same whichever way the comparison failed, and because it is
    # the part an administrator acts on.
    #
    # IT IS THE INJECTION NOW, not "turn Secure Boot off". -BootLoaderPath takes
    # the OS loader off the SAME serviced Windows as the boot managers and
    # copies it into the mounted image, so a refusal here means that copy did
    # not reach the file that was measured.
    $remedy = ("The swap replaces the image's own OS loader too: -BootLoaderPath '<Windows>\Boot\EFI' also copies " +
        "'<Windows>\System32\Boot\winload.efi' and winload.exe into the mounted image, so the boot manager and the " +
        "loader behind it come off one serviced Windows and are matched by construction. Point -BootLoaderPath at a " +
        "FULLY PATCHED Windows - not at a Windows install media, whose copies are older than the ADK's - or name the " +
        "folder explicitly with -OsLoaderPath. See .planning/SPIKES.md, S20.3.")

    # PARSED, OR $null FOR A VERSION THAT CANNOT BE COMPARED. A scriptblock
    # rather than a second private function because it is four lines and has no
    # meaning outside this comparison - the same shape New-HDTBootImageManifest's
    # $valueOf and New-HDTPxePayload's $copyOne already use.
    #
    # Build 0 counts as unreadable: '0.0.0.0' is what IFileSystem.GetVersion
    # answers for a file with no version resource, and no shipped loader has one
    # of those.
    $versionOf = {
        param([string] $Text)

        $parsed = $null
        if (-not [version]::TryParse($Text, [ref] $parsed)) { return $null }
        if ([int] $parsed.Build -le 0) { return $null }

        return $parsed
    }

    $osVersion = & $versionOf $OsLoaderVersion

    if ($null -eq $osVersion) {
        throw (New-HDTErrorRecord -TargetObject $OsLoaderPath -Category InvalidData `
                -Message ("the Secure Boot bootloader swap cannot be proved safe, so it is refused. The OS loader inside this boot image, '{0}', reports its file version as '{1}', which is not a version this can compare - '0.0.0.0' is a file carrying no version resource at all, and a real winload.efi always carries one, so the probe found the wrong file. A swap that goes ahead unchecked produces media the firmware accepts and the BOOT MANAGER then refuses with 0xc0430001 (STATUS_SECUREBOOT_ROLLBACK_DETECTED), which is a Windows Boot Manager recovery screen and no log anywhere. {2}" -f
                    $OsLoaderPath, $OsLoaderVersion, $remedy))
    }

    $replacementVersion = & $versionOf $ReplacementOsLoaderVersion

    if ($null -eq $replacementVersion) {
        throw (New-HDTErrorRecord -TargetObject $OsLoaderPath -Category InvalidData `
                -Message ("the Secure Boot bootloader swap cannot be proved safe, so it is refused. The serviced Windows the replacement boot managers came from reports its own 'System32\Boot\winload.efi' as version '{0}', which is not a version this can compare - '0.0.0.0' is a file carrying no version resource, and every winload.efi Microsoft ships carries one. That file is the yardstick the boot image's own OS loader ('{1}', version {2}) is measured against, because the two come off one Windows and are therefore on one servicing track. {3}" -f
                    $ReplacementOsLoaderVersion, $OsLoaderPath, $OsLoaderVersion, $remedy))
    }

    # EVERY LOADER IN THE SWAP, NOT THE FIRST. Get-HDTBootLoaderSource already
    # refuses to replace one file out of two; the same has to hold for what gets
    # CHECKED, or a mixed source folder passes on whichever row came first.
    #
    # READABILITY ONLY. A boot manager's version is on its own track (28000 on
    # this host) and cannot be ordered against an OS loader's (26100) - that
    # comparison is what S20.3 records as a false refusal. What it still has to
    # be is a real file: an unreadable version means the probe found the wrong
    # one, and the log has to be able to name what went in.
    $bootManagerVersion = New-Object -TypeName System.Collections.ArrayList

    foreach ($loader in @($BootLoaderRow)) {
        $name = [string] $loader.Name
        $version = [string] $loader.Version

        if ($null -eq (& $versionOf $version)) {
            throw (New-HDTErrorRecord -TargetObject ([string] $loader.Source) -Category InvalidData `
                    -Message ("the Secure Boot bootloader swap cannot be proved safe, so it is refused. The replacement boot manager '{0}' at '{1}' reports its file version as '{2}', which is not a version this can read - '0.0.0.0' is a file carrying no version resource, and every bootmgr.efi and bootmgfw.efi Microsoft ships carries one. A file that reports no version is not the file this swap was pointed at, and an unchecked swap is how working Secure Boot media becomes media that shows 0xc0430001 at boot. {3}" -f
                        $name, [string] $loader.Source, $version, $remedy))
        }

        if (-not $bootManagerVersion.Contains($version)) { [void] $bootManagerVersion.Add($version) }
    }

    # THE TRACKS HAVE TO MATCH BEFORE ANYTHING IS ORDERED. Major, minor and
    # build together name a servicing track; only the revision moves within one.
    # Comparing across two is meaningless, and doing it anyway is exactly the
    # defect this function was rewritten to remove.
    if ($osVersion.Major -ne $replacementVersion.Major -or
        $osVersion.Minor -ne $replacementVersion.Minor -or
        $osVersion.Build -ne $replacementVersion.Build) {

        throw (New-HDTErrorRecord -TargetObject $OsLoaderPath -Category InvalidArgument `
                -Message ("the Secure Boot servicing check was handed two versions from different servicing tracks and cannot order them. The OS loader inside this boot image, '{0}', is {1} (track {2}.{3}.{4}) and the replacement OS loader is {5} (track {6}.{7}.{8}). Windows ships the boot manager on its own track and the OS on another - this build host runs boot manager 10.0.28000.342 over OS loader 10.0.26100.8655 with Secure Boot ON, every day - so 'older' and 'newer' mean nothing between them, and comparing them anyway is the false refusal .planning/SPIKES.md S20.3 records. Both versions handed to this check must be winload.efi versions off ONE serviced Windows. This is a defect in the caller, not something an administrator can correct." -f
                    $OsLoaderPath, $OsLoaderVersion, $osVersion.Major, $osVersion.Minor, $osVersion.Build,
                    $ReplacementOsLoaderVersion, $replacementVersion.Major, $replacementVersion.Minor, $replacementVersion.Build))
    }

    # AT OR ABOVE PASSES. A rollback is the image sitting BELOW the loader that
    # was supposed to replace it; an image ahead of it is not a rollback and
    # refusing one would be inventing a rule nobody measured.
    if ($osVersion -ge $replacementVersion) { return }

    # THE MEASURED FAILURE, NAMED BY ITS CAUSE. "The media does not boot" is the
    # symptom and would send the reader back to the SVN floor, which is a
    # different mechanism and is not what refused it: the firmware accepted the
    # loader and the boot manager rejected the next stage.
    throw (New-HDTErrorRecord -TargetObject $OsLoaderPath -Category InvalidOperation `
            -Message ("the Secure Boot bootloader swap would produce media that does not boot, so it is refused. The winload.efi inside this boot image, '{0}', is version {1}, and the serviced Windows the replacement boot manager(s) came from ({2}) carries winload.efi {3} - the same servicing track, and the image is BEHIND it, so the replacement did not reach the file. A boot manager will not hand control to an OS loader from an older servicing level while Secure Boot is on: that is a ROLLBACK check, it fails with 0xc0430001 STATUS_SECUREBOOT_ROLLBACK_DETECTED, and it shows a Windows Boot Manager recovery screen rather than the firmware's Security Violation. THIS IS NOT THE SVN FLOOR the swap exists to clear - the firmware accepted the loader, which is why the identical media booted with Secure Boot switched off, and winload.efi carries no BOOTMGRSECURITYVERSIONNUMBER resource for a swap to correct. Measured on Generation 2 Hyper-V, 2026-09-07: a swapped image carrying 10.0.26100.1 FAILED with Secure Boot on and PASSED with it off, while the unswapped ADK media PASSED with it on. {4}" -f
                $OsLoaderPath, $OsLoaderVersion, (@($bootManagerVersion) -join ', '), $ReplacementOsLoaderVersion, $remedy))
}
