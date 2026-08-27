function Get-HDTDriverMatch {
    <#
        .SYNOPSIS
            The drivers in a store that are for the machine in front of you,
            best first.

        .DESCRIPTION
            THE PnP FALLBACK, AND ONLY THE FALLBACK. Group match is the primary
            path and stays MDT's: a rule builds HDTDriverGroup out of make and
            model, ApplyDrivers injects that folder whole, and nothing here is
            consulted. This is what answers when no group matched - the
            unrecognised model that would otherwise deploy with whatever the
            applied image happened to have inbox.

            WINDOWS HAS ALREADY RANKED THE IDS, which is the thing worth knowing
            before reading the sort. A device publishes HardwareID ordered most
            specific first:

              PCI\VEN_8086&DEV_466E&SUBSYS_382817AA&REV_02
              PCI\VEN_8086&DEV_466E&SUBSYS_382817AA
              PCI\VEN_8086&DEV_466E&CC_060400

            and CompatibleID is the generic tail behind it. So specificity is
            NOT a score computed here by counting ampersands - it is the INDEX
            at which the driver matched. Lower wins, and every CompatibleID
            ranks behind every HardwareID because that is what the array order
            means. A scoring scheme of our own would be a second opinion about
            something Windows has already decided, and it would disagree on
            exactly the ids that are hard.

            THE TIE-BREAK IS WHERE A WRONG ANSWER IS EXPENSIVE. Two packs claim
            the same id - a vendor one and an inbox one, or an A05 and an A10 -
            and the machine gets whichever came off the disk first unless
            something orders them. Version descending, then date descending,
            both parsed rather than compared as text.

            A DISABLED DRIVER IS NOT A CANDIDATE. Control\driver-state.yaml is
            how an administrator withdraws a driver that bricks a model without
            deleting the pack it arrived in; a match that ignored it would
            quietly put it back on the next deployment.

            ONE ROW PER DRIVER, NOT PER DEVICE. What the caller needs is the SET
            of .inf files to inject, and a driver serving four ports of one NIC
            is still one injection. The row keeps the best rank it achieved and
            the device that earned it, so a report can say why it was chosen.

        .PARAMETER Device
            The present devices, as Get-HDTPresentDevice answers them: rows with
            HardwareID and CompatibleID.

        .PARAMETER Driver
            The candidate drivers, as Get-HDTDriver answers them: rows with
            HardwareId, Version, Date and Enabled.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per matched driver, best
            first, with Driver, Rank, Source, MatchedId and DeviceName.

        .EXAMPLE
            $device = Get-HDTPresentDevice
            $driver = Get-HDTDriver -Root 'C:\HDTLab\Share'
            Get-HDTDriverMatch -Device $device -Driver $driver

            What a PnP fallback would inject on this machine, in the order it
            would choose.

        .EXAMPLE
            Get-HDTDriverMatch -Device $device -Driver $driver |
                Select-Object -First 1 -ExpandProperty Driver

            The single best candidate - what to inject when only one will do.

        .LINK
            Get-HDTDriver

        .LINK
            Get-HDTPresentDevice
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Device,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyCollection()]
        [object[]] $Driver
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A row assembled by hand need not carry every property Get-HDTDriver sets,
    # and StrictMode makes reading an absent one an error rather than a null.
    $read = {
        param([object] $Row, [string] $Name)

        if ($null -eq $Row) { return $null }
        if ($null -eq $Row.PSObject.Properties[$Name]) { return $null }

        return $Row.PSObject.Properties[$Name].Value
    }

    # -- what the machine is asking for -----------------------------------
    #
    # Flattened to id -> best rank, because the same id appears on more than one
    # device (four ports of one NIC) and the best rank is the one that decides.
    # The device that earned it is kept so a report can name it.

    $want = @{}

    foreach ($current in @($Device)) {
        if ($null -eq $current) { continue }

        $hardware = @(& $read $current 'HardwareID')
        $compatible = @(& $read $current 'CompatibleID')
        $deviceName = [string] (& $read $current 'Name')

        # EVERY CompatibleID RANKS BEHIND EVERY HardwareID, and this offset is
        # how: a generic PCI\CC_0108 match on one device must never outrank a
        # VEN+DEV match on another.
        $offset = $hardware.Count

        for ($index = 0; $index -lt ($hardware.Count + $compatible.Count); $index++) {
            if ($index -lt $offset) {
                $id = $hardware[$index]
                $rank = $index
                $source = 'HardwareID'
            } else {
                $id = $compatible[$index - $offset]
                $rank = $index
                $source = 'CompatibleID'
            }

            if ($null -eq $id) { continue }

            $key = ([string] $id).Trim().ToUpperInvariant()
            if ([string]::IsNullOrEmpty($key)) { continue }

            if ($want.ContainsKey($key) -and [int] $want[$key]['Rank'] -le [int] $rank) { continue }

            $want[$key] = @{
                Id         = [string] $id
                Rank       = [int] $rank
                Source     = [string] $source
                DeviceName = [string] $deviceName
            }
        }
    }

    if ($want.Count -eq 0) { return [pscustomobject[]] @() }

    # -- what the store can offer -----------------------------------------

    $match = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($Driver)) {
        if ($null -eq $current) { continue }

        # A ROW WITHOUT Enabled IS ENABLED. Get-HDTDriver always sets it, but a
        # caller assembling rows by hand should not have to know that a missing
        # flag means anything but "nobody turned this off".
        $enabled = & $read $current 'Enabled'
        if ($null -ne $enabled -and -not [bool] $enabled) { continue }

        $best = $null

        foreach ($id in @(& $read $current 'HardwareId')) {
            if ($null -eq $id) { continue }

            $key = ([string] $id).Trim().ToUpperInvariant()
            if ([string]::IsNullOrEmpty($key)) { continue }
            if (-not $want.ContainsKey($key)) { continue }

            $candidate = $want[$key]

            if ($null -eq $best -or [int] $candidate['Rank'] -lt [int] $best['Rank']) {
                $best = $candidate
            }
        }

        if ($null -eq $best) { continue }

        [void] $match.Add([pscustomobject] @{
                Driver      = $current
                Rank        = [int] $best['Rank']
                Source      = [string] $best['Source']
                MatchedId   = [string] $best['Id']
                DeviceName  = [string] $best['DeviceName']
                SortVersion = (ConvertTo-HDTDriverVersion -Value (& $read $current 'Version'))
                SortDate    = (ConvertTo-HDTDriverDate -Value (& $read $current 'Date'))
            })
    }

    if ($match.Count -eq 0) { return [pscustomobject[]] @() }

    $ordered = @($match | Sort-Object -Property `
        @{ Expression = 'Rank'; Ascending = $true },
        @{ Expression = 'SortVersion'; Descending = $true },
        @{ Expression = 'SortDate'; Descending = $true })

    # SortVersion and SortDate are dropped: they are how the order was reached,
    # not facts about the driver, and a caller reading Version off the row
    # should get the .inf's own string rather than a parsed approximation of it.
    return [pscustomobject[]] @($ordered |
            Select-Object -Property Driver, Rank, Source, MatchedId, DeviceName)
}
