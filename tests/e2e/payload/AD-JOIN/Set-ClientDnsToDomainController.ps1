# POINT THIS MACHINE'S RESOLVER AT THE DOMAIN CONTROLLER, BEFORE ANYTHING TRIES
# TO FIND THE DOMAIN.
#
# A PowerShell step script - a USER extension point, not an HDT command, so it
# carries no HDT prefix. It defines no functions and prefixes its variables
# join*, for WDS-2025's reason: the engine invokes a step script in its own
# session, so a function declared here would shadow whatever else answered to
# that name for the rest of the deployment.
#
# ----------------------------------------------------------------------------
# THIS IS THE FAILURE THE WHOLE SEQUENCE IS ARRANGED AROUND
# ----------------------------------------------------------------------------
#
# A client on this lab's segment holds a DHCP lease from the home router, and
# the router hands out ITSELF as the DNS server. The router has never heard of
# the AD zone and never will - it is an RFC 2606 .test name that exists on
# exactly one machine.
#
# A domain join in that state fails with:
#
#   "An Active Directory Domain Controller (AD DC) for the domain <name> could
#    not be contacted."
#
# which is true and useless. It is the same message for a wrong domain name, a
# wrong credential, a firewall, a controller that is switched off, and this. A
# client does not look the domain up by name - it looks up
# _ldap._tcp.dc._msdcs.<domain> and follows the answer - so a resolver that
# cannot answer that query is a client that cannot see the domain at all, and
# nothing in the error says so.
#
# ----------------------------------------------------------------------------
# IT SETS NAME RESOLUTION AND NOT AN ADDRESS
# ----------------------------------------------------------------------------
#
# CLAUDE.md forbids assigning an address or inventing a subnet without asking,
# and that rule was written because a made-up 10.10.10.0/24 collided with a
# VMware adapter already holding 10.10.10.1. So this machine keeps the lease the
# router gave it, exactly as it is. Nothing here calls New-NetIPAddress, and
# tests/unit/LabDomainSequence.Tests.ps1 refuses it over every payload script.
#
# Set-DnsClientServerAddress writes the resolver as a STATIC per-adapter setting
# which takes precedence over the lease's and survives every renewal. Without
# that, a renewal mid-deployment would hand the machine back to the router and
# the join - or the policy application after it - would fail for a reason
# nothing in the log would explain.
#
# THE CONTROLLER'S ADDRESS AND NOT ITS NAME. HDTDomainDnsServer is an address on
# purpose: resolving the controller BY NAME would need a resolver that can
# already see the zone, which is precisely what this machine does not have. It
# is the same reason WSUS-UPDATE's HDTWSUSServer is an address and not a name,
# and it is checked below rather than assumed, because a name here fails in a
# circle that is genuinely hard to read.
#
# THE CONTROLLER ONLY - NO SECOND ENTRY. The obvious-looking "and the router as
# a backup" makes things worse, not better: a resolver that cannot answer for
# the AD zone does not fail over cleanly, it returns an authoritative "no such
# name" from a server authoritative for nothing, and the machine then fails
# intermittently rather than plainly. External names are the CONTROLLER's job -
# AD-DC-2025 sets its forwarder to the gateway for exactly this.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'IScriptInvoker captures InformationRecords into the step log; Write-Host is the documented idiom for a step script.')]
param([System.Collections.IDictionary] $Variable)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------ WHAT WAS ASKED --

$joinDnsServer = ''
if ($Variable.Contains('HDTDomainDnsServer')) { $joinDnsServer = ([string] $Variable['HDTDomainDnsServer']).Trim() }

$joinDomainName = ''
if ($Variable.Contains('HDTJoinDomain')) { $joinDomainName = ([string] $Variable['HDTJoinDomain']).Trim() }

if ([string]::IsNullOrWhiteSpace($joinDnsServer)) {
    throw ("nothing supplies HDTDomainDnsServer, so this machine has no way to find the domain. Set it in the fallback rule of rules.yaml to the ADDRESS the AD-DC-2025 run printed at the bottom of its last step - that address is a DHCP lease, so read it off the controller rather than remembering it from a previous build.")
}

if ([string]::IsNullOrWhiteSpace($joinDomainName)) {
    throw ("nothing supplies HDTJoinDomain, so there is no zone to check the resolver against. Set it in the fallback rule of rules.yaml to the forest AD-DC-2025 created.")
}

# AN ADDRESS, NOT A NAME, AND THE REFUSAL SAYS WHY. A name here would have to be
# resolved by the resolver this step is about to replace, which is the resolver
# that cannot see the domain - a circle whose symptom is a join failing for
# reasons that look like anything else.
$joinParsed = [System.Net.IPAddress]::Any
if (-not [System.Net.IPAddress]::TryParse($joinDnsServer, [ref] $joinParsed)) {
    throw ("HDTDomainDnsServer is '{0}', which is a name rather than an address. It has to be an address: a name would have to be resolved by the resolver this step exists to replace, and that resolver is the home router, which knows nothing about {1}." -f
        $joinDnsServer, $joinDomainName)
}

