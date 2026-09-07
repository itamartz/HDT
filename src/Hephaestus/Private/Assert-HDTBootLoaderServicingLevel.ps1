function Assert-HDTBootLoaderServicingLevel {
    <#
        .SYNOPSIS
            Refuses a Secure Boot bootloader swap whose replacement boot manager
            and the boot image's own winload.efi are from different servicing
            levels. The decision only - the caller supplies both versions.

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
            next stage: the built boot.wim's winload.efi is 10.0.26100.1 while
            the swapped boot manager is 10.0.28000.342.

            SO THIS IS A DIFFERENT MECHANISM FROM THE ONE THE SWAP EXISTS FOR,
            and confusing the two costs a night. The SVN floor is the firmware
            checking a resource in the boot manager. This is the BOOT MANAGER
            checking the OS loader it is about to start, and winload.efi carries
            no BOOTMGRSECURITYVERSIONNUMBER resource at all - so no amount of
            copying loaders can satisfy it. It is gated on Secure Boot, which is
            exactly why the same ISO booted with Secure Boot off.

            THE COMPARISON IS ON THE BUILD, AND ONLY THE BUILD. A post-revocation
            boot manager runs on its own version track - build 28000 against an
            OS build of 26100 - which is the tell S20 already records for
            recognising a good source. A winload.efi serviced to the same level
            reads the same build. Nothing measured says a REVISION gap refuses,
            so this does not claim to check one: 28000.342 over 28000.100 passes.

            IT REFUSES A ROLLBACK AND NOT AN ADVANCE. The check the boot manager
            performs is on an OS loader BELOW its own level. Refusing one above
            it would be this function inventing a rule nobody measured.

            AN UNREADABLE VERSION IS A REFUSAL, not a pass. '0.0.0.0' is
            IFileSystem.GetVersion saying the file carries no version resource,
            and a real bootmgr.efi or winload.efi always carries one - so it
            means the probe found the wrong file, and "cannot prove it is safe"
            for a feature whose failure mode is unbootable media has to stop.

            WHAT THE REAL FIX IS, so this refusal is not mistaken for it. The
            WinPE OS loader has to move WITH the boot manager: the boot image
            must be SERVICED so its own winload.efi comes up to the boot
            manager's servicing level, rather than two files being copied over
            the top of a media tree. See Get-HDTBootLoaderSource's note and
            SPIKES S20.2. This function is the guard, not the cure.

            PURE, so the whole decision is provable with nothing mounted
            (CLAUDE.md rule 5). It reads no file and writes nothing.

        .PARAMETER BootLoaderRow
            The rows Get-HDTBootLoaderSource produced - Name, Source,
            Destination, Version. Empty means no swap was asked for, and then
            there is nothing to refuse: the ADK's own matched pair is the
            control run that PASSED with Secure Boot on.

        .PARAMETER OsLoaderVersion
            The four-part file version of the winload.efi inside the boot image
            the swapped loaders will be asked to start.

        .PARAMETER OsLoaderPath
            Where that winload.efi was read from, for the message. An
            administrator holding a machine that will not start needs to know
            which file was compared, not just that a comparison failed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTBootLoaderServicingLevel -BootLoaderRow $row -OsLoaderVersion '10.0.26100.1' -OsLoaderPath $winload

            Throws: 10.0.28000.342 over 10.0.26100.1 is the pair that failed on
            hardware.
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
        [string] $OsLoaderPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NOTHING TO CHECK WHEN NOTHING IS SWAPPED. -BootLoaderPath is opt-in and
    # stays opt-in: a build that was not given a patched folder must behave
    # exactly as it did before any of this existed.
    if (@($BootLoaderRow).Count -eq 0) { return }

    # THE ONE SENTENCE BOTH REFUSALS BELOW END WITH. Written once because the
    # remedy is the same whichever way the comparison failed, and because it is
    # the part an administrator acts on.
    $remedy = ("The fix is to SERVICE the boot image so its own winload.efi comes up to the boot manager's level; " +
        "copying loaders over a media tree cannot do it. Until that exists, build without -BootLoaderPath and turn " +
        "Secure Boot off on the target - which is what the unswapped ADK media does, and it boots. See .planning/SPIKES.md, S20.2.")

    # THE BUILD, OR -1 FOR A VERSION THAT CANNOT BE COMPARED. A scriptblock
    # rather than a second private function because it is three lines and has no
    # meaning outside this comparison - the same shape New-HDTBootImageManifest's
    # $valueOf and New-HDTPxePayload's $copyOne already use.
    #
    # Build 0 counts as unreadable: '0.0.0.0' is what IFileSystem.GetVersion
    # answers for a file with no version resource, and no shipped loader has one
    # of those.
    $buildOf = {
        param([string] $Text)

        $parsed = $null
        if (-not [version]::TryParse($Text, [ref] $parsed)) { return -1 }
        if ([int] $parsed.Build -le 0) { return -1 }

        return [int] $parsed.Build
    }

    $osBuild = & $buildOf $OsLoaderVersion

    if ($osBuild -lt 0) {
        throw (New-HDTErrorRecord -TargetObject $OsLoaderPath -Category InvalidData `
                -Message ("the Secure Boot bootloader swap cannot be proved safe, so it is refused. The OS loader inside this boot image, '{0}', reports its file version as '{1}', which is not a build number this can compare - '0.0.0.0' is a file carrying no version resource at all, and a real winload.efi always carries one, so the probe found the wrong file. A swap that goes ahead unchecked produces media the firmware accepts and the BOOT MANAGER then refuses with 0xc0430001 (STATUS_SECUREBOOT_ROLLBACK_DETECTED), which is a Windows Boot Manager recovery screen and no log anywhere. {2}" -f
                    $OsLoaderPath, $OsLoaderVersion, $remedy))
    }

    # EVERY LOADER IN THE SWAP, NOT THE FIRST. Get-HDTBootLoaderSource already
    # refuses to replace one file out of two; the same has to hold for what gets
    # CHECKED, or a mixed source folder passes on whichever row came first.
    foreach ($loader in @($BootLoaderRow)) {
        $name = [string] $loader.Name
        $version = [string] $loader.Version
        $build = & $buildOf $version

        if ($build -lt 0) {
            throw (New-HDTErrorRecord -TargetObject ([string] $loader.Source) -Category InvalidData `
                    -Message ("the Secure Boot bootloader swap cannot be proved safe, so it is refused. The replacement boot manager '{0}' at '{1}' reports its file version as '{2}', which is not a build number this can compare - '0.0.0.0' is a file carrying no version resource, and every bootmgr.efi and bootmgfw.efi Microsoft ships carries one. Its servicing level cannot be matched against the OS loader in the boot image ('{3}', version {4}), and an unchecked swap is how working Secure Boot media becomes media that shows 0xc0430001 at boot. {5}" -f
                        $name, [string] $loader.Source, $version, $OsLoaderPath, $OsLoaderVersion, $remedy))
        }

        if ($osBuild -ge $build) { continue }

        # THE MEASURED FAILURE, NAMED BY ITS CAUSE. "The media does not boot" is
        # the symptom and would send the reader back to the SVN floor, which is a
        # different mechanism and is not what refused it: the firmware accepted
        # the loader and the boot manager rejected the next stage.
        throw (New-HDTErrorRecord -TargetObject ([string] $loader.Source) -Category InvalidOperation `
                -Message ("the Secure Boot bootloader swap would produce media that does not boot, so it is refused. The replacement boot manager '{0}' is version {1} (build {2}) and the winload.efi inside this boot image, '{3}', is version {4} (build {5}) - two different servicing levels. A boot manager will not hand control to an OS loader older than itself while Secure Boot is on: that is a ROLLBACK check, it fails with 0xc0430001 STATUS_SECUREBOOT_ROLLBACK_DETECTED, and it shows a Windows Boot Manager recovery screen rather than the firmware's Security Violation. THIS IS NOT THE SVN FLOOR the swap exists to clear - the firmware accepted the loader, which is why the identical media boots with Secure Boot switched off, and winload.efi carries no BOOTMGRSECURITYVERSIONNUMBER resource for a swap to correct. Measured on Generation 2 Hyper-V, 2026-09-07: {1} over {4} FAILED with Secure Boot on and PASSED with it off, while the unswapped ADK media PASSED with it on. {6}" -f
                    $name, $version, $build, $OsLoaderPath, $OsLoaderVersion, $osBuild, $remedy))
    }
}
