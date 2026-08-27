function Get-HDTBootImageDriverInjection {
    <#
        .SYNOPSIS
            What Update-HDTBootImage should hand DISM: whole folders, or
            the .inf files inside them.

        .DESCRIPTION
            THE TICK BOX HAS TO CHANGE WHAT DISM RECEIVES, or it is decoration.
            Add-WindowsDriver on a folder with -Recurse takes everything in it;
            there is no "except that one". So a folder holding a disabled driver
            cannot be injected as a folder - it has to go in one .inf at a time,
            with the disabled ones left out.

            AND EVERY OTHER FOLDER STILL GOES IN WHOLE, which is the point of
            deciding this per folder rather than globally. A vendor pack of forty
            drivers with nothing disabled is ONE DISM call; the same pack with
            one driver turned off is thirty-nine. Injecting every driver
            individually always would turn a two-second step into forty calls on
            every share, to serve a case most shares never have.

            A FOLDER WITH NOTHING IN IT IS STILL A FOLDER CALL. It is the same
            outcome either way, and a build whose operation list changed shape
            because a folder happened to be empty would be a build nobody could
            assert about.

            IT DECIDES, IT DOES NOT INJECT. The caller has the service; this has
            the driver list, and returns what to call with.

        .PARAMETER Folder
            The folders the selection profile resolved to, in declared order.

        .PARAMETER Driver
            What Get-HDTDriver answered for the share.

        .PARAMETER Root
            The deployment share root, for turning a driver's relative path back
            into the folder it sits under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per DISM call, in order,
            with Path and Recurse. Recurse is $true for a whole folder and
            $false for a single .inf.

        .EXAMPLE
            Get-HDTBootImageDriverInjection -Folder $resolved.Path -Driver (Get-HDTDriver -Root $root) -Root $root

        .EXAMPLE
            @(Get-HDTBootImageDriverInjection -Folder $f -Driver $d -Root $r | Where-Object { -not $_.Recurse })

            The folders that had something disabled in them - the only ones that
            cost more than one call.

        .LINK
            Get-HDTDriver
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Folder,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Driver = @(),

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        # ONE CALL PER DRIVER, SO SOMETHING CAN COUNT THEM.
        #
        # A folder injected with -Recurse is ONE Add-WindowsDriver that DISM
        # works through for a minute with no callback of any kind, so the build's
        # step 10 parked on "Injecting the boot drivers" and said nothing else
        # for the whole of it. There is nothing to report against unless the
        # calls are the drivers.
        #
        # IT IS A SWITCH BECAUSE THE COST IS REAL: a vendor pack of seventy
        # drivers becomes seventy calls instead of one. The build asks for it
        # deliberately; every other caller keeps the cheap shape.
        [Parameter()]
        [switch] $PerDriver,

        # MDT'S "network and mass storage drivers only", as a list of classes.
        # Empty injects everything, which is what every share does today.
        #
        # A FILTER FORCES PER-DRIVER INJECTION. DISM's -Recurse takes a folder
        # whole and has no "except the display ones", so the moment a class is
        # named the folder has to be handed over one .inf at a time - the same
        # reason a disabled driver already forces it.
        #
        # A DRIVER WHOSE CLASS CANNOT BE READ IS KEPT. Some .inf files declare no
        # Class at all, and dropping one because a field was missing could remove
        # the NIC driver from a boot image and leave a machine that boots and
        # cannot reach the share - failing towards a smaller image is the wrong
        # direction when the cost of being wrong is a bench visit.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Class = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $store = Get-HDTWorkspacePath -Root $Root -Kind Drivers
    $call = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Folder)) {
        $full = [string] $current

        # WHICH DRIVERS LIVE UNDER THIS FOLDER. A profile names a folder and the
        # drivers under it are everything at or below that path - the same
        # "and everything under it" an include already means.
        $relative = $full
        if ($relative.StartsWith($store, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $relative.Substring($store.Length).TrimStart('\', '/')
        }

        $prefix = $relative
        if (-not [string]::IsNullOrEmpty($prefix)) { $prefix = $prefix.TrimEnd('\') + '\' }

        $inside = @($Driver | Where-Object {
                [string]::IsNullOrEmpty($prefix) -or
                ([string] $_.Path).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            })

        $off = @($inside | Where-Object { -not [bool] $_.Enabled })

        # THE CLASS FILTER, WHICH BEHAVES LIKE A SECOND KIND OF 'disabled': it
        # decides which drivers go in, so it forces the same per-driver shape.
        $filtered = $false

        if (@($Class).Count -gt 0) {
            $filtered = $true

            $inside = @($inside | Where-Object {
                    $one = [string] $_.Class

                    # NO CLASS MEANS KEEP, not drop. See the parameter's note:
                    # removing a driver because a field was unreadable is how a
                    # boot image loses the card it needed.
                    [string]::IsNullOrWhiteSpace($one) -or ($Class -contains $one)
                })

            $off = @($inside | Where-Object { -not [bool] $_.Enabled })
        }

        # A CATALOG THAT ANSWERED NOTHING FOR THIS FOLDER CANNOT BE SPLIT BY, and
        # that is not the same as a folder with no drivers in it: Get-HDTDriver
        # failing, or a folder whose .inf files this build cannot read, would
        # otherwise turn -PerDriver into a boot image with NOTHING injected.
        # The folder goes in whole - one call, no progress, and a build that
        # works.
        $splittable = ($PerDriver -and @($inside).Count -gt 0)

        # A FILTER THAT MATCHED NOTHING INJECTS NOTHING FROM THIS FOLDER, and
        # says so by adding no calls - rather than falling through to the
        # whole-folder shape below, which would inject everything the filter had
        # just excluded. A profile naming a folder of display drivers with a
        # network-and-storage filter is a legitimate combination that should
        # contribute no drivers, not all of them.
        if ($filtered -and @($inside).Count -eq 0) { continue }

        # NOTHING DISABLED: ONE CALL, the whole folder, exactly as before.
        if (@($off).Count -eq 0 -and -not $splittable -and -not $filtered) {
            [void] $call.Add([pscustomobject] @{ Path = $full; Recurse = $true; Name = '' })
            continue
        }

        foreach ($one in @($inside | Where-Object { [bool] $_.Enabled })) {
            [void] $call.Add([pscustomobject] @{
                    Path    = [string] $one.FullPath
                    Recurse = $false

                    # WHAT THE WINDOW PUTS BESIDE THE COUNT. A full path is the
                    # width of the strip and tells a technician nothing they
                    # cannot see from the folder they picked; the .inf name is
                    # what a driver is called.
                    Name    = [string] $one.InfName
                })
        }
    }

    return [pscustomobject[]] @($call)
}