Write-Host ('pointing this machine at {0} for {1}' -f $joinDnsServer, $joinDomainName)

# --------------------------------------------------------------- THE ADAPTER --

$joinAddress = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })

foreach ($joinRow in $joinAddress) {
    Write-Host ('adapter {0} (index {1}): {2}/{3}, prefix origin {4}' -f
        $joinRow.InterfaceAlias, $joinRow.InterfaceIndex, $joinRow.IPAddress, $joinRow.PrefixLength, $joinRow.PrefixOrigin)
}

if (@($joinAddress).Count -eq 0) {
    throw ('this machine holds no routable IPv4 address, so it has no lease and cannot reach a controller whatever its resolver says. On the ''HDT External'' switch that is a DHCP failure; on ''HDT Lab'' it is expected, and that switch is the wrong one for this sequence - SPIKES S6 records that it has no DHCP and no route to the host.')
}

# -------------------------------------------------------------- THE RESOLVER --

foreach ($joinRow in $joinAddress) {

    $joinBefore = Get-DnsClientServerAddress -InterfaceIndex $joinRow.InterfaceIndex -AddressFamily IPv4
    Write-Host ('interface {0} resolver was: {1}' -f
        $joinRow.InterfaceAlias, ((@($joinBefore.ServerAddresses) -join ', ')))

    Set-DnsClientServerAddress -InterfaceIndex $joinRow.InterfaceIndex -ServerAddresses $joinDnsServer

    $joinAfter = Get-DnsClientServerAddress -InterfaceIndex $joinRow.InterfaceIndex -AddressFamily IPv4
    Write-Host ('interface {0} resolver is now: {1} (static, so a DHCP renewal cannot hand it back to the router)' -f
        $joinRow.InterfaceAlias, ((@($joinAfter.ServerAddresses) -join ', ')))

    # AND THE IPv6 RESOLVER, WHICH IS THE ONE THAT ACTUALLY ANSWERS.
    #
    # THIS COST A WHOLE HARDWARE RUN ON 2026-09-07 AND THE SYMPTOM NAMED
    # NOTHING USEFUL. Setting the line above is not enough on this segment: the
    # home router advertises itself as an IPv6 DNS server over Router
    # Advertisement, Windows PREFERS an IPv6 resolver over an IPv4 one, and the
    # router has never heard of this forest. So every lookup went to the router,
    # came back NXDOMAIN, and the join failed with
    #
    #   "The specified domain either does not exist or could not be contacted"
    #
    # - error 1355, pointing at the domain, the credential and the network with
    # equal weight and at the actual cause not at all. The proof was that the
    # same name FAILED through the configured resolver path and SUCCEEDED when
    # forced at the controller with -Server.
    #
    # THE LIST IS EMPTIED RATHER THAN POINTED AT THE CONTROLLER'S OWN IPv6.
    # That address exists, but it is a PRIVACY / TEMPORARY address
    # (SuffixOrigin Random) handed out by Router Advertisement: it rotates, so
    # pinning it here would work today and break by itself later, which is worse
    # than not using IPv6 for DNS at all. An empty static list means this
    # adapter asks the IPv4 resolver above - the controller - and nothing else.
    #
    # NOT ResetServerAddresses, WHICH WOULD RESTORE THE ROUTER. Reset returns the
    # adapter to what DHCP and RA supply, which is precisely the configuration
    # being corrected.
    #
    # AND THIS IS A RESOLVER CHANGE, NOT AN ADDRESSING ONE. No address is
    # assigned, no subnet is invented, and the machine keeps its DHCP lease -
    # the distinction CLAUDE.md's networking rule turns on.
    $joinV6Before = Get-DnsClientServerAddress -InterfaceIndex $joinRow.InterfaceIndex -AddressFamily IPv6
    Write-Host ('interface {0} IPv6 resolver was: {1}' -f
        $joinRow.InterfaceAlias, ((@($joinV6Before.ServerAddresses) -join ', ')))

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
    Set-NetIPInterface -InterfaceIndex $joinRow.InterfaceIndex -AddressFamily IPv6 `
        -RouterDiscovery Disabled -ErrorAction SilentlyContinue

    $joinRowV6After = Get-DnsClientServerAddress -InterfaceIndex $joinRow.InterfaceIndex -AddressFamily IPv6
    Write-Host ('interface {0} IPv6 resolver is now: {1} - router discovery disabled, so the router cannot outrank the resolver set above' -f
        $joinRow.InterfaceAlias, $(if (@($joinRowV6After.ServerAddresses).Count -eq 0) { '(none)' } else { (@($joinRowV6After.ServerAddresses) -join ', ') }))
}

# THE CACHE, CLEARED, AND IT IS NOT HOUSEKEEPING. This machine has already asked
# the router about things during boot, and a NEGATIVE answer is cached like any
# other. Without this, the join can look up the domain, get the router's cached
# "no such name" back without a packet leaving the machine, and fail against a
# controller that was answering perfectly the whole time.
Clear-DnsClientCache
Write-Host 'resolver cache cleared - a negative answer cached from the router would otherwise be served locally, without a packet leaving this machine'

# ------------------------------------------------------------- DOES IT WORK ---
#
# ASK THE QUESTION THE JOIN IS ABOUT TO ASK, HERE, WHERE THE ANSWER MEANS
# SOMETHING. A client finds a controller through these records and through
# nothing else, so if they do not resolve now the join will fail in a minute
# with a message about the domain rather than about DNS.

# POLLED, ON A ONE-SECOND INTERVAL, AGAINST A DEADLINE - not asked once. The
# resolver was changed moments ago and the stack settles at its own pace; a
# single query decides the whole join on whatever the first second happened to
# look like. One second of interval with two minutes of patience returns the
# instant DNS is usable and still waits far longer than the old single shot did.
#
# AND IT CHECKS THE CONFIGURED RESOLVER PATH, NOT ONLY THE SERVER.
#
# THIS IS THE CORRECTION THAT MATTERS AND IT COST A HARDWARE RUN. This block
# used to query with -Server $joinDnsServer, which bypasses the machine's own
# resolver configuration and asks the controller directly. So it PASSED - and
# the join immediately afterwards FAILED with "the specified domain either does
# not exist or could not be contacted", because the machine's real lookups were
# going somewhere else entirely (the router, over IPv6 - see the resolver block
# above). A check that cannot fail the way the next step fails is not a check.
#
# So both are asked, every round: -Server proves the controller answers, and the
# plain lookup proves THIS MACHINE will reach it - which is what the join does.
$joinDeadlineSecond = 120
$joinWatch = [System.Diagnostics.Stopwatch]::StartNew()
$joinAttempt = 0
$joinFailed = New-Object System.Collections.ArrayList

$joinRecordList = @(
    ('_ldap._tcp.dc._msdcs.{0}' -f $joinDomainName)
    ('_kerberos._tcp.{0}' -f $joinDomainName))

while ($true) {

    $joinAttempt++
    $joinFailed = New-Object System.Collections.ArrayList

    foreach ($joinRecord in $joinRecordList) {

        $joinAnswer = @(Resolve-DnsName -Name $joinRecord -Type SRV -Server $joinDnsServer -ErrorAction SilentlyContinue)
        if (@($joinAnswer).Count -eq 0) {
            [void] $joinFailed.Add(('{0} (asked of {1} directly)' -f $joinRecord, $joinDnsServer))
            continue
        }

        # THE SAME RECORD, THROUGH THIS MACHINE'S OWN RESOLVER. No -Server: this
        # is the path the join will take.
        $joinLocal = @(Resolve-DnsName -Name $joinRecord -Type SRV -ErrorAction SilentlyContinue)
        if (@($joinLocal).Count -eq 0) {
            [void] $joinFailed.Add(('{0} (through this machine''s own resolver)' -f $joinRecord))
        }
    }

    if ($joinFailed.Count -eq 0) {
        Write-Host ('attempt {0}: every record answered, both directly and through this machine''s own resolver, after {1:n1}s' -f
            $joinAttempt, $joinWatch.Elapsed.TotalSeconds)
        break
    }

    if ($joinWatch.Elapsed.TotalSeconds -ge $joinDeadlineSecond) { break }

    Write-Host ('attempt {0} at {1:n1}s: still waiting on {2}' -f
        $joinAttempt, $joinWatch.Elapsed.TotalSeconds, ($joinFailed -join '; '))

    Start-Sleep -Seconds 1
}

$joinWatch.Stop()

if ($joinFailed.Count -gt 0) {
    throw ("{0} did not answer for {1} within {2:n1}s over {3} attempt(s). A client finds a domain controller through these records and through nothing else, so the join that follows would fail with 'a domain controller for the domain could not be contacted' - which would send somebody to look at the credential. A record that answers when asked of {4} directly but NOT through this machine's own resolver means the resolver configuration above did not take, not that the controller is down. Check that {4} is really this forest's controller, that AD-DC-2025's verification step passed on it, and that it is switched on." -f
        $joinDnsServer, ($joinFailed -join ' and '), $joinWatch.Elapsed.TotalSeconds, $joinAttempt, $joinDnsServer)
}

foreach ($joinRecord in $joinRecordList) {
    foreach ($joinSrv in @(Resolve-DnsName -Name $joinRecord -Type SRV -Server $joinDnsServer -ErrorAction SilentlyContinue)) {
        Write-Host ('{0} -> {1}' -f $joinRecord, ($joinSrv | Out-String).Trim())
    }
}

Write-Host ('{0} answers for {1} and this machine reaches it through its own resolver: that is the one thing a join needs before the credential matters. It took {2:n1}s.' -f
    $joinDnsServer, $joinDomainName, $joinWatch.Elapsed.TotalSeconds)
