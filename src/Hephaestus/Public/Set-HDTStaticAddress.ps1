function Set-HDTStaticAddress {
    <#
        .SYNOPSIS
            Configures an adapter with a static IPv4 address, through WMI.

        .DESCRIPTION
            W2's static IP pane, behind the glass, and
            MDT's "Configure with Static IP Address" rebuilt.

            WMI, NOT NetTCPIP, AND THAT IS NOT A STYLE CHOICE. SPIKES S14:
            Get-NetIPAddress does not exist in a WinPE image built from the ADK -
            the NetTCPIP module is simply not there, and it is what killed the
            first SMB probe. Win32_NetworkAdapterConfiguration is present by
            construction, because WinPE-WMI is one of the six components
            Get-HDTBootImageComponent always injects. A pane that configured the
            network with cmdlets that do not exist would fail exactly where
            nobody could see it.

            THREE CALLS, AND THE ORDER IS LOAD-BEARING:

              EnableStatic(IPAddress, SubnetMask)
              SetGateways(DefaultIPGateway, GatewayCostMetric)
              SetDNSServerSearchOrder(DNSServerSearchOrder)

            A gateway set before the address exists is a gateway on a subnet the
            machine is not on yet, and WMI refuses it.

            IT REFUSES TO GUESS WHICH ADAPTER. One IP-enabled
            adapter is the WinPE case and needs no choosing; two is a coin toss
            with the machine's own network as the stake, so it stops and names
            them both. -InterfaceIndex is how a caller settles it.

            EVERYTHING IS CHECKED BEFORE ANYTHING IS CHANGED. A command that
            half-configures a network is worse than one that refuses: the
            machine is then on an address nobody chose, with a technician
            reading a log that says the DNS list was bad. So the address, the
            mask, the gateway and every DNS server are validated first, and only
            then does the first method run.

            A NON-CONTIGUOUS MASK IS REFUSED, and it is the interesting refusal:
            255.0.255.0 is four legal octets and is not a subnet mask. WMI
            accepts it and the machine ends up somewhere that cannot be reasoned
            about.

            IT DOES NOT REPORT SUCCESS FOR A ReturnValue THAT WAS NOT ONE. WMI
            answers 0 for done and 1 for done-but-reboot; everything else is a
            refusal - 70 is an invalid address, 91 is access denied - and
            reporting a network that was not configured sends a technician
            looking at the share instead of at the address they typed.

        .PARAMETER IPAddress
            The IPv4 address to set.

        .PARAMETER SubnetMask
            The subnet mask. Must be contiguous.

        .PARAMETER Gateway
            The default gateway. Omitted, no gateway is set - which is right for
            an isolated segment and is not the same as setting an empty one.

        .PARAMETER DnsServer
            DNS servers, in order. A single comma-separated string is split, so
            what the wizard's DNS box asks a technician to type is what this
            accepts.

        .PARAMETER InterfaceIndex
            Which adapter, when the machine has more than one.

        .PARAMETER CimProvider
            An ICimProvider. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Applied,
            RebootRequired, IPAddress, SubnetMask, Gateway, DnsServer,
            AdapterDescription and InterfaceIndex.

        .EXAMPLE
            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -Gateway '192.168.2.1'

            What the Welcome screen calls when a technician chooses "Use the
            following IP address".

        .EXAMPLE
            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -DnsServer '192.168.2.1, 1.1.1.1' -WhatIf

            What it would do, on a machine it must not touch yet.
    #>
    # SupportsShouldProcess, and NO ConfirmImpact - which is the engine's
    # convention and is deliberate here. ConfirmImpact = 'High' makes this
    # prompt by default, and THE UNATTENDED PATH IS THE DEFAULT
    # (.planning/WPF-FIRST.md): a static address applied from a rule on a
    # machine with nobody present must not stop for a confirmation nobody is
    # there to give. -Confirm is still available to anyone who wants it.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $IPAddress,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $SubnetMask,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Gateway = '',

        [Parameter()]
        [AllowNull()]
        [string[]] $DnsServer,

        [Parameter()]
        [AllowNull()]
        [System.Nullable[int]] $InterfaceIndex,

        [Parameter()]
        [AllowNull()]
        [object] $CimProvider
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $CimProvider) { $CimProvider = New-HDTCimProvider }

    # STRICTER THAN [System.Net.IPAddress]::TryParse ON PURPOSE. TryParse reads
    # '192.168.2' as 192.168.0.2 and accepts IPv6 outright, so a technician's
    # typo becomes a different machine's address rather than a refusal.
    $isIPv4 = {
        param([string] $Value)

        if ($Value -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }

        foreach ($octet in @($Value.Split('.'))) {
            if ([int] $octet -gt 255) { return $false }
        }

        return $true
    }

    # -- 1. everything is checked before anything is changed ----------------

    if (-not (& $isIPv4 $IPAddress)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ("'{0}' is not an IPv4 address. It must be four numbers 0-255 separated by dots, like 192.168.2.50." -f $IPAddress)))
    }

    if (-not (& $isIPv4 $SubnetMask)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ("'{0}' is not a subnet mask. It must be four numbers 0-255 separated by dots, like 255.255.255.0." -f $SubnetMask)))
    }

    # A MASK IS A RUN OF ONES FOLLOWED BY A RUN OF ZEROES. 255.0.255.0 passes
    # every octet check above and is not a mask; inverted, a contiguous mask is
    # all zeroes then all ones, and n AND (n+1) is 0 for exactly that shape.
    $maskValue = [uint64] 0
    foreach ($octet in @($SubnetMask.Split('.'))) { $maskValue = ($maskValue * 256) + [uint64] $octet }
    $inverted = [uint64] 4294967295 - $maskValue

    if ($maskValue -eq 0 -or ($inverted -band ($inverted + 1)) -ne 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ("'{0}' is not a usable subnet mask: a mask is a run of ones followed by a run of zeroes, like 255.255.255.0 or 255.255.240.0." -f $SubnetMask)))
    }

    $hasGateway = -not [string]::IsNullOrWhiteSpace($Gateway)
    if ($hasGateway -and -not (& $isIPv4 $Gateway)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ("the default gateway '{0}' is not an IPv4 address. A gateway is an address on this subnet, not a name." -f $Gateway)))
    }

    # THE HINT UNDER THE DNS BOX SAYS "separate several with a comma", so what
    # the box produces has to be what this accepts - otherwise the hint on
    # screen is an instruction to break it.
    $dns = @(@($DnsServer) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
            ForEach-Object { [string] $_ } |
            ForEach-Object { $_.Split(',') } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ })

    foreach ($server in $dns) {
        if (-not (& $isIPv4 $server)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                        -Message ("the DNS server '{0}' is not an IPv4 address. WinPE resolves the deployment share by address, so a name here cannot be looked up." -f $server)))
        }
    }

    # -- 2. which adapter, and the refusal to guess -------------------------

    $adapter = @($CimProvider.GetInstance('Win32_NetworkAdapterConfiguration') |
            Where-Object { $_.IPEnabled })

    if ($null -ne $InterfaceIndex) {
        $chosen = @($adapter | Where-Object { [int] $_.InterfaceIndex -eq [int] $InterfaceIndex })

        if ($chosen.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category ObjectNotFound `
                        -Message ("this machine has no IP-enabled adapter with interface index {0}. It has: {1}." -f
                            $InterfaceIndex, ((@($adapter | ForEach-Object { '{0} ({1})' -f $_.Description, $_.InterfaceIndex }) -join ', ')))))
        }

        $adapter = $chosen
    }

    if ($adapter.Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category ObjectNotFound `
                    -Message 'this machine has no IP-enabled network adapter to configure. In WinPE that usually means the NIC driver is not in the boot image.'))
    }

    if ($adapter.Count -gt 1) {
        # CLAUDE.md rule 6: refuse ambiguous targets. Picking the first would
        # reconfigure whichever adapter WMI happened to enumerate first.
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidArgument `
                    -Message ("this machine has {0} IP-enabled adapters and nothing said which one to configure: {1}. Name one with -InterfaceIndex." -f
                        $adapter.Count, ((@($adapter | ForEach-Object { '{0} (index {1})' -f $_.Description, $_.InterfaceIndex }) -join ', ')))))
    }

    $target = $adapter[0]

    $result = [ordered] @{
        Applied            = $false
        RebootRequired     = $false
        IPAddress          = $IPAddress
        SubnetMask         = $SubnetMask
        Gateway            = $Gateway
        DnsServer          = [string[]] $dns
        AdapterDescription = [string] $target.Description
        InterfaceIndex     = [int] $target.InterfaceIndex
    }

    if (-not $PSCmdlet.ShouldProcess(
            ('{0} (index {1})' -f $target.Description, $target.InterfaceIndex),
            ('set static address {0}/{1}' -f $IPAddress, $SubnetMask))) {

        return [pscustomobject] $result
    }

    # -- 3. the three calls, in the order WMI needs them --------------------

    $call = @(
        @{ Method = 'EnableStatic'; Argument = @{ IPAddress = [string[]] @($IPAddress); SubnetMask = [string[]] @($SubnetMask) } })

    if ($hasGateway) {
        # SetGateways takes two PARALLEL arrays; a gateway with no metric is how
        # this call fails on a machine that already has a route.
        $call += @{ Method = 'SetGateways'; Argument = @{ DefaultIPGateway = [string[]] @($Gateway); GatewayCostMetric = [uint16[]] @(1) } }
    }

    if ($dns.Count -ge 1) {
        $call += @{ Method = 'SetDNSServerSearchOrder'; Argument = @{ DNSServerSearchOrder = [string[]] $dns } }
    }

    foreach ($current in $call) {
        $returnValue = [int] $CimProvider.InvokeMethod($target, [string] $current.Method, [hashtable] $current.Argument)

        # 0 is done, 1 is done-but-reboot. Everything else is the machine saying
        # no, and it is named with the method that said it.
        if ($returnValue -eq 1) { $result['RebootRequired'] = $true }

        if ($returnValue -ne 0 -and $returnValue -ne 1) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Category InvalidOperation `
                        -Message ("{0} on '{1}' returned {2}, so the network was not configured. WMI's codes: 70 is an invalid address, 71 an invalid mask, 82 unable to configure the gateway, 91 access denied." -f
                            $current.Method, $target.Description, $returnValue)))
        }
    }

    $result['Applied'] = $true

    return [pscustomobject] $result
}
