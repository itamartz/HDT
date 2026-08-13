function New-HDTImageService {
    <#
        .SYNOPSIS
            Creates the real IImageService adapter over the DISM cmdlets,
            bcdboot, bcdedit and reagentc.

        .DESCRIPTION
            The one place in HDT that names Get-WindowsImage,
            Expand-WindowsImage, bcdboot.exe, bcdedit.exe or Reagentc.exe.
            PROJECT constraint 4 forbids a step from touching hardware directly,
            so ApplyImage and ConfigureBoot receive this object and can be
            swapped for New-HDTFakeImageService in a test with no media, no disk
            and no reboot.

            FIVE METHODS, AND THE EXACT MECHANISM EACH WRAPS:

              GetImageInfo(imagePath)
                  Get-WindowsImage -ImagePath, then Get-WindowsImage -Index per
                  index for EditionId, Architecture and Version, which the
                  summary form does not carry.

              ApplyImage(imagePath, index, applyPath)
                  Expand-WindowsImage -ImagePath -Index -ApplyPath (DESIGN 9.2).

              InstallBootFile(osRoot, systemVolume, firmware)
                  bcdboot.exe "<OsRoot>\Windows" /s <systemVolume> /f <firmware>,
                  where firmware is UEFI, BIOS or ALL.

              SetRecoveryImage(osRoot, recoveryPath)
                  <OsRoot>\Windows\System32\Reagentc.exe /setreimage
                      /path <recoveryPath> /target <OsRoot>\Windows

              SetBootOrderFirst()
                  bcdedit.exe /set "{fwbootmgr}" displayorder "{bootmgr}" /addfirst

            SetBootOrderFirst IS SPIKES.md S6's FOURTH FINDING AS AN API. After
            apply, a machine that still has the boot media first in the firmware
            order simply reboots into WinPE and the deployment loops. Putting
            the Windows Boot Manager first is what ends the loop; ConfigureBoot
            owns deciding when to call it.

            SetRecoveryImage CALLS THE APPLIED IMAGE'S OWN Reagentc.exe, BY FULL
            PATH, AND USES /setreimage. Two reasons, both checked on this
            machine rather than remembered. First, reagentc on Windows 11 24H2
            has NO /setosimage verb at all - it lists /info, /setreimage,
            /enable, /disable, /boottore, /setbootshelllink and the
            quick-machine-recovery verbs - so the verb in DESIGN 9.2 is wrong
            and 04-03 corrects the document. Second, THERE IS NO WinPE-Recovery
            OPTIONAL COMPONENT: reagentc.exe is not in WinPE, and WinPE is the
            only environment this method is ever called from, so a bare
            'reagentc.exe' would be command-not-found. Microsoft's own offline
            WinRE procedure runs the target image's copy, which exists as soon
            as ApplyImage has finished and is the same 26100 build as the WinPE
            hosting it. Building the path from $OsRoot is argument construction,
            not a branch, so the adapter stays dumb.

            THIS IS AN UNTESTED ADAPTER (DESIGN 12.2.3), and deliberately so:
            four of its five methods write to a disk or reorder this machine's
            firmware boot entries. Its contract row calls GetImageInfo and
            nothing else; the rest is proven in tests/integration (04-04)
            against a scratch VHDX. The price of not testing it is that it must
            stay dumb. THE ONLY BRANCHES BELOW ARE AN EXISTENCE GUARD AND FOUR
            EXIT-CODE CHECKS, each commented as such. Every decision about WHICH
            index to apply or WHETHER a recovery partition exists lives in the
            steps, which are tested against the fake. Do not add logic here.

            EVERY NATIVE FAILURE CARRIES THE TOOL'S OWN OUTPUT. "bcdboot failed"
            without bcdboot's own sentence is the log entry that wastes an hour
            at three in the morning in front of a machine that will not boot.

            It is a [pscustomobject] carrying ScriptMethod members rather than a
            PowerShell class: classes dot-sourced into the module are the known
            flaky path across -Force re-imports (see 01-03).

        .PARAMETER Journal
            The shared cross-service operation journal. When supplied, every
            recorded call is appended to it in addition to $Operations, numbered
            globally across services.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with the five
            IImageService ScriptMethods. Note that Get-Member -MemberType Method
            does NOT list a ScriptMethod - use -MemberType Method, ScriptMethod.

        .EXAMPLE
            $image = New-HDTImageService
            $image.GetImageInfo('C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim') |
                Format-Table Index, Name, Edition, Architecture

            The index catalogue an administrator picks from. Index 1 of the
            staged media is Windows 11 Enterprise LTSC.

        .EXAMPLE
            $image = New-HDTImageService
            $image.ApplyImage('Z:\OperatingSystems\Win11\sources\install.wim', 1, 'W:\')
            $image.InstallBootFile('W:\', 'S:', 'UEFI')
            $image.SetBootOrderFirst()

            The apply ceremony SPIKES.md S6 performed by hand, as three calls.

        .NOTES
            Architecture comes back from Get-WindowsImage as a NUMERIC DISM
            code, not a string: the staged media reports 9, which is amd64. The
            captured fixtures record it as it arrives rather than prettified,
            because a fixture that improved on the tool would be a fixture that
            lied about it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. The destructive methods it exposes are called by ApplyImage and ConfigureBoot, which carry SupportsShouldProcess.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Collections.ArrayList] $Journal
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $service = [pscustomobject] @{
        Operations  = [System.Collections.ArrayList]::new()
        Journal     = $Journal
        ServiceName = 'ImageService'
    }

    $service | Add-Member -MemberType ScriptMethod -Name Record -Value {
        param([string] $Operation, [object[]] $Argument)

        [void] $this.Operations.Add([pscustomobject] @{
                Sequence  = $this.Operations.Count + 1
                Operation = $Operation
                Arguments = $Argument
            })

        if ($null -ne $this.Journal) {
            [void] $this.Journal.Add([pscustomobject] @{
                    Sequence  = $this.Journal.Count + 1
                    Service   = $this.ServiceName
                    Operation = $Operation
                    Arguments = $Argument
                })
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name GetOperationName -Value {
        return , ([string[]] @($this.Operations | ForEach-Object { $_.Operation }))
    }

    # Existence guard, not logic. It gives this adapter and the fake the same
    # failure for the same mistake - a WIM path that is not there - where
    # Get-WindowsImage would otherwise report a DISM error that does not say
    # plainly that the file is missing.
    $service | Add-Member -MemberType ScriptMethod -Name AssertImage -Value {
        param([string] $ImagePath)

        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new(
                "Could not find image '$ImagePath'.", $ImagePath)
        }
    }

    # The whole of the allowed logic in a native call: run it, and if it failed,
    # throw with the tool's own output attached (DESIGN 12.2.3).
    $service | Add-Member -MemberType ScriptMethod -Name AssertExitCode -Value {
        param([int] $ExitCode, [string] $Tool, [string] $CommandLine, [object[]] $Output)

        if ($ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new(
                ("{0} exited {1} for: {2}{3}{4}" -f $Tool, $ExitCode, $CommandLine,
                    [System.Environment]::NewLine, (@($Output) -join [System.Environment]::NewLine)))
        }
    }

    # -- IImageService ------------------------------------------------------

    $service | Add-Member -MemberType ScriptMethod -Name GetImageInfo -Value {
        param([string] $ImagePath)

        $this.Record('GetImageInfo', @($ImagePath))
        $this.AssertImage($ImagePath)

        # A foreach over the indices, no branch. The summary form carries the
        # index, name, description and size; EditionId, Architecture and
        # Version only come back from the per-index form.
        $row = foreach ($image in @(Get-WindowsImage -ImagePath $ImagePath)) {
            $detail = Get-WindowsImage -ImagePath $ImagePath -Index $image.ImageIndex

            [pscustomobject] @{
                Index        = [int] $image.ImageIndex
                Name         = [string] $image.ImageName
                Description  = [string] $image.ImageDescription
                Edition      = [string] $detail.EditionId
                SizeBytes    = [long] $image.ImageSize
                Architecture = [string] $detail.Architecture
                Version      = [string] $detail.Version
            }
        }

        # The unary comma is mandatory: a ScriptMethod returning an array
        # collapses a one-element array to a scalar without it, and a WIM with
        # a single index is the normal case (tests/helpers/README.md F3).
        return , ([object[]] @($row))
    }

    $service | Add-Member -MemberType ScriptMethod -Name ApplyImage -Value {
        param([string] $ImagePath, [int] $Index, [string] $ApplyPath)

        $this.Record('ApplyImage', @($ImagePath, $Index, $ApplyPath))
        $this.AssertImage($ImagePath)

        # DESIGN 9.2. SPIKES.md S6 applied a 4 GB WIM this way over SMB in 95
        # seconds, so a network apply is not a performance concern.
        Expand-WindowsImage -ImagePath $ImagePath -Index $Index -ApplyPath $ApplyPath | Out-Null
    }

    $service | Add-Member -MemberType ScriptMethod -Name InstallBootFile -Value {
        param([string] $OsRoot, [string] $SystemVolume, [string] $Firmware)

        $this.Record('InstallBootFile', @($OsRoot, $SystemVolume, $Firmware))

        $windows = Join-Path -Path $OsRoot -ChildPath 'Windows'
        $output = @(& "$env:SystemRoot\System32\bcdboot.exe" $windows '/s' $SystemVolume '/f' $Firmware 2>&1)

        # Exit-code check, with bcdboot's own sentence attached.
        $this.AssertExitCode($LASTEXITCODE, 'bcdboot.exe',
            ('bcdboot {0} /s {1} /f {2}' -f $windows, $SystemVolume, $Firmware), $output)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetRecoveryImage -Value {
        param([string] $OsRoot, [string] $RecoveryPath)

        $this.Record('SetRecoveryImage', @($OsRoot, $RecoveryPath))

        # The APPLIED IMAGE'S OWN reagentc, by full path: WinPE has none, and
        # there is no WinPE-Recovery optional component to add one. Argument
        # construction, not a branch.
        $windows = Join-Path -Path $OsRoot -ChildPath 'Windows'
        $reagentc = Join-Path -Path $windows -ChildPath 'System32\Reagentc.exe'

        # /setreimage, NOT /setosimage: reagentc on Windows 11 24H2 has no such
        # verb. DESIGN 9.2 is corrected in 04-03.
        $output = @(& $reagentc '/setreimage' '/path' $RecoveryPath '/target' $windows 2>&1)

        $this.AssertExitCode($LASTEXITCODE, 'Reagentc.exe',
            ('{0} /setreimage /path {1} /target {2}' -f $reagentc, $RecoveryPath, $windows), $output)
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetBootOrderFirst -Value {
        $this.Record('SetBootOrderFirst', @())

        # SPIKES.md S6: after apply, a machine whose firmware still has the boot
        # media first simply reboots into WinPE and the deployment loops.
        $output = @(& "$env:SystemRoot\System32\bcdedit.exe" '/set' '{fwbootmgr}' 'displayorder' '{bootmgr}' '/addfirst' 2>&1)

        $this.AssertExitCode($LASTEXITCODE, 'bcdedit.exe',
            'bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst', $output)
    }

    return $service
}
