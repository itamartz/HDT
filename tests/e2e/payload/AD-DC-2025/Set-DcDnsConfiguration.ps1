# PIN THIS DOMAIN CONTROLLER'S RESOLVER TO ITSELF, AND POINT ITS FORWARDER AT
# WHATEVER THE LAN'S GATEWAY TURNS OUT TO BE.
#
# A PowerShell step script - a USER extension point, not an HDT command, so it
# carries no HDT prefix. It defines no functions and prefixes its variables dc*.
#
# ----------------------------------------------------------------------------
# THIS SETS NAME RESOLUTION. IT DOES NOT SET AN ADDRESS, AND THE DIFFERENCE IS
# THE WHOLE POINT.
# ----------------------------------------------------------------------------
#
# CLAUDE.md: "Never assign, create or use another subnet without asking the user
# first", and the host's own address on this segment "is local wiring, not a
# fact about HDT" - a lease, to be read and never written down. That rule exists
# because inventing 10.10.10.0/24 for an isolated switch collided with a VMware
# adapter already holding 10.10.10.1, and the conflict was caught only because
# the assignment happened to fail.
#
# So: this server's IPv4 ADDRESS stays exactly as the home router's DHCP handed
# it over. Nothing here calls New-NetIPAddress, and
# tests/unit/LabDomainSequence.Tests.ps1 refuses it over every payload script.
# What is changed is which server this machine ASKS for names, which alters no
# addressing and nothing outside this VM.
#
# ----------------------------------------------------------------------------
# WHY IT HAS TO BE DONE AT ALL - PROMOTION ALREADY DID IT, AND IT DOES NOT LAST
# ----------------------------------------------------------------------------
#
# Install-ADDSForest points the adapter's resolver at the new controller as part
# of promotion. On an adapter with a STATIC address that is the end of it. On an
# adapter with a DHCP LEASE - which is this one, deliberately - the DNS server
# list is part of what the lease supplies, and the next renewal replaces it with
# the home router's 192.168.1.1.
#
# The router has never heard of hdtlab.test. What that looks like afterwards, on
# the controller itself, is: Get-ADDomain hangs and then fails, the DFS
# Replication and Netlogon services log errors about locating a domain
# controller, Group Policy stops applying, and every one of those reads like a
# broken directory rather than like a name server. It is one of the classic
# silent failures of a lab domain built on DHCP.
#
# Set-DnsClientServerAddress writes the list as a STATIC per-adapter setting,
# which takes precedence over the lease's and survives every renewal. The
# address remains the lease's.
#
# 127.0.0.1 AND NOTHING ELSE, ON PURPOSE. The obvious-looking "and the router as
# a backup" is worse than no backup: a client whose second resolver cannot
# answer for the AD zone does not fail over cleanly, it gets an authoritative
# "no such name" from a server that is authoritative for nothing, and the
# resulting intermittent failures are far harder to read than a hard one.
# External names are the FORWARDER's job, below.
#
# ----------------------------------------------------------------------------
# THE FORWARDER IS READ, NOT ASSUMED
# ----------------------------------------------------------------------------
#
# The DC needs to resolve names outside hdtlab.test - Windows Update, activation,
# anything a server does. With the resolver pinned to itself, that traffic goes
# wherever the DNS SERVICE forwards it.
#
# The gateway this adapter was actually handed is what is used, read off the
# route table at run time. CLAUDE.md names the lab gateway, and it is still read
# rather than typed: it is a lease like every other number on this segment, and
# a script that hard-codes it works until the day somebody changes a router.
# Root hints are the fallback if there is no gateway to read, which is what a
# server does with no forwarder configured at all.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'IScriptInvoker captures InformationRecords into the step log; Write-Host is the documented idiom for a step script.')]
param([System.Collections.IDictionary] $Variable)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dcDomainName = 'hdtlab.test'
if ($Variable.Contains('HDTDomainDnsName') -and
    -not [string]::IsNullOrWhiteSpace([string] $Variable['HDTDomainDnsName'])) {
    $dcDomainName = ([string] $Variable['HDTDomainDnsName']).Trim()
}

