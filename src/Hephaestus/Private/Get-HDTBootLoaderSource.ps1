function Get-HDTBootLoaderSource {
    <#
        .SYNOPSIS
            Which UEFI bootloader files a Secure Boot swap replaces, and from
            where. The decision only - the caller copies.

        .DESCRIPTION
            THE PROBLEM, MEASURED AND NOT INFERRED (SPIKES S20). Microsoft's
            answer to CVE-2023-24932 (BlackLotus) is a Secure Version Number
            floor: the boot manager carries an SVN of its own and the firmware
            refuses anything below the minimum it has been told to enforce. That
            floor is currently 7.0. Every bootloader the ADK ships carries
            SVN 3.0, so a fully patched machine with Secure Boot on shows
            "Security Violation" and never reaches WinPE - and nothing HDT logs
            can explain it, because the refusal happens before HDT runs.

            The SVN is a four-byte RT_RCDATA resource named
            BOOTMGRSECURITYVERSIONNUMBER (high word major, low word minor). Read
            off this host on 2026-09-07:

              ADK WinPE Media\bootmgr.efi           10.0.26100.1085   SVN 3.0
              ADK WinPE Media\EFI\Boot\bootx64.efi  10.0.26100.1085   SVN 3.0
              Win11-LTSC-2024 install media, both   10.0.26100.1041   SVN 3.0
              WS2025-Std install media, both        10.0.26100.1041   SVN 3.0
              C:\Windows\Boot\EFI\bootmgr.efi       10.0.28000.342    SVN 9.0
              C:\Windows\Boot\EFI\bootmgfw.efi      10.0.28000.342    SVN 9.0

            THE INSTALL MEDIA IS NOT A FIX and it is the first place anyone
            reaches for: LTSC 2024 and Server 2025 are 44 builds BEHIND the ADK's
            own copy and carry the same SVN 3.0. Nor is the certificate a
            discriminator - all six are signed by Microsoft Windows Production
            PCA 2011, the good ones included. What moved is the SVN alone.

            So the source is a fully patched Windows's own %SystemRoot%\Boot\EFI,
            and the tell that a copy is post-revocation is that its build number
            (28000) runs AHEAD of the OS build it came from (26100): servicing
            ships the boot manager on its own version track.

            TWO FILES IN, FOUR NAMES OUT, AND THE PAIRING IS NOT A RENAME.
            bootmgr.efi is what the BIOS bootmgr chains to; bootmgfw.efi is the
            firmware boot manager, which removable media carries as
            EFI\Boot\bootx64.efi and a WDS tree as wdsmgfw.efi. They are
            different binaries - about 16 KB apart in .text - so crossing them
            over produces a media tree that looks right and boots wrong.

              -Target Media                         -Target Pxe
              bootmgr.efi   -> bootmgr.efi          -> Boot\<arch>\bootmgfw.efi
              bootmgfw.efi  -> EFI\Boot\bootx64.efi -> Boot\<arch>\wdsmgfw.efi

            The PXE column looks crossed and is not: Get-HDTPxePayloadRow already
            stages the payload's bootmgfw.efi FROM the ADK media's bootmgr.efi
            and its wdsmgfw.efi FROM EFI\Boot\bootx64.efi. This substitutes the
            SOURCE of each of those rows, so the pairing is preserved rather than
            re-invented.

            AN INCOMPLETE SWAP IS WORSE THAN NONE, so a folder missing either
            file refuses the whole thing. One replaced loader out of two is still
            a machine that will not start, and it is a machine whose media now
            looks like it was fixed.

            IT DOES NOT READ THE SVN. Nothing here proves the folder it was
            given is above the floor - it reports the four-part file version so
            the log can say what replaced what, and the administrator supplies a
            patched Windows's own folder. Reading the resource is a separate
            increment; claiming to check something this does not check would be
            worse than saying so.

            ⚠ SWAPPING THE LOADERS IS NOT ENOUGH, AND THAT IS MEASURED
            (SPIKES S20.2). Three Generation 2 Hyper-V runs on 2026-09-07:

              swapped media, Secure Boot ON    FAIL - 0xc0430001
              the same ISO,  Secure Boot OFF   PASS - WinPE reached
              unswapped ADK, Secure Boot ON    PASS - WinPE reached

            The firmware ACCEPTED the SVN 9.0 boot manager - the control run
            says so, and it also says this host's Hyper-V Secure Boot template
            does not enforce the 7.0 floor at all. What refused the media was
            the BOOT MANAGER, on the stage after itself: the built boot.wim's
            winload.efi is 10.0.26100.1 while the swapped boot manager is
            10.0.28000.342, and a boot manager will not start an OS loader from
            an older servicing level while Secure Boot is on. 0xc0430001 is
            STATUS_SECUREBOOT_ROLLBACK_DETECTED, and it arrives on Windows Boot
            Manager's recovery screen rather than a firmware Security Violation.
            winload.efi carries no BOOTMGRSECURITYVERSIONNUMBER resource at all,
            so nothing about it can be corrected by copying files.

            Assert-HDTBootLoaderServicingLevel is the guard that now refuses
            that pair. It is a guard and not a cure.

            WHAT THE CURE WOULD TAKE, written down here so the next person does
            not start from the two-file copy again. THE OS LOADER HAS TO MOVE
            WITH THE BOOT MANAGER, which means SERVICING the WinPE image rather
            than overwriting files in the media tree:

              1. Apply the current Windows cumulative update (.msu) to the
                 mounted boot.wim - Add-WindowsPackage against the mount, the
                 same mount step 7 already opens. The LCU is what carries the
                 post-revocation winload.efi; it is not on the ADK media and it
                 is not in the install media either (S20's measurements: both
                 are 26100-series).
              2. Take the boot manager from the SAME update level rather than
                 from whatever this build host happens to be patched to, so the
                 pair is matched by construction instead of by coincidence. A
                 -BootLoaderPath pointing at the build host is only ever right
                 by accident.
              3. Re-run this check afterwards. It costs two calls and it is the
                 difference between "the versions agree" and "we believe they
                 agree".
              4. Prove it the only way it can be proved: a Generation 2 VM with
                 Secure Boot ON, booted from the built ISO. Every analyser on
                 this host said the SVN-9.0 media was correct, and it was not.

            The open questions that go with it: which servicing package HDT is
            entitled to assume is available (the ADK ships none), where it comes
            from on a disconnected build host, and whether the ADK's own
            26100-era BCD is happy under a 28000-series boot manager - which the
            failing run could not answer, because it never got that far.

            PURE, so the whole decision is provable against New-HDTFakeFileSystem
            (CLAUDE.md rule 5). Nothing here copies anything.

        .PARAMETER BootLoaderPath
            The folder holding the replacement loaders: bootmgr.efi and
            bootmgfw.efi, taken from a fully patched Windows -
            %SystemRoot%\Boot\EFI on the build host is the usual one.

        .PARAMETER Target
            Media for a WinPE media tree (the ISO and the WIM are built from it),
            Pxe for a non-WDS TFTP or HTTP payload.

        .PARAMETER Architecture
            amd64 (default) or arm64, in the ADK's vocabulary. Only -Target Pxe
            uses it, and its destination folder uses the PXE tree's word for the
            same thing: amd64 stages under Boot\x64.

        .PARAMETER FileSystem
            An IFileSystem. Used to test for each loader and to read its version;
            nothing here writes.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per row, in copy order:
            Name (the leaf in the source folder), Source (absolute), Destination
            (relative to the media tree or the payload root) and Version (the
            four-part file version of the source).

        .EXAMPLE
            Get-HDTBootLoaderSource -BootLoaderPath 'C:\Windows\Boot\EFI' -Target Media -FileSystem $fs

            The two rows Update-HDTBootImage copies over its media tree after the
            ADK tree is staged and before the ISO is burned.

        .EXAMPLE
            Get-HDTBootLoaderSource -BootLoaderPath 'C:\Windows\Boot\EFI' -Target Pxe -FileSystem $fs

            The same two loaders under the names a TFTP root serves them by.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $BootLoaderPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Media', 'Pxe')]
        [string] $Target,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture = 'amd64',

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The PXE tree's word for the ADK's amd64 - the same translation
    # Get-HDTPxePayloadRow makes, and for the same reason. See its help.
    $folder = 'x64'
    if ($Architecture -eq 'arm64') { $folder = 'arm64' }

    $boot = [System.IO.Path]::Combine('Boot', $folder)

    # THE TABLE, IN COPY ORDER. Keyed by the leaf in the source folder, because
    # that is the set the refusal below is written against: two names, whichever
    # target asked.
    if ($Target -eq 'Pxe') {
        $plan = @(
            @{ Name = 'bootmgr.efi'; Destination = [System.IO.Path]::Combine($boot, 'bootmgfw.efi') }
            @{ Name = 'bootmgfw.efi'; Destination = [System.IO.Path]::Combine($boot, 'wdsmgfw.efi') }
        )
    } else {
        $plan = @(
            @{ Name = 'bootmgr.efi'; Destination = 'bootmgr.efi' }
            @{ Name = 'bootmgfw.efi'; Destination = [System.IO.Path]::Combine('EFI', 'Boot', 'bootx64.efi') }
        )
    }

    # [IO.Path]::Combine AND NEVER Join-Path, so a folder on a drive this
    # process has not mounted can still be planned - Join-Path resolves the
    # drive and throws DriveNotFound, which would make the line untestable
    # (CLAUDE.md rule 8, and Get-HDTWorkspacePath's note).
    $missing = New-Object -TypeName System.Collections.ArrayList
    $row = New-Object -TypeName System.Collections.ArrayList

    foreach ($entry in $plan) {
        $source = [System.IO.Path]::Combine($BootLoaderPath, [string] $entry['Name'])

        if (-not $FileSystem.TestPath($source)) {
            # EVERY MISSING ONE, NOT THE FIRST. An administrator who fixes the
            # file this refusal names and runs the build again only to be
            # refused for the next one has been told half of what was wrong.
            [void] $missing.Add([string] $entry['Name'])
            continue
        }

        [void] $row.Add([pscustomobject] @{
                Name        = [string] $entry['Name']
                Source      = $source
                Destination = [string] $entry['Destination']
                Version     = [string] $FileSystem.GetVersion($source)
            })
    }

    if ($missing.Count -gt 0) {
        # THE CAUSE, NOT THE SYMPTOM. "Could not find file" would send the
        # reader looking for a typo. What they need is why the file is wanted at
        # all, and the one folder on this machine that satisfies it - because
        # the obvious alternative, the Windows install media, carries the SAME
        # revoked SVN and looks like a fix.
        throw (New-HDTErrorRecord -TargetObject $BootLoaderPath -Category ObjectNotFound `
                -Message ("the Secure Boot bootloader swap needs {0} in '{1}' and {2} there. The ADK's own bootloaders carry Secure Version Number 3.0 against an enforced floor of 7.0, so a fully patched machine with Secure Boot enabled refuses this media before WinPE loads and shows only a firmware Security Violation. Point -BootLoaderPath at a fully patched Windows's own '%SystemRoot%\Boot\EFI', which holds both files - NOT at a Windows install media, whose copies carry the same revoked SVN 3.0. Both loaders are replaced or neither is: one corrected file out of two is still a machine that will not start." -f
                    (($missing | ForEach-Object { "'" + $_ + "'" }) -join ' and '), $BootLoaderPath,
                    $(if ($missing.Count -eq 1) { 'it is not' } else { 'neither is' })))
    }

    return [pscustomobject[]] @($row)
}
