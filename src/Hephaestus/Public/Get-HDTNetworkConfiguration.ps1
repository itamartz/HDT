function Get-HDTNetworkConfiguration {
    <#
        .SYNOPSIS
            Reads the machine's current IPv4 configuration - the DHCP lease, or
            whatever is set.

        .DESCRIPTION
            W2's network pane shows what the machine ACTUALLY GOT before asking
            a technician whether to override it. An empty set of boxes under
            "Obtain an IP address automatically" tells them nothing; the lease
            tells them whether the network is working at all, which is usually
            the question they are really asking.

            WMI, NOT NetTCPIP, AND THAT IS NOT A STYLE CHOICE.
            Get-NetIPAddress does not exist in a WinPE image built from the ADK -
            the NetTCPIP module is simply not there, and it is what killed the
            first SMB probe. Win32_NetworkAdapterConfiguration is present by
            construction, because WinPE-WMI is one of the six components
            Get-HDTBootImageComponent always injects.

            THE ADAPTER WITH A DEFAULT GATEWAY WINS, and among equals the first
            one WMI enumerates. On a machine carrying virtual switches the first
            IPEnabled adapter is routinely a VMnet with an address and no route
            to anything, so "the first one with an address" is the wrong answer
            on every developer machine this is built on.

            IPv4 ONLY, AND ROUTABLE ONLY. Loopback and APIPA are filtered out:
            169.254.x.x is precisely the "DHCP did not answer" case, and showing
            it in the IP box as though it were a lease would tell a technician
            the opposite of the truth. When nothing routable is present the
            fields come back empty and HasLease is false, which is the honest
            answer and the one the pane should display.

        .PARAMETER CimProvider
            An ICimProvider. Defaults to the real adapter.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with HasLease,
            IPAddress, SubnetMask, Gateway, DnsServer (string[]), DnsServerText
            and AdapterDescription.

        .EXAMPLE
            $network = Get-HDTNetworkConfiguration
            if ($network.HasLease) { $network.IPAddress }

            The address this machine can be reached on, or nothing when there is no
            lease yet.

        .EXAMPLE
            $network.Adapter | ForEach-Object { '{0} {1}' -f $_.Name, $_.Status }

            Every adapter and what it is doing. A machine that looks connected and can
            reach nothing is the case worth catching here - an APIPA address is
            not an address.

    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $CimProvider
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $CimProvider) { $CimProvider = New-HDTCimProvider }

    $result = [ordered] @{
        HasLease           = $false
        IPAddress          = ''
        SubnetMask         = ''
        Gateway            = ''
        DnsServer          = [string[]] @()
        DnsServerText      = ''
        AdapterDescription = ''
    }

    # THE ADAPTER WITH A GATEWAY WINS, and this is not cosmetic. On a machine
    # with virtual switches - this build host has five VMware VMnets, three
    # Hyper-V vEthernets and a Tailscale tunnel - the FIRST IPEnabled adapter is
    # a VMnet with an address, no gateway and no route to anywhere. Showing it
    # in a deployment wizard would tell a technician the network is fine when
    # the share is unreachable.
    #
    # A gateway is the cheapest available proxy for "this adapter can reach
    # something". Adapters without one are still considered, but last, so a
    # genuinely gateway-less lab still shows an address rather than nothing.
    $candidate = @()

    foreach ($current in @($CimProvider.GetInstance('Win32_NetworkAdapterConfiguration'))) {
        if (-not $current.IPEnabled) { continue }

        # @($null).Count IS 1 IN POWERSHELL, and that is what made the first
        # version of this selection a no-op: an adapter with NO gateway counted
        # as having one, every adapter compared equal, and the machine showed
        # whichever VMnet the sort happened to surface. An empty string is not a
        # route either. tests/unit/Get-HDTNetworkConfiguration.Tests.ps1 pins it
        # against the captured shape of this host.
        $gateway = @(@($current.DefaultIPGateway) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })

        $candidate += [pscustomobject] @{
            Adapter = $current
            Gateway = $gateway
        }
    }

    # ROUTED FIRST, ENUMERATION ORDER WITHIN EACH GROUP. Two filtered passes
    # rather than Sort-Object: sorting is NOT STABLE in Windows PowerShell 5.1
    # and -Stable does not exist before 6.2, so which of two equally routed
    # adapters the wizard displays would otherwise be unspecified. Where-Object
    # preserves input order, so this is the same answer every run.
    $ordered = @(@($candidate | Where-Object { $_.Gateway.Count -ge 1 }) +
        @($candidate | Where-Object { $_.Gateway.Count -eq 0 }))

    foreach ($entry in $ordered) {
        $current = $entry.Adapter

        $address = @($current.IPAddress)
        $mask = @($current.IPSubnet)

        # BY POSITION, because IPAddress and IPSubnet are PARALLEL ARRAYS. An
        # adapter that lists its IPv6 address first would otherwise report that
        # address's prefix length - '64' - in the subnet mask box.
        for ($position = 0; $position -lt $address.Count; $position++) {
            $current4 = [string] $address[$position]

            # IPv4, routable. See the header: APIPA is the failure case, not a
            # lease, and must not be shown as one.
            if ([string]::IsNullOrWhiteSpace($current4)) { continue }
            if ($current4 -like '*:*' -or $current4 -like '127.*' -or $current4 -like '169.254.*') { continue }

            $result['HasLease'] = $true
            $result['IPAddress'] = $current4
            $result['AdapterDescription'] = [string] $current.Description

            if ($position -lt $mask.Count) { $result['SubnetMask'] = [string] $mask[$position] }

            if ($entry.Gateway.Count -ge 1) { $result['Gateway'] = [string] $entry.Gateway[0] }

            $dns = @(@($current.DNSServerSearchOrder) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
                    ForEach-Object { [string] $_ })
            $result['DnsServer'] = [string[]] $dns
            $result['DnsServerText'] = ($dns -join ', ')

            break
        }

        if ($result['HasLease']) { break }
    }

    return [pscustomobject] $result
}