# --------------------------------------------------------- THE ADAPTER --------
#
# The one holding a routable IPv4 address. Loopback and APIPA are excluded
# because neither is the LAN, and a machine with an APIPA address has no lease
# at all - which on 'HDT Lab' is the expected outcome (SPIKES S6) and on
# 'HDT External' is a fault worth naming here rather than three steps later.

$dcAddress = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })

foreach ($dcRow in $dcAddress) {
    Write-Host ('adapter {0} (index {1}): {2}/{3}, prefix origin {4}' -f
        $dcRow.InterfaceAlias, $dcRow.InterfaceIndex, $dcRow.IPAddress, $dcRow.PrefixLength, $dcRow.PrefixOrigin)
}

if (@($dcAddress).Count -eq 0) {
    throw ('this server holds no routable IPv4 address, so it has no lease. On the ''HDT External'' switch that is a DHCP failure; on ''HDT Lab'' it is expected and that switch is the wrong one for this sequence - SPIKES S6 records that it has no DHCP and no route to the share.')
}

# -------------------------------------------------- THE GATEWAY, FOR LATER ----
#
# READ BEFORE THE RESOLVER IS CHANGED, because after the change this machine
# resolves through itself and a mistake here would be harder to diagnose. The
# lowest-metric default route is the one traffic actually takes.

$dcGateway = ''
$dcRoute = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric)

foreach ($dcHop in $dcRoute) {
    Write-Host ('default route via {0} on interface {1}, metric {2}' -f
        $dcHop.NextHop, $dcHop.InterfaceIndex, $dcHop.RouteMetric)
}

if (@($dcRoute).Count -gt 0) { $dcGateway = [string] @($dcRoute)[0].NextHop }

# ------------------------------------------------------- THE RESOLVER ---------

