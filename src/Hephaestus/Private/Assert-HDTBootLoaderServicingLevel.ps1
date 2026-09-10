function Assert-HDTBootLoaderServicingLevel {
    <#
        .SYNOPSIS
            Refuses a Secure Boot bootloader swap whose replacement boot manager
            and the boot image's own winload.efi are from different servicing
            levels. The decision only - the caller supplies both versions.

        .DESCRIPTION
            THE DEFECT THIS CLOSES, MEASURED ON HARDWARE (SPIKES S20.2 and
            S20.4). -BootLoaderPath as first shipped turned WORKING Secure Boot
            media into non-booting media, silently. Six Generation 2 Hyper-V
            runs across two builds settled it, and no build has ever produced
            swapped media that starts:

              2026-09-07, boot managers only (S20.2)
                swapped media (boot manager SVN 9.0), Secure Boot ON   FAIL 0xc0430001
                swapped media (the same ISO),         Secure Boot OFF  PASS
                unswapped ADK media (SVN 3.0),        Secure Boot ON   PASS

              2026-09-10, boot managers AND a serviced OS loader (S20.4)
                swapped media, Secure Boot ON                          FAIL 0xc0430001
                the same ISO,  Secure Boot OFF                         FAIL 0xc0430001
                unswapped ADK media, Secure Boot ON                    PASS

            0xc0430001 is STATUS_SECUREBOOT_ROLLBACK_DETECTED, and it arrives on
            Windows Boot Manager's own recovery screen - NOT the firmware's
            "Security Violation" screen the SVN floor produces. The firmware
            ACCEPTED the swapped boot manager. The boot manager then refused the
            next stage: the built boot.wim's winload.efi is 10.0.26100.1 while
            the swapped boot manager is 10.0.28000.342.

            SO THIS IS A DIFFERENT MECHANISM FROM THE ONE THE SWAP EXISTS FOR,
            and confusing the two costs a night. The SVN floor is the firmware
            checking a resource in the boot manager. This is the BOOT MANAGER
            refusing the OS loader it is about to start, and winload.efi carries
            no BOOTMGRSECURITYVERSIONNUMBER resource at all - so no amount of
            copying loaders can satisfy it. IT IS ALSO NOT GATED ON SECURE BOOT:
            S20.2 read it that way because the identical ISO booted with Secure
            Boot off, and the 2026-09-10 media refused with Secure Boot off too.

            THE COMPARISON IS A PROXY FOR "THIS IMAGE HAS NOT BEEN SERVICED",
            NOT A LITERAL STATEMENT OF WHAT THE BOOT MANAGER CHECKS, and that
            distinction is why this rule keeps getting "corrected" wrongly. A
            boot manager plainly does NOT require an OS loader at its own build:
            this build host runs bootmgr.efi 10.0.28000.342 over winload.efi
            10.0.26100.8655 with Secure Boot on, every day (Confirm-SecureBootUEFI
            True, read 2026-09-10). 28000 is the boot manager's own servicing
            track and 26100 is the OS's, so the two numbers are not literally
            orderable. What they DO separate is a boot image nobody has serviced
            - the ADK's RTM 26100.1 - from one somebody has. That is the thing
            worth refusing, and the build number is the cheapest way to see it.

            DO NOT "FIX" THIS BACK INTO A SAME-TRACK LOADER-AGAINST-LOADER
            COMPARISON. That was tried: S20.3 argued exactly that, 0.24.0
            shipped it along with a serviced winload.efi copied into the mount,
            and the media it allowed FAILED to boot with Secure Boot on AND off
            (S20.4) where this rule would have refused it. The refusals below
            are the right refusals; only the reasoning printed in the old text
            was wrong.

            IT REFUSES A ROLLBACK AND NOT AN ADVANCE. What is refused is an OS
            loader BELOW the replacement boot manager's level. Refusing one
            above it would be this function inventing a rule nobody measured.

            AN UNREADABLE VERSION IS A REFUSAL, not a pass. '0.0.0.0' is
            IFileSystem.GetVersion saying the file carries no version resource,
            and a real bootmgr.efi or winload.efi always carries one - so it
            means the probe found the wrong file, and "cannot prove it is safe"
            for a feature whose failure mode is unbootable media has to stop.

            WHAT THE REAL FIX IS, so this refusal is not mistaken for it. The
            boot image must be SERVICED: apply the current cumulative update to
            the mount, which moves winload.efi and ntoskrnl.exe TOGETHER because
            a loader and a kernel are a matched pair. COPYING LOADERS IN CANNOT
            DO IT AND MAKES THE MEDIA STRICTLY WORSE - measured, byte-perfect,
            and it cost the one configuration that used to boot (S20.4). See
            Get-HDTBootLoaderSource's note and SPIKES S20.2 and S20.4. This
            function is the guard, not the cure.

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
    $remedy = ("The fix is to SERVICE the boot image - apply the current cumulative update to the mount, which moves " +
        "winload.efi and ntoskrnl.exe together. Copying loaders in instead was built and boot-tested and it made the " +
        "media WORSE, not better (SPIKES S20.4). Until servicing exists, build WITHOUT -BootLoaderPath: that is the " +
        "unswapped ADK media, and it reached WinPE with Secure Boot ON in every control run here. " +
        "See .planning/SPIKES.md, S20.2 and S20.4.")

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
                -Message ("the Secure Boot bootloader swap cannot be proved safe, so it is refused. The OS loader inside this boot image, '{0}', reports its file version as '{1}', which is not a build number this can compare - '0.0.0.0' is a file carrying no version resource at all, and a real winload.efi always carries one, so the probe found the wrong file. A swap that goes ahead unchecked produces media the firmware accepts and the BOOT MANAGER then refuses with 0xc0430001 (STATUS_SECUREBOOT_ROLLBACK_DETECTED), which is a Windows Boot Manager recovery screen and no log anywhere - with Secure Boot on or off alike. {2}" -f
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
                -Message ("the Secure Boot bootloader swap would produce media that does not boot, so it is refused. The replacement boot manager '{0}' is version {1} (build {2}) and the winload.efi inside this boot image, '{3}', is version {4} (build {5}) - an OS loader that far behind a patched boot manager is a boot image nobody has SERVICED, and that pair does not start: it fails with 0xc0430001 STATUS_SECUREBOOT_ROLLBACK_DETECTED on a Windows Boot Manager recovery screen rather than the firmware's Security Violation. THIS IS NOT THE SVN FLOOR the swap exists to clear - the firmware accepted the loader, and winload.efi carries no BOOTMGRSECURITYVERSIONNUMBER resource for a swap to correct. Measured on Generation 2 Hyper-V, 2026-09-07: {1} over {4} FAILED with Secure Boot on and PASSED with it off, while the unswapped ADK media PASSED with it on. Re-measured 2026-09-10 with a serviced winload.efi copied into the image as well: it FAILED with Secure Boot on AND off, so copying the loader in is not the way out of this refusal. {6}" -f
                    $name, $version, $build, $OsLoaderPath, $OsLoaderVersion, $osBuild, $remedy))
    }
}
