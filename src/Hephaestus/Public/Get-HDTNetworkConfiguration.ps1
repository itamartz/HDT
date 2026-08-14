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

            WMI, NOT NetTCPIP, AND THAT IS NOT A STYLE CHOICE. SPIKES S14:
            Get-NetIPAddress does not exist in a WinPE image built from the ADK -
            the NetTCPIP module is simply not there, and it is what killed the
            first SMB probe. Win32_NetworkAdapterConfiguration is present by
            construction, because WinPE-WMI is one of the six components
            Get-HDTBootImageComponent always injects.

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
    # with virtual switches - this build host has five - the FIRST IPEnabled
    # adapter is a VMware VMnet with an address, no gateway and no route to
    # anywhere. Showing 192.168.134.1 in a deployment wizard would tell a
    # technician the network is fine when the share is unreachable.
    #
    # A gateway is the cheapest available proxy for "this adapter can reach
    # something". Adapters without one are still considered, but last, so a
    # genuinely gateway-less lab still shows an address rather than nothing.
    $configuration = @($CimProvider.GetInstance('Win32_NetworkAdapterConfiguration') |
            Where-Object { $_.IPEnabled } |
            Sort-Object -Property @{ Expression = { @($_.DefaultIPGateway).Count -ge 1 }; Descending = $true })

    foreach ($current in $configuration) {
        foreach ($candidate in @($current.IPAddress)) {
            $address = [string] $candidate

            # IPv4, routable. See the header: APIPA is the failure case, not a
            # lease, and must not be shown as one.
            if ($address -like '*:*' -or $address -like '127.*' -or $address -like '169.254.*') {
                continue
            }

            $result['HasLease'] = $true
            $result['IPAddress'] = $address
            $result['AdapterDescription'] = [string] $current.Description

            $mask = @($current.IPSubnet)
            if ($mask.Count -ge 1) { $result['SubnetMask'] = [string] $mask[0] }

            $router = @($current.DefaultIPGateway)
            if ($router.Count -ge 1) { $result['Gateway'] = [string] $router[0] }

            $dns = @($current.DNSServerSearchOrder | Where-Object { $_ } | ForEach-Object { [string] $_ })
            $result['DnsServer'] = [string[]] $dns
            $result['DnsServerText'] = ($dns -join ', ')

            break
        }

        if ($result['HasLease']) { break }
    }

    return [pscustomobject] $result
}
