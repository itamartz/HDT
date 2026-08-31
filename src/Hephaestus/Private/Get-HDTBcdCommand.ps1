function Get-HDTBcdCommand {
    <#
        .SYNOPSIS
            Every bcdedit command line the FullOS -> WinPE transport runs, as
            ordered data.

        .DESCRIPTION
            DERIVED FROM MDT. ZTIBCDUtility.vbs in
            C:\Program Files\Microsoft Deployment Toolkit\Templates\Distribution\Scripts:
            CreateNewBCDEntryEx (:108-160), CreateRamDiskEntryEx (:85-99) and
            AdjustBCDDefaults (:163-172), reached from LTIApply.wsf InstallPE
            (:159-410). MIT licensed; see NOTICE.md. PSD has no FullOS -> WinPE
            mechanism at all - PSDTBA.ps1 /capture is an explicit stub - so MDT's
            VBScript is the only prior art there is.

            WHY THIS IS A FUNCTION AND NOT TEN LINES IN THE ADAPTER.
            New-HDTImageService is deliberately untested: every method in it
            writes to a disk or reorders a machine's boot configuration, and the
            price of not testing it is that it must stay dumb (CLAUDE.md rule 1).
            Ten bcdedit invocations, in an order that matters, with a ramdisk
            device syntax that is wrong in six ways bcdedit does not report, is
            not dumb. So the ORDER and the ARGUMENTS are decided here, where a
            unit test asserts them character by character, and the adapter is a
            loop that runs what this returns.

            THREE ACTIONS, WHICH ARE MDT'S OWN THREE HALVES:

              Create   the ramdisk options object, then the OSLOADER entry and
                       the seven elements that make it a bootable WinPE.
              Arm      /bootsequence, and nothing else.
              Remove   /delete <id> /cleanup.

            THE ARM IS ONE COMMAND, AND THAT IS THE DELIBERATE DIVERGENCE.
            MDT's AdjustBCDDefaults runs four - /timeout 0, /displayorder
            /addfirst, /bootsequence and /default - so MDT's "boot into WinPE
            once" is not a one-shot at all. It is why LTICleanup.wsf (:119-121)
            has to run bcdedit /delete afterwards, and why a machine that never
            reaches cleanup boots WinPE for ever.

            HDT sets /bootsequence alone. {default} goes on naming the Windows
            Boot Manager and the entry never enters the display order, so:

              * the boot after the one-shot is Windows, by itself;
              * the entry is invisible in the boot menu, on a machine that may be
                handed to somebody the day after a deployment;
              * a machine that never comes back to be torn down degrades to
                "boots Windows" rather than "stranded in WinPE".

            Teardown still matters and is still the caller's job - /bootsequence
            is consumed, but the OSLOADER object it named stays in the store for
            ever - it is just no longer the difference between a working machine
            and a brick.

            EVERY COMMAND BELOW HAS BEEN RUN AGAINST REAL bcdedit (SPIKES S23),
            against a standalone scratch store rather than a machine's own. Three
            things that were guesses before that probe and are facts now:

              * {ramdiskoptions} is an alias bcdedit resolves INSIDE the device
                string, to {ae5534e0-a924-466c-b836-758539a3ee3a}.
              * bcdedit VALIDATES NO PATH. Every command returned 0 with a
                boot.wim that did not exist. Whether the staged image is really
                there is the step's problem, and arming without checking is an
                0xc000000f on a machine that has already been generalized.
              * /bootsequence is an element on {bootmgr}. A store without one
                fails with "The system cannot find the file specified", which
                reads like a missing file and is not (S23.2).

            THE ONE TOLERATED COMMAND. {ramdiskoptions} is a well-known object: a
            machine with a registered WinRE already has one, and bcdedit /create
            on an object that exists fails with "The object already exists".
            Deleting it first is not an option, because WinRE points at it and
            removing it would break Reset This PC on a machine HDT was only asked
            to reboot. So the create carries Tolerate, and the two /set calls
            after it are what prove the object is really there.

            AND TOLERATING THE CREATE WAS NOT ENOUGH, WHICH IS WHAT
            RamdiskOptionsPresent IS FOR. Letting the create fail keeps the
            object; setting its two elements afterwards HIJACKS it. On a machine
            with a registered WinRE that repoints WinRE's own ramdisksdidevice
            and ramdisksdipath at HDT's staged boot.sdi - and the remove action
            then DELETES that file, leaving a WinRE aimed at something that is no
            longer on the disk. MEASURED on 2026-08-31, SPIKES S23.8: reagentc
            reported "Windows RE status: Enabled" on a machine whose
            {ramdiskoptions} read `ramdisksdipath \HDT\Boot\boot.sdi`. The
            paragraph above refuses to DELETE the object for exactly this reason
            and the code then overwrote it, which is the same harm by a quieter
            route.

            MDT DOES NOT DO THIS, and its guard is the fix. ZTIBCDUtility.vbs
            CreateRamDiskEntryEx (:86-89) opens with

              If BCDObjectExists("{ramdiskoptions}") then exit Function

            so MDT writes to the object only when it is absent, and an entry on a
            machine that already had one simply uses the one that is there. That
            is safe because a machine with {ramdiskoptions} has a WORKING one:
            boot.sdi is a generic ramdisk descriptor, not a per-image file, which
            is why MDT can boot a WinPE through WinRE's copy of it.

            The caller decides, because deciding needs a read of the store and
            this function composes rather than measures. Invoke-HDTBootToWinPEStep
            asks IImageService.TestRamdiskOptions and passes the answer here.

        .PARAMETER Action
            Create, Arm or Remove.

        .PARAMETER Store
            The BCD store to edit, or '' for the system store. Empty is right in
            the full OS, where the machine booted through the store bcdboot
            wrote and the EFI System Partition has no drive letter to name. A
            path is right in WinPE, where the running store is the RAM disk's and
            is not the one the machine boots from.

        .PARAMETER Id
            The braced GUID of the entry. Must be braced and must be a GUID: a
            bare word would still be a legal bcdedit identifier - {default},
            {current} and {bootmgr} all are - and deleting one of those is a
            machine that will not start.

        .PARAMETER Description
            What the entry calls itself. Create only.

        .PARAMETER RamdiskVolume
            The volume the staged WinPE lives on, as 'C:'. Create only.

        .PARAMETER WimDevicePath
            The staged boot.wim, relative to RamdiskVolume. Create only.

        .PARAMETER SdiDevicePath
            The staged boot.sdi, relative to RamdiskVolume. Create only.

        .PARAMETER RamdiskOptionsPresent
            The machine already has a {ramdiskoptions} object, so leave it
            entirely alone: no /create and neither /set. Create only. MDT's own
            guard, and the difference between using a machine's ramdisk options
            and taking them over. See the header.

        .PARAMETER LoaderPath
            \windows\system32\boot\winload.efi or winload.exe. Chosen by
            Get-HDTLocalWinPePlan from the firmware, never here: this function
            composes, it does not decide what the machine is.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[], in the order they must
            run. Each carries Argument (string[]) and Tolerate (bool).

        .EXAMPLE
            Get-HDTBcdCommand -Action Arm -Store '' -Id '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}'

            One command: /bootsequence {7f1b6e18-...}.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Create', 'Arm', 'Remove')]
        [string] $Action,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Store,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$')]
        [string] $Id,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Description = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $RamdiskVolume = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $WimDevicePath = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $SdiDevicePath = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $LoaderPath = '',

        [Parameter()]
        [switch] $RamdiskOptionsPresent
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The /store prefix, applied once here so no caller has to remember it. The
    # decision itself lives in Get-HDTBcdStoreArgument, because the adapter's
    # TestRamdiskOptions probe has to make the same one and a probe that reads a
    # different store from the one the create writes to is undiagnosable from a
    # log (SPIKES S23.7).
    $prefix = [string[]] @(Get-HDTBcdStoreArgument -Store $Store)

    $add = {
        param([string[]] $Argument, [bool] $Tolerate)

        return [pscustomobject] ([ordered] @{
                Argument = [string[]] @($prefix + $Argument)
                Tolerate = [bool] $Tolerate
            })
    }

    $command = New-Object -TypeName System.Collections.ArrayList

    if ($Action -eq 'Arm') {
        # ONE COMMAND. See the header: this is the whole of HDT's answer to
        # MDT's four-line AdjustBCDDefaults, and the three it does not run are
        # the three that stop it being a one-shot.
        [void] $command.Add((& $add ([string[]] @('/bootsequence', $Id)) $false))
        return , ([pscustomobject[]] @($command))
    }

    if ($Action -eq 'Remove') {
        # /cleanup takes the entry out of every list that references it.
        # {ramdiskoptions} is deliberately left alone: a registered WinRE points
        # at it, and deleting it would break Reset This PC on a machine HDT was
        # only asked to reboot.
        [void] $command.Add((& $add ([string[]] @('/delete', $Id, '/cleanup')) $false))
        return , ([pscustomobject[]] @($command))
    }

    # -- Create -------------------------------------------------------------

    # The ramdisk options object first, because the entry below names it. The
    # create is tolerated; the two /set calls after it are the proof it exists.
    # NO EMBEDDED QUOTES ON THE DESCRIPTION, AND THE ENUM PROVES IT. These tokens are splatted at
    # bcdedit.exe as an ARRAY, and Windows PowerShell quotes any element
    # containing a space itself; a pair of quotes written in here would be
    # escaped as literal characters and bcdedit would name the entry
    # "HDT Windows PE" with the quotation marks in it.
    #
    # UNLESS THE MACHINE ALREADY HAS ONE, in which case none of the three run.
    # See the header: writing to a {ramdiskoptions} somebody else owns takes
    # WinRE's ramdisk options away from it, and the teardown then deletes the
    # file they were repointed at. MDT's CreateRamDiskEntryEx guards the same
    # way, and the entry below names {ramdiskoptions} either way.
    if (-not $RamdiskOptionsPresent) {
        [void] $command.Add((& $add ([string[]] @('/create', '{ramdiskoptions}', '-d', 'Ramdisk Device Options')) $true))
        [void] $command.Add((& $add ([string[]] @('/set', '{ramdiskoptions}', 'ramdisksdidevice', ('partition={0}' -f $RamdiskVolume))) $false))
        [void] $command.Add((& $add ([string[]] @('/set', '{ramdiskoptions}', 'ramdisksdipath', $SdiDevicePath)) $false))
    }

    [void] $command.Add((& $add ([string[]] @('/create', $Id, '-d', $Description, '-application', 'OSLOADER')) $false))

    # THE RAMDISK DEVICE SYNTAX, WHICH IS THE PART THAT GOES WRONG SILENTLY.
    # bcdedit accepts a device string it cannot boot and reports success; the
    # failure arrives as a black screen and an 0xc000000f, on a machine that has
    # already been generalized and cannot be looked at.
    $device = 'ramdisk=[{0}]{1},{{ramdiskoptions}}' -f $RamdiskVolume, $WimDevicePath
    [void] $command.Add((& $add ([string[]] @('/set', $Id, 'device', $device)) $false))
    [void] $command.Add((& $add ([string[]] @('/set', $Id, 'osdevice', $device)) $false))

    [void] $command.Add((& $add ([string[]] @('/set', $Id, 'path', $LoaderPath)) $false))
    [void] $command.Add((& $add ([string[]] @('/set', $Id, 'systemroot', '\windows')) $false))
    [void] $command.Add((& $add ([string[]] @('/set', $Id, 'detecthal', 'yes')) $false))
    [void] $command.Add((& $add ([string[]] @('/set', $Id, 'winpe', 'yes')) $false))

    # The unary comma is mandatory: a one-element array would otherwise collapse
    # to a scalar on the way out, and Arm and Remove both return one.
    return , ([pscustomobject[]] @($command))
}
