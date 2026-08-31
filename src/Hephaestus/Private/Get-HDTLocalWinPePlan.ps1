function Get-HDTLocalWinPePlan {
    <#
        .SYNOPSIS
            Where the WinPE a machine will boot back into comes from, where it is
            staged, and what the BCD entry that reaches it looks like.

        .DESCRIPTION
            THE TRANSPORT HALF OF THE FullOS -> WinPE REBOOT, AS PURE STRINGS.
            Get-HDTResumeCandidate answers "is a run already in progress" and is
            deliberately transport-independent - it does not care how the machine
            came to be running WinPE. This is the other half: how it gets there,
            without a human and without changing the firmware boot order.

            DERIVED FROM MDT, LTIApply.wsf InstallPE (:159-410) and
            ZTIBCDUtility.vbs. MIT licensed; see NOTICE.md.

            FOUR DECISIONS LIVE HERE, AND EACH ONE IS A DIVERGENCE WORTH READING.

            1. WHERE THE WinPE COMES FROM: the share's Boot\<name>.wim, which is
               MDT's own source (<DeployRoot>\Boot\LiteTouchPE_x64.wim). NOT the
               running X: - that is an EXPANDED RAM disk, so producing a .wim
               from it would mean capturing it, and nothing on X: records which
               image this machine booted from anyway. Copy-HDTResumeAgent takes
               the image's own tree because the engine that resumes must be the
               engine that started; that argument does not carry here, because
               what is being staged is a boot image rather than a running
               engine, and the share is the only place a boot image exists as a
               file.

            2. WHERE IT IS STAGED: <volume>\HDT\Boot. The EFI System Partition is
               260 MB in both shipped templates and a boot image is roughly 500,
               so the OS volume is the only candidate - which is MDT's own
               fallback (LTIApply.wsf:235-243), reached there by a free-space
               check rather than on purpose.

               UNDER \HDT, WHICH IS THE ENTIRE REASON THE CAPTURE STAYS CLEAN.
               Templates\Capture\wimscript.ini already excludes \HDT as a tree,
               so a WinPE staged there cannot travel inside a captured image.
               Staging anywhere else would need a second entry in that file, and
               the two would eventually disagree - which is the failure mode
               CLAUDE.md 8 is a list of.

            3. WHERE boot.sdi COMES FROM: the RUNNING WINDOWS,
               <SystemRoot>\Boot\DVD\EFI\boot.sdi. Every Windows installation
               carries one, it is version-matched to the boot manager that will
               read it, and taking it from the OS means the transport needs no
               extra file on the share and no ADK on the client. MDT robocopies
               the ADK's media tree instead, which is where the next point comes
               from.

            4. WHAT IS NOT TOUCHED, AND IT IS THE IMPORTANT ONE:
               bootmgfw.efi. MDT's InstallPE (:295-308) robocopies the ADK's
               efi\ and Boot\ trees over the boot drive and RENAMES bootx64.efi
               to BootMgFW.efi - that is, it replaces the machine's boot manager
               with the ADK's copy. SPIKES S20 measured that exact file at SVN
               3.0 against an enforced floor of 7.0, so copying MDT more
               faithfully here would DOWNGRADE the one binary Secure Boot
               already refuses.

               HDT copies no loader at all. The firmware goes on loading the ESP
               boot manager bcdboot installed from the applied image, and the
               ramdisk entry is loaded BY it as an OSLOADER application - so the
               Secure Boot chain gains nothing new, and this path is no worse
               than booting the media. Do not "fix" this later by copying MDT's
               robocopy; it is the regression, not the repair.

        .PARAMETER Volume
            The volume the WinPE is staged on and booted from. 'C', 'C:' and
            'C:\' are all accepted, because HDTOSVolume is spelled all three ways
            in the wild.

            IN THE FULL OS THIS IS THE RUNNING SYSTEM DRIVE, not %HDTOSVolume%:
            that variable carries the WinPE letter (W:) across the reboot in
            state.json, and bcdedit resolves a drive letter to a partition at the
            moment it runs.

        .PARAMETER DeployRoot
            The share. Boot\<BootImageName>.wim under it is the boot image.

        .PARAMETER SystemRoot
            The running Windows directory, which is where boot.sdi is read from.

        .PARAMETER Firmware
            UEFI or BIOS. Decides the loader, the boot.sdi source tree and the
            store path - three branches that would otherwise be in an adapter
            nothing executes.

        .PARAMETER SystemVolume
            The system partition's letter, or empty for the system store. Empty
            is right in the full OS; the teardown leg in WinPE names it, because
            the store the running WinPE would otherwise edit is the RAM disk's.

        .PARAMETER BootImageName
            The boot image's base name on the share. Defaults to HDTPE_x64, the
            workspace convention New-HDTPxePayload already defaults to.

        .OUTPUTS
            System.Management.Automation.PSCustomObject carrying EntryId,
            Description, SourceWimPath, SourceSdiPath, StageDirectory, WimPath,
            SdiPath, RamdiskVolume, WimDevicePath, SdiDevicePath, LoaderPath and
            StorePath.

        .EXAMPLE
            Get-HDTLocalWinPePlan -Volume 'C' -DeployRoot '\\LAP\HDTShare' `
                -SystemRoot 'C:\Windows' -Firmware 'UEFI'

            What the arming leg asks for in the full OS: the share's boot image,
            staged to C:\HDT\Boot, armed in the system store.

        .NOTES
            THE SHARE PATH GOES THROUGH Get-HDTWorkspacePath, not through a
            'Boot' this function spells itself. The workspace layout has one
            place of truth and a second spelling of it here would be the kind of
            disagreement CLAUDE.md 8 is a list of.

            [IO.Path]::Combine otherwise, never Join-Path: Join-Path resolves
            the drive and throws DriveNotFound for a volume that is not mounted
            on the machine running the test, which would make this function
            untestable against a fake (CLAUDE.md 8, Get-HDTWorkspacePath).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Volume,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $DeployRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SystemRoot,

        [Parameter(Mandatory = $true)]
        [ValidateSet('UEFI', 'BIOS')]
        [string] $Firmware,

        [Parameter()]
        [AllowEmptyString()]
        [string] $SystemVolume = '',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BootImageName = 'HDTPE_x64'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE FIXED ENTRY ID, AND IT IS FIXED FOR MDT'S REASON. Teardown runs in a
    # different leg of the run, after a reboot, and has to be able to name the
    # entry without having kept a note of it; a fresh GUID per run would also
    # leave one dead OSLOADER object in the store per reference build.
    #
    # NOT MDT'S {d22e7e91-9ee7-46eb-89d7-c5859e4302f0}. HDT carries no MDT
    # dependency (CLAUDE.md rule 4), and sharing the identifier would mean an
    # HDT teardown deleting an MDT entry, or the reverse, on a machine that had
    # met both.
    $entryId = '{7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}'

    $letter = ([string] $Volume).Trim().TrimEnd('\', '/').TrimEnd(':')
    $letter = $letter.Substring(0, 1).ToUpperInvariant()
    $ramdiskVolume = '{0}:' -f $letter

    # The staged tree. \HDT\Boot rather than MDT's \sources: \HDT is what
    # wimscript.ini already excludes, and the capture exclusion is the whole
    # reason this location was chosen.
    $stageDirectory = '{0}\HDT\Boot' -f $ramdiskVolume
    $wimDevicePath = '\HDT\Boot\boot.wim'
    $sdiDevicePath = '\HDT\Boot\boot.sdi'

    $upper = $Firmware.ToUpperInvariant()

    # UEFI or BIOS, decided once. The DVD\EFI and DVD\PCAT trees both ship in
    # every Windows installation; the store paths are bcdboot's own layouts.
    $sdiTree = 'PCAT'
    $loaderPath = '\windows\system32\boot\winload.exe'
    $storeLeaf = 'Boot\BCD'

    if ($upper -eq 'UEFI') {
        $sdiTree = 'EFI'
        $loaderPath = '\windows\system32\boot\winload.efi'
        $storeLeaf = 'EFI\Microsoft\Boot\BCD'
    }

    $storePath = ''
    if (-not [string]::IsNullOrWhiteSpace($SystemVolume)) {
        $systemLetter = ([string] $SystemVolume).Trim().TrimEnd('\', '/').TrimEnd(':')
        $systemLetter = $systemLetter.Substring(0, 1).ToUpperInvariant()
        $storePath = '{0}:\{1}' -f $systemLetter, $storeLeaf
    }

    return [pscustomobject] ([ordered] @{
            EntryId        = $entryId
            Description    = 'HDT Windows PE'
            SourceWimPath  = Get-HDTWorkspacePath -Root $DeployRoot -Kind Boot -ChildPath ('{0}.wim' -f $BootImageName)
            SourceSdiPath  = [System.IO.Path]::Combine($SystemRoot, 'Boot', 'DVD', $sdiTree, 'boot.sdi')
            StageDirectory = $stageDirectory
            WimPath        = '{0}{1}' -f $ramdiskVolume, $wimDevicePath
            SdiPath        = '{0}{1}' -f $ramdiskVolume, $sdiDevicePath
            RamdiskVolume  = $ramdiskVolume
            WimDevicePath  = $wimDevicePath
            SdiDevicePath  = $sdiDevicePath
            LoaderPath     = $loaderPath
            StorePath      = $storePath
        })
}
