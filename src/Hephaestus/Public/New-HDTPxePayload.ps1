function New-HDTPxePayload {
    <#
        .SYNOPSIS
            Stages everything a non-WDS TFTP or HTTP stack needs to serve the HDT
            boot image, and verifies every copy by hash.

        .DESCRIPTION
            For sites with an existing TFTP/HTTP stack instead of
            WDS, New-HDTPxePayload stages bootmgr, bootmgfw.efi, boot.sdi, the
            BCD, and the boot WIM into a directory to point that server at."

            THE REQUIRED SET IS A DECLARED TABLE, AND -ListRequired HANDS IT
            BACK. The tests read that same table rather than a second copy of it,
            so completeness is checked against ONE list. A row added without a
            copy landing turns the suite red; a row deleted stops being asserted,
            which is why the row count is pinned as well.

              Boot\<arch>\bootmgr.exe             ADK Media  bootmgr
              Boot\<arch>\wdsmgfw.efi  (optional) ADK Media  EFI\Boot\bootx64.efi
              Boot\<arch>\bootmgfw.efi            ADK Media  bootmgr.efi
              Boot\<arch>\boot.sdi                ADK Media  Boot\boot.sdi
              Boot\<arch>\BCD                     ADK Media  Boot\BCD
              Boot\<arch>\Fonts\*                 ADK Media  Boot\Fonts\*
              Boot\<arch>\Images\<name>.wim       workspace  Boot\<name>.wim
              Boot\<arch>\<name>.manifest.json    workspace  Boot\<name>.manifest.json

            wdsmgfw.efi IS OPTIONAL AND DOES NOT AFFECT Complete, because a
            site's TFTP stack may want either name for the same bootloader and
            this command does not know which. It is reported in Skipped rather
            than dropped silently.

            WHAT 'Complete' MEANS: every declared file is staged and its bytes
            verify. IT DOES NOT MEAN A MACHINE WILL PXE BOOT FROM THIS, and this
            file will not make the larger claim. The BCD staged here is the ADK
            media template, which describes booting sources\boot.wim from
            removable media; a TFTP/HTTP stack generally needs its own BCD store
            and its own device element.

            THIS PAYLOAD HAS NEVER BEEN NETWORK-BOOTED by anything in this
            repository - there is no WDS on this host and PROJECT.md confines a
            PXE responder to the isolated 'HDT Lab' switch - so claiming staging
            completeness is honest and claiming bootability would not be.
            tests/integration/PxePayload.Integration.Tests.ps1 asserts that this
            sentence is still here.

            EVERY COPY IS VERIFIED BY HASH AND A MISMATCH IS A FAILURE, NOT A
            WARNING. A truncated boot.sdi on a TFTP server is a machine that
            hangs at boot with no message on the screen and no line in any log;
            an operator who was warned about it in a scrollback they closed is an
            operator with a fleet that does not boot.

            Everything goes through IFileSystem and every ADK path through
            Get-HDTAdkPath - PROJECT.md's rule, because the kit layout has moved
            between ADK releases and a literal would work here forever and fail
            in the field.

        .PARAMETER WorkspaceRoot
            The deployment share. Boot\<name>.wim and its manifest are read from
            it, and it is the one place this command refuses to write.

        .PARAMETER Path
            Where to stage the payload - the directory a TFTP or HTTP server is
            pointed at. Must be outside the workspace: the payload is for a
            different server, and a copy of the share inside the share is a share
            that grows a copy of itself every time somebody runs this.

        .PARAMETER Architecture
            amd64 (default) or arm64, in the ADK's vocabulary. The destination
            folder uses the PXE tree's: amd64 stages under Boot\x64.

        .PARAMETER BootImageName
            The boot image base name, HDTPE_x64 by default - which is
            workspace.yaml's own default for bootImage.name. Name another if the
            workspace declares one.

        .PARAMETER ListRequired
            Return the declared table instead of staging anything: Destination,
            Source, Origin, Required and Kind, in table order.

        .PARAMETER AdkRoot
            An explicit ADK root, which wins over the registry.

        .PARAMETER BootLoaderPath
            A folder holding bootmgr.efi and bootmgfw.efi from a FULLY PATCHED
            Windows - '%SystemRoot%\Boot\EFI' on a patched host. The payload's
            two UEFI loader rows are staged FROM IT instead of from the ADK
            media, hashed and verified like every other row.

            BOTH DELIVERY PATHS OR NEITHER. Correcting the ISO and leaving the
            TFTP root alone leaves PXE serving the same revoked loader; the two
            are one product to the person whose machine shows Security Violation.

            Omitted, the ADK media supplies them as it always has. See SPIKES
            S20 for why the ADK's copies are refused and why a Windows install
            media is not the fix.

            ⚠ THE SWAP PRODUCES MEDIA THAT DOES NOT BOOT. DO NOT USE IT.
            Six Generation 2 Hyper-V runs across two builds (SPIKES S20.2 and
            S20.4), and no build has ever produced swapped media that starts:

              2026-09-07, boot managers only
                swapped media, Secure Boot ON    FAIL - 0xc0430001
                the same ISO,  Secure Boot OFF   PASS - WinPE reached
                unswapped ADK, Secure Boot ON    PASS - WinPE reached

              2026-09-10, boot managers AND a serviced OS loader copied in
                swapped media, Secure Boot ON    FAIL - 0xc0430001
                the same ISO,  Secure Boot OFF   FAIL - 0xc0430001
                unswapped ADK, Secure Boot ON    PASS - WinPE and the engine up

            0xc0430001 is STATUS_SECUREBOOT_ROLLBACK_DETECTED. The firmware
            ACCEPTED the swapped boot manager; the boot manager then refused the
            OS loader behind it, because the boot image's own winload.efi is
            10.0.26100.1 against a boot manager of 10.0.28000.342 - an image
            nobody has serviced. It is not gated on Secure Boot; the 2026-09-10
            media refused with Secure Boot off as well. The build REFUSES that
            combination rather than shipping it, and that refusal is correct.

            The cure is to SERVICE the boot image - the cumulative update moves
            winload.efi and ntoskrnl.exe together. Copying a serviced loader in
            was built, boot-tested and measured to make the media strictly
            worse, and it is gone.

            This command cannot mount the WIM it stages, so it reads the OS
            loader version out of Boot\<name>.manifest.json. A manifest that does
            not record one is refused: rebuild the boot image first.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER Registry
            An IRegistryService, for resolving the ADK. Defaults to the real
            adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Architecture,
            BootImageName, Complete, File (Destination, Source, SizeBytes,
            Sha256, Required), Missing and Skipped.

            With -ListRequired: one PSCustomObject per declared row.

        .EXAMPLE
            New-HDTPxePayload -WorkspaceRoot 'C:\HDTLab\Share' -Path 'D:\tftproot'

            Stages the payload and reports Complete when every declared file
            landed and verified.

        .EXAMPLE
            New-HDTPxePayload -ListRequired | Format-Table Destination, Source, Required

            What the payload is declared to contain, without staging it.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Stage', SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Stage')]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Stage')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'List')]
        [switch] $ListRequired,

        [Parameter()]
        [ValidateSet('amd64', 'arm64')]
        [string] $Architecture = 'amd64',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BootImageName = 'HDTPE_x64',

        [Parameter(ParameterSetName = 'Stage')]
        [AllowEmptyString()]
        [string] $AdkRoot = '',

        # OPT-IN, and it substitutes a SOURCE rather than adding a row. The
        # declared table stays the one list (see Get-HDTPxePayloadRow); what
        # changes is where two of its rows are copied from, so -ListRequired
        # still describes the payload and the hashes reported still describe
        # what landed.
        [Parameter(ParameterSetName = 'Stage')]
        [AllowEmptyString()]
        [string] $BootLoaderPath = '',

        [Parameter(ParameterSetName = 'Stage')]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter(ParameterSetName = 'Stage')]
        [AllowNull()]
        [object] $Registry
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $row = @(Get-HDTPxePayloadRow -Architecture $Architecture -BootImageName $BootImageName)

    if ($ListRequired) {
        return [pscustomobject[]] $row
    }

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Registry) { $Registry = New-HDTRegistryService }

    # =====================================================================
    # 1. THE DESTINATION - THE PAYLOAD IS FOR A DIFFERENT SERVER
    # =====================================================================

    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $payloadFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $separator = [System.IO.Path]::DirectorySeparatorChar

    if ($payloadFull -eq $workspaceFull -or
        $payloadFull.StartsWith(($workspaceFull + $separator), [System.StringComparison]::OrdinalIgnoreCase)) {

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message ("the payload path '{0}' is inside the workspace '{1}'. This payload is a copy of the boot bits for a DIFFERENT server - a TFTP or HTTP root - and staging it inside the deployment share gives the share a copy of itself that grows every time this command runs. Choose a path outside the workspace." -f $Path, $WorkspaceRoot)))
    }

    # =====================================================================
    # 2. THE ADK, RESOLVED - NEVER A LITERAL
    # =====================================================================

    $adkSplat = @{
        Asset        = 'WinPeMedia'
        Architecture = $Architecture
        Registry     = $Registry
        FileSystem   = $FileSystem
    }
    if (-not [string]::IsNullOrWhiteSpace($AdkRoot)) { $adkSplat['Root'] = $AdkRoot }

    $mediaRoot = Get-HDTAdkPath @adkSplat

    # =====================================================================
    # 2b. THE SECURE BOOT LOADERS, IF A PATCHED FOLDER WAS NAMED
    # =====================================================================
    #
    # SPIKES S20: the ADK's bootmgr.efi and EFI\Boot\bootx64.efi carry Secure
    # Version Number 3.0 against an enforced floor of 7.0, so a fully patched
    # machine with Secure Boot on refuses them before WinPE loads. Nothing HDT
    # writes can explain that, because HDT never ran.
    #
    # KEYED BY DESTINATION, so the substitution happens where the table already
    # decided which file goes where. Get-HDTBootLoaderSource preserves that
    # pairing - the payload's bootmgfw.efi comes from bootmgr.efi and its
    # wdsmgfw.efi from bootmgfw.efi, which is the ADK's EFI\Boot\bootx64.efi
    # under another name. They are DIFFERENT binaries, so crossing them over
    # yields a payload that stages clean and boots nothing.
    #
    # RESOLVED BEFORE THE FIRST WRITE. A folder that cannot do the job refuses
    # here rather than after half a payload is on somebody's TFTP root.

    $loaderOverride = @{}

    if (-not [string]::IsNullOrWhiteSpace($BootLoaderPath)) {
        try {
            $loaderRow = @(Get-HDTBootLoaderSource -BootLoaderPath $BootLoaderPath -Target Pxe `
                    -Architecture $Architecture -FileSystem $FileSystem)
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        foreach ($loader in @($loaderRow)) {
            $loaderOverride[[string] $loader.Destination] = [string] $loader.Source
        }
    }

    # =====================================================================
    # 3. THE BOOT IMAGE MUST HAVE BEEN BUILT
    # =====================================================================

    $wimSource = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Boot -ChildPath ('{0}.wim' -f $BootImageName)

    if (-not $FileSystem.TestPath($wimSource)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $wimSource -Category ObjectNotFound `
                    -Message ("there is no boot image to stage. Run Update-HDTBootImage against this workspace first - it writes Boot\{0}.wim, Boot\{0}.manifest.json and the ISO beside them; a PXE payload without the WIM is a TFTP root that answers a machine and then has nothing to give it." -f $BootImageName)))
    }

    # =====================================================================
    # 3b. THE SECURE BOOT SERVICING CHECK, READ OUT OF THE MANIFEST
    # =====================================================================
    #
    # THE SWAP AS FIRST SHIPPED PRODUCED MEDIA THAT DOES NOT BOOT, and said
    # nothing about it. Measured on Generation 2 Hyper-V, 2026-09-07 (SPIKES
    # S20.2): swapped media FAILED with Secure Boot on - 0xc0430001,
    # STATUS_SECUREBOOT_ROLLBACK_DETECTED, on a Windows Boot Manager recovery
    # screen - the same ISO PASSED with Secure Boot off, and the unswapped ADK
    # media PASSED with it on. The firmware accepted the replacement boot
    # manager; the boot manager then refused the OS loader behind it, because
    # the image's winload.efi was 10.0.26100.1 against a boot manager of
    # 10.0.28000.342.
    #
    # THE MANIFEST IS WHERE THE FACT LIVES ON THIS SIDE. Update-HDTBootImage can
    # read winload.efi directly, because it has the image open. This command
    # stages a WIM it never mounts, so the version it has to match is the one
    # recorded in Boot\<name>.manifest.json when that WIM was built.
    #
    # A MISSING FIELD IS A REFUSAL, NOT A PASS. An image built before this was
    # recorded cannot be judged, and "cannot be judged" for a feature whose
    # failure mode is a machine that will not start has to stop rather than
    # shrug. Rebuilding the boot image is a one-command remedy and the message
    # says so.

    if (-not [string]::IsNullOrWhiteSpace($BootLoaderPath)) {
        $manifestSource = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Boot `
            -ChildPath ('{0}.manifest.json' -f $BootImageName)

        $osLoaderVersion = ''
        $osLoaderPath = ''

        if ($FileSystem.TestPath($manifestSource)) {
            $manifest = ConvertFrom-Json -InputObject ([string] $FileSystem.ReadAllText($manifestSource))

            # PROBED RATHER THAN INDEXED. Set-StrictMode -Version Latest makes
            # reading an absent property on a PSCustomObject an error, and an
            # older manifest is exactly the case this has to report cleanly.
            if (@($manifest.PSObject.Properties.Name) -contains 'osLoader') {
                if (@($manifest.osLoader.PSObject.Properties.Name) -contains 'version') {
                    $osLoaderVersion = [string] $manifest.osLoader.version
                }
                if (@($manifest.osLoader.PSObject.Properties.Name) -contains 'path') {
                    $osLoaderPath = [string] $manifest.osLoader.path
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($osLoaderVersion)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $manifestSource -Category ObjectNotFound `
                        -Message ("the Secure Boot bootloader swap cannot be proved safe, so it is refused: the boot image manifest '{0}' records no OS loader version. A replacement boot manager will not start an OS loader from an older servicing level while Secure Boot is on (0xc0430001, STATUS_SECUREBOOT_ROLLBACK_DETECTED), and this command stages the WIM without mounting it, so the manifest is the only place that version exists. Run Update-HDTBootImage against this workspace to rebuild the boot image and record it, or stage without -BootLoaderPath and leave the ADK's own matched loaders in place. See .planning/SPIKES.md, S20.2." -f $manifestSource)))
        }

        if ([string]::IsNullOrWhiteSpace($osLoaderPath)) { $osLoaderPath = $manifestSource }

        # THE VALUE AND WHERE IT CAME FROM (CLAUDE.md, logging).
        Write-Verbose ("Secure Boot servicing check: '{0}' records the boot image's OS loader as '{1}', version {2}. Each replacement boot manager is compared against it." -f
            $manifestSource, $osLoaderPath, $osLoaderVersion)

        try {
            Assert-HDTBootLoaderServicingLevel -BootLoaderRow $loaderRow `
                -OsLoaderVersion $osLoaderVersion -OsLoaderPath $osLoaderPath
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }

    # =====================================================================
    # 4. STAGE
    # =====================================================================

    $description = 'Stage the {0} PXE payload ({1} declared row(s))' -f $BootImageName, $row.Count

    $staged = New-Object -TypeName System.Collections.ArrayList
    $missing = New-Object -TypeName System.Collections.ArrayList
    $skipped = New-Object -TypeName System.Collections.ArrayList

    if (-not $PSCmdlet.ShouldProcess($Path, $description)) {
        return [pscustomobject] @{
            Path          = $Path
            Architecture  = $Architecture
            BootImageName = $BootImageName
            Complete      = $false
            File          = [pscustomobject[]] @()
            Missing       = [string[]] @()
            Skipped       = [string[]] @()
        }
    }

    $FileSystem.CreateDirectory($Path)

    # COPY AND VERIFY, ONE FILE. The hash of the source is read before the copy
    # and the hash of the destination after it, and they are compared - so a copy
    # that silently truncated is a failure here rather than a machine that hangs
    # at boot on somebody else's site.
    $copyOne = {
        param([string] $Source, [string] $RelativeDestination, [bool] $Required)

        $destination = [System.IO.Path]::Combine($Path, $RelativeDestination)

        $FileSystem.CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
        $FileSystem.CopyItem($Source, $destination)

        $sourceHash = [string] $FileSystem.GetHash($Source)
        $destinationHash = [string] $FileSystem.GetHash($destination)

        if (-not $sourceHash.Equals($destinationHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("HDTIntegrityError: the staged copy of '{0}' does not match its source. Source '{1}' hashes {2}; the copy at '{3}' hashes {4}. This is reported as a failure and not a warning on purpose: a truncated boot file on a TFTP server is a machine that hangs at boot with no message on the screen and no line in any log." -f
                $RelativeDestination, $Source, $sourceHash, $destination, $destinationHash)
        }

        return [pscustomobject] @{
            Destination = $RelativeDestination
            Source      = $Source
            SizeBytes   = [long] $FileSystem.GetLength($destination)
            Sha256      = $destinationHash
            Required    = $Required
        }
    }

    foreach ($entry in $row) {
        $origin = $mediaRoot
        if ([string] $entry.Origin -eq 'Workspace') { $origin = $WorkspaceRoot }

        $source = [System.IO.Path]::Combine($origin, ([string] $entry.Source))

        # THE SWAP, APPLIED WHERE THE SOURCE IS CHOSEN. Everything below - the
        # existence probe, the copy, the hash comparison, the reported row - then
        # treats a swapped loader exactly like any other file, which is the point:
        # a substituted bootmgfw.efi that truncated in transit must fail here for
        # the same reason a truncated boot.sdi does.
        if ($loaderOverride.ContainsKey([string] $entry.Destination)) {
            $source = [string] $loaderOverride[[string] $entry.Destination]

            Write-Verbose ("Secure Boot loader: '{0}' is staged from '{1}' rather than from the ADK media, whose copy carries Secure Version Number 3.0 against an enforced floor of 7.0." -f
                [string] $entry.Destination, $source)
        }

        if (-not $FileSystem.TestPath($source)) {
            if ([bool] $entry.Required) {
                [void] $missing.Add([string] $entry.Destination)
                Write-Warning ("The PXE payload is incomplete: '{0}' is declared required and its source '{1}' is not there. The payload was staged without it." -f
                    $entry.Destination, $source)
            } else {
                [void] $skipped.Add([string] $entry.Destination)
            }

            continue
        }

        if ([string] $entry.Kind -eq 'Directory') {
            foreach ($child in @($FileSystem.GetChildItem($source))) {
                $leaf = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))

                [void] $staged.Add((& $copyOne ([string] $child) `
                            ([System.IO.Path]::Combine([string] $entry.Destination, $leaf)) `
                            ([bool] $entry.Required)))
            }

            continue
        }

        [void] $staged.Add((& $copyOne $source ([string] $entry.Destination) ([bool] $entry.Required)))
    }

    return [pscustomobject] @{
        Path          = $Path
        Architecture  = $Architecture
        BootImageName = $BootImageName

        # Complete is "every declared REQUIRED row landed and verified". The
        # optional row cannot make it false, and nothing here says the payload
        # will boot a machine.
        Complete      = ($missing.Count -eq 0)
        File          = [pscustomobject[]] @($staged)
        Missing       = [string[]] @($missing)
        Skipped       = [string[]] @($skipped)
    }
}