foreach ($dcRow in $dcAddress) {

    $dcBefore = Get-DnsClientServerAddress -InterfaceIndex $dcRow.InterfaceIndex -AddressFamily IPv4
    Write-Host ('interface {0} resolver was: {1}' -f
        $dcRow.InterfaceAlias, ((@($dcBefore.ServerAddresses) -join ', ')))

    Set-DnsClientServerAddress -InterfaceIndex $dcRow.InterfaceIndex -ServerAddresses '127.0.0.1'

    $dcAfter = Get-DnsClientServerAddress -InterfaceIndex $dcRow.InterfaceIndex -AddressFamily IPv4
    Write-Host ('interface {0} resolver is now: {1} (static, so a DHCP renewal cannot replace it with the router)' -f
        $dcRow.InterfaceAlias, ((@($dcAfter.ServerAddresses) -join ', ')))

    # AND THE IPv6 LIST, FOR THE REASON THE LINE ABOVE EXISTS.
    #
    # The same correction AD-JOIN's Set-ClientDnsToDomainController.ps1 makes,
    # and it is made here for the same reason rather than because this server
    # has been seen to need it. The home router advertises itself as an IPv6
    # DNS server over Router Advertisement, and Windows PREFERS an IPv6 resolver
    # over an IPv4 one - so pinning only the IPv4 entry above leaves the router
    # answering, and the router knows nothing about this forest.
    #
    # THIS CONTROLLER DOES NOT NOTICE, WHICH IS EXACTLY WHY IT IS FIXED HERE.
    # Its own DNS service answers its own zone locally, so the misconfiguration
    # is invisible on the server and shows up on a CLIENT minutes later as
    # "the domain could not be contacted" - which is how it was found on
    # 2026-09-07, on the client rather than here. A latent fault that only ever
    # hurts somebody else is still a fault.
    #
    # EMPTIED, NOT POINTED AT ::1. The loopback would work, but this server's
    # own IPv6 address is a rotating privacy address and the zone is served on
    # IPv4 throughout this lab; leaving IPv6 out of DNS entirely is the
    # configuration that cannot drift.
    $dcV6Before = Get-DnsClientServerAddress -InterfaceIndex $dcRow.InterfaceIndex -AddressFamily IPv6
    Write-Host ('interface {0} IPv6 resolver was: {1}' -f
        $dcRow.InterfaceAlias, ((@($dcV6Before.ServerAddresses) -join ', ')))

    # ROUTER DISCOVERY OFF, WHICH IS WHAT ACTUALLY REMOVES THEM.
    #
    # These entries are not a DHCP setting and not a static list - they arrive
    # in the ROUTER ADVERTISEMENT itself, as RDNSS. That is why the two obvious
    # repairs both do nothing, and both were tried on a real machine first:
    #
    #   Set-DnsClientServerAddress -AddressFamily IPv6   - the parameter does
    #       not exist; only the Get- side has one. It throws.
    #   netsh interface ipv6 set/delete dnsservers        - returns success and
    #       changes nothing, because the list it edits is not the list the
    #       router supplied.
    #
    # Turning router discovery off on this interface stops the advertisement
    # being accepted, and the resolver list collapses back to the IPv4 entry
    # set above. Measured on 2026-09-07: with RDNSS present the controller's own
    # name did NOT resolve; with router discovery disabled it did, and
    # nltest /dsgetdc returned the controller over IPv4.
    #
    # THIS IS STILL NOT ADDRESSING. No address is assigned and no subnet is
    # invented - the machine keeps its DHCP lease on IPv4 and whatever IPv6
    # address it already holds. What stops is this interface taking its DNS
    # SERVER from the router, which is the whole purpose of this step.
    Set-NetIPInterface -InterfaceIndex $dcRow.InterfaceIndex -AddressFamily IPv6 `
        -RouterDiscovery Disabled -ErrorAction SilentlyContinue

    $dcRowV6After = Get-DnsClientServerAddress -InterfaceIndex $dcRow.InterfaceIndex -AddressFamily IPv6
    Write-Host ('interface {0} IPv6 resolver is now: {1} - router discovery disabled, so the router cannot outrank the resolver set above' -f
        $dcRow.InterfaceAlias, $(if (@($dcRowV6After.ServerAddresses).Count -eq 0) { '(none)' } else { (@($dcRowV6After.ServerAddresses) -join ', ') }))
}

# ------------------------------------------------------- THE FORWARDER --------

if (Get-Command -Name 'Set-DnsServerForwarder' -ErrorAction SilentlyContinue) {

    if ([string]::IsNullOrWhiteSpace($dcGateway)) {

        Write-Host 'no default gateway was found, so no forwarder is configured. The DNS service falls back to root hints, which is what a server with no forwarder does; external names may be slower and will still resolve if this segment can reach the internet.'

    } else {

        # UseRootHint STAYS TRUE. If the gateway stops answering - a router
        # reboot, a firmware update - a forest with no fallback stops resolving
        # anything external, and that failure looks like a broken DC.
        Set-DnsServerForwarder -IPAddress $dcGateway -UseRootHint $true

        Write-Host ('DNS forwarder set to {0}, the default gateway this adapter was handed. Read from the route table rather than typed: every address on this segment is a lease.' -f $dcGateway)
    }

    foreach ($dcForwarder in @(Get-DnsServerForwarder -ErrorAction SilentlyContinue)) {
        Write-Host ('forwarder in effect: {0} (root hints {1}, timeout {2}s)' -f
            (@($dcForwarder.IPAddress) -join ', '), $dcForwarder.UseRootHint, $dcForwarder.Timeout)
    }

} else {
    Write-Host 'the DnsServer module is not present, so no forwarder was configured. That is unexpected on a controller promoted with -InstallDns and is worth looking at; it does not stop the AD zone itself from answering.'
}

# ------------------------------------------------ REGISTER AND SHOW THE ZONE --
#
# Register-DnsClient makes the server put its own A record into the zone it now
# hosts. Promotion normally does this; doing it again after the resolver moved
# is cheap and closes the case where the record was written against the router.

Register-DnsClient
Write-Host ('registered this server''s own record in {0}' -f $dcDomainName)

foreach ($dcZone in @(Get-DnsServerZone -ErrorAction SilentlyContinue)) {
    Write-Host ('zone {0}: type {1}, AD-integrated {2}, dynamic update {3}' -f
        $dcZone.ZoneName, $dcZone.ZoneType, $dcZone.IsDsIntegrated, $dcZone.DynamicUpdate)
}

Write-Host ('this controller now resolves through itself for {0} and forwards everything else. A client that wants to join this domain must have ITS resolver pointed here first - the router hands out its own address as the DNS server and knows nothing about this zone.' -f $dcDomainName)
