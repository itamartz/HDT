function New-HDTBootIso {
    <#
        .SYNOPSIS
            Builds a bootable ISO from a WinPE media tree with oscdimg, staging
            the boot bits somewhere oscdimg can actually read them.

        .DESCRIPTION
            The ISO is a first-class debugging artifact, not a byproduct.
            Mounting it into a VM is the fastest loop for testing a sequence:
            no PXE stack, no DHCP scope, no WDS.

            Update-HDTBootImage calls this as its last step, but it is a command
            in its own right - point it at any WinPE media tree and it produces a
            bootable ISO.

            SIX STEPS, AND STEP 2 IS THE ONE THAT MATTERS:

              1. Resolve Oscdimg, EtfsBoot, EfiSys and EfiSysNoPrompt through
                 Get-HDTAdkPath. NEVER A LITERAL - PROJECT.md: "the layout has
                 moved between ADK releases."

              2. STAGE the boot bits it needs into -BootBitPath. THIS EXISTS
                 BECAUSE oscdimg REQUIRES IT, NOT FOR TIDINESS. The ADK lives under
                 'C:\Program Files (x86)\...', and oscdimg's -bootdata: cannot
                 take a quoted path: a quoted path arrives doubled and oscdimg
                 answers "ERROR: Could not open boot sector file
                 ""C:\Program Files (x86)\...\etfsboot.com"" / Error 123". The
                 verified fix is to copy the bits to a space-free directory and
                 build the argument unquoted. Get-HDTBootIsoArgument refuses a
                 -BootBitPath with a space, so the staging cannot be quietly
                 skipped.

              3. Get-HDTBootIsoArgument - all six firmware/no-prompt
                 combinations, asserted as exact strings in a unit suite.

              4. ShouldProcess on the ISO path. It overwrites a file a fleet may
                 be booting from.

              5. NewIso, through the injected IBootImageService.

              6. Report Path, SizeBytes, Firmware, NoPromptForKey, Label,
                 MediaRoot and Sha256.

            ONLY THE BITS IT NEEDS ARE STAGED. UEFI stages one file - efisys.bin
            or efisys_noprompt.bin; BIOS stages etfsboot.com; Both stages two.
            A test asserts which, because staging the wrong El Torito image
            produces an ISO that boots and prompts, which looks like success
            until an unattended VM sits at the prompt until it times out.

            -NoPromptForKey DEFAULTS OFF HERE and Update-HDTBootImage passes it
            ON unless -PromptForKey was given, because a boot image you mount to
            test something should just boot. A direct caller building media for
            a shelf gets the Microsoft default.

            THERE IS NO NO-PROMPT etfsboot. The Oscdimg folder holds
            oscdimg.exe, etfsboot.com, efisys.bin, efisys_noprompt.bin and the
            two _EX variants and nothing else, so -NoPromptForKey with
            -Firmware BIOS warns and builds an ISO that will prompt. HDT states
            this rather than pretending otherwise.

        .PARAMETER MediaRoot
            The WinPE media tree to burn - the ADK's Media template with
            sources\boot.wim in it.

        .PARAMETER Path
            The ISO to write. Overwritten if it exists.

        .PARAMETER Firmware
            UEFI (default), BIOS or Both.

        .PARAMETER NoPromptForKey
            Remove the "Press any key to boot from CD or DVD..." pause on the
            UEFI leg, by staging efisys_noprompt.bin. No effect on BIOS, which
            warns.

        .PARAMETER Label
            The ISO volume label, uppercased into the argument. HDTPE_x64 by
            default. A label with a space is refused.

        .PARAMETER BootBitPath
            Where to stage the boot bits. Defaults to
            $env:SystemDrive\HDTBootBits, which has no space by construction.
            Update-HDTBootImage passes its own scratch directory so the staging
            happens somewhere the build cleans.

        .PARAMETER AdkRoot
            An explicit ADK root, which wins over the registry.

        .PARAMETER Architecture
            amd64 (default) or arm64.

        .PARAMETER BootImageService
            An IBootImageService. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Registry
            An IRegistryService, for resolving the ADK. Defaults to the real
            adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, SizeBytes,
            Sha256, Firmware, NoPromptForKey, Label and MediaRoot.

        .EXAMPLE
            $media = 'C:\HDTLab\Share\Boot\media'
            $iso = 'C:\HDTLab\Share\Boot\HDTPE_x64.iso'
            New-HDTBootIso -MediaRoot 'C:\HDTLab\scratch\bootimage\work\media' `
                -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.iso' -NoPromptForKey

            The debugging ISO: mount it into a Generation 2 VM and it boots
            straight into WinPE with no keypress.

        .EXAMPLE
            New-HDTBootIso -MediaRoot $media -Path $iso -Firmware Both

            A dual BIOS + UEFI ISO for legacy hardware. Without
            -NoPromptForKey, because the BIOS leg would prompt anyway.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $MediaRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateSet('UEFI', 'BIOS', 'Both')]
        [string] $Firmware = 'UEFI',

        [Parameter()]
        [switch] $NoPromptForKey,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Label = 'HDTPE_x64',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BootBitPath = (Join-Path -Path $env:SystemDrive -ChildPath 'HDTBootBits'),

        [Parameter()]
        [AllowEmptyString()]
        [string] $AdkRoot = '',

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture = 'amd64',

        [Parameter()]
        [AllowNull()]
        [object] $BootImageService,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $Registry
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Registry) { $Registry = New-HDTRegistryService }
    if ($null -eq $BootImageService) { $BootImageService = New-HDTBootImageService }

    $adkSplat = @{
        Architecture = $Architecture
        Registry     = $Registry
        FileSystem   = $FileSystem
    }
    if (-not [string]::IsNullOrWhiteSpace($AdkRoot)) { $adkSplat['Root'] = $AdkRoot }

    # -- 1. the ADK, resolved and never written down -------------------------

    $oscdimg = Get-HDTAdkPath -Asset Oscdimg @adkSplat

    # Which El Torito images this firmware needs, and only those. Staging one
    # that is not needed is harmless; staging the wrong one produces an ISO that
    # boots AND PROMPTS, which looks like success until an unattended VM times
    # out at the prompt.
    $needed = New-Object -TypeName System.Collections.ArrayList

    if ($Firmware -eq 'BIOS' -or $Firmware -eq 'Both') {
        [void] $needed.Add((Get-HDTAdkPath -Asset EtfsBoot @adkSplat))
    }

    if ($Firmware -eq 'UEFI' -or $Firmware -eq 'Both') {
        $efiAsset = 'EfiSys'
        if ($NoPromptForKey) { $efiAsset = 'EfiSysNoPrompt' }

        [void] $needed.Add((Get-HDTAdkPath -Asset $efiAsset @adkSplat))
    }

    # -- 2. SPIKES S2's staging ----------------------------------------------
    #
    # THIS IS NOT TIDINESS. oscdimg's -bootdata: cannot take a quoted path and
    # the ADK path has spaces in it; the verified fix is to copy the bits
    # somewhere without one and build the argument unquoted. The argument builder
    # refuses a path with a space, so this cannot be skipped by a later caller.

    $bits = $BootBitPath.TrimEnd('\', '/')
    $FileSystem.CreateDirectory($bits)

    foreach ($source in $needed) {
        $FileSystem.CopyItem($source, [System.IO.Path]::Combine($bits, [System.IO.Path]::GetFileName($source)))
    }

    # -- 3. the argument ------------------------------------------------------

    $argument = Get-HDTBootIsoArgument -Firmware $Firmware -NoPromptForKey:$NoPromptForKey `
        -BootBitPath $bits -Label $Label

    # -- 4/5. the burn --------------------------------------------------------

    $description = 'Build a {0} boot ISO from {1}' -f $Firmware, $MediaRoot

    if (-not $PSCmdlet.ShouldProcess($Path, $description)) {
        return [pscustomobject] @{
            Path           = $Path
            SizeBytes      = [long] 0
            Sha256         = ''
            Firmware       = $Firmware
            NoPromptForKey = [bool] $NoPromptForKey
            Label          = $Label
            MediaRoot      = $MediaRoot
            Oscdimg        = $oscdimg
        }
    }

    $BootImageService.NewIso($MediaRoot, $Path, [string[]] @($argument))

    # -- 6. the row -----------------------------------------------------------

    return [pscustomobject] @{
        Path           = $Path
        SizeBytes      = [long] $FileSystem.GetLength($Path)
        Sha256         = [string] $FileSystem.GetHash($Path)
        Firmware       = $Firmware
        NoPromptForKey = [bool] $NoPromptForKey
        Label          = $Label
        MediaRoot      = $MediaRoot
        Oscdimg        = $oscdimg
    }
}
