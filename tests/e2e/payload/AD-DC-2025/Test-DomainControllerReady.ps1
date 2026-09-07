# PROVE THE FOREST IS ACTUALLY SERVING - THE STEP THAT REFUSES TO CALL A BUILD
# FINISHED BECAUSE THE PREVIOUS STEPS RETURNED ZERO.
#
# A PowerShell step script - a USER extension point, not an HDT command, so it
# carries no HDT prefix. It defines no functions and prefixes its variables dc*.
#
# WHY A VERIFICATION STEP AT ALL. Every way a first domain controller fails is
# SILENT on the controller and only visible on a CLIENT, minutes later, as "an
# Active Directory Domain Controller for the domain could not be contacted" -
# a message that names DNS, the domain name, the credential and the network with
# equal probability and none of them specifically. Install-ADDSForest returning
# a Success status proves the promotion transaction committed; it proves nothing
# about the machine that came back from the reboot.
#
# So this asks the questions AD-JOIN's client is about to ask, on the server,
# while somebody is still reading the log:
#
#   1. does Windows think this is a domain controller at all?
#   2. are NTDS, DNS, Netlogon, KDC and DFSR running?
#   3. does the DIRECTORY answer - Get-ADDomain, Get-ADForest?
#   4. do the SRV records a joining client looks up actually resolve? This is
#      THE question. A client does not look up the domain by name; it looks up
#      _ldap._tcp.dc._msdcs.<domain> and follows the answer. A forest whose
#      records did not register is a forest no client can find, and the server
#      itself works perfectly.
#   5. are SYSVOL and NETLOGON shared? Group Policy and the logon scripts live
#      there, and a controller whose SYSVOL never replicated in shares neither -
#      which a join survives and a logon does not.
#
# 4 IS THE ONE WORTH HAVING, and it is checked against the SERVER'S OWN resolver
# on purpose, because that is the same data a client gets once its resolver is
# pointed here.
#
# IT WAITS BEFORE IT JUDGES. The directory is not up the instant the logon
# screen appears: NTDS finishes its initial replication and SYSVOL is shared a
# little after boot, and a check that ran immediately would fail a perfectly
# good controller. The wait is bounded and every attempt is logged, so a run
# that took four minutes says so rather than looking instant.
#
# IT REPORTS AND THEN DECIDES, rather than throwing at the first problem, so one
# run produces the whole picture instead of the first line of it - Test-Wds
# ServerReady.ps1's shape, for Test-WdsServerReady.ps1's reason.

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

$dcProblem = New-Object System.Collections.ArrayList

Write-Host ('verifying the forest {0} on {1}' -f $dcDomainName, $env:COMPUTERNAME)

# ------------------------------------------------------------ 1. THE ROLE -----
#
# DomainRole 4 is a backup domain controller and 5 a primary; both mean "this
# is a DC". Anything below means the promotion did not survive the reboot,
# which is a different failure from the directory being slow and is worth
# separating from it before anything waits five minutes.

$dcComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
Write-Host ('DomainRole {0}, domain {1}, part of domain: {2}' -f
    $dcComputerSystem.DomainRole, $dcComputerSystem.Domain, $dcComputerSystem.PartOfDomain)

if ($dcComputerSystem.DomainRole -lt 4) {
    [void] $dcProblem.Add(('DomainRole is {0} - this machine is not a domain controller, so the promotion did not survive the restart' -f
            $dcComputerSystem.DomainRole))
}

# -------------------------------------------------------- 2. THE SERVICES -----
#
# NTDS is the directory, DNS answers for the zone, Netlogon registers the SRV
# records and services the secure channel, KDC issues the tickets a join needs,
# and DFSR replicates SYSVOL. A stopped one of these is the whole failure in
# every case, and none of them says so anywhere a client can see.

foreach ($dcServiceName in 'NTDS', 'DNS', 'Netlogon', 'kdc', 'DFSR') {

    $dcService = Get-Service -Name $dcServiceName -ErrorAction SilentlyContinue

    if ($null -eq $dcService) {
        [void] $dcProblem.Add(('the {0} service does not exist on this server' -f $dcServiceName))
        continue
    }

    Write-Host ('{0}: {1} ({2})' -f $dcService.Name, $dcService.Status, $dcService.StartType)

    if ($dcService.Status -ne 'Running') {
        [void] $dcProblem.Add(('{0} is {1}, not Running' -f $dcService.Name, $dcService.Status))
    }
}

# ------------------------------------------------------- 3. THE DIRECTORY -----
#
# THE BOUNDED WAIT, POLLED ON A SHORT INTERVAL AGAINST A DEADLINE.
#
# THE INTERVAL IS THE THING THAT WAS WRONG, NOT THE PATIENCE. This used to
# sleep 15 seconds between attempts, which is both too slow and too fast at
# once: a directory that answers in two seconds still cost fifteen, and a
# directory that needed longer got only twenty tries. A one-second poll against
# a five-minute deadline is the same patience and returns the moment the
# directory is actually up.
#
# AND IT IS TIMED, because the elapsed number is the one worth having. An
# administrator reading this a week later can see how long this controller
# really took to answer, which is the only evidence that says whether five
# minutes is the right ceiling.

if (-not (Get-Module -ListAvailable -Name 'ActiveDirectory')) {

    [void] $dcProblem.Add('the ActiveDirectory module is not on this server, so nothing here can query the directory. It comes with the AD DS role''s management tools - includeManagementTools on the InstallRoles step')

} else {

    Import-Module -Name 'ActiveDirectory' -ErrorAction Stop

    $dcDomain = $null
    $dcLastError = ''
    $dcAttempt = 0
    $dcWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $dcDeadlineSecond = 300

    while ($dcWatch.Elapsed.TotalSeconds -lt $dcDeadlineSecond) {

        $dcAttempt++

        try {
            $dcDomain = Get-ADDomain -Identity $dcDomainName -ErrorAction Stop
            Write-Host ('attempt {0}: the directory answered after {1:n1}s' -f
                $dcAttempt, $dcWatch.Elapsed.TotalSeconds)
            break
        } catch {
            $dcLastError = [string] $_.Exception.Message

            # EVERY ATTEMPT IS LOGGED WITH ITS ELAPSED TIME. At one second per
            # try this is a verbose block, and that is the trade CLAUDE.md's
            # logging rule asks for: a hundred lines that show exactly when the
            # directory came up beat two that say it eventually did.
            Write-Host ('attempt {0} at {1:n1}s: the directory is not answering yet - {2}' -f
                $dcAttempt, $dcWatch.Elapsed.TotalSeconds, $dcLastError)

            Start-Sleep -Seconds 1
        }
    }

    $dcWatch.Stop()

    if ($null -eq $dcDomain) {

        [void] $dcProblem.Add(('Get-ADDomain never answered for {0}: {1} attempt(s) over {2:n1}s (deadline {3}s). Last error: {4}' -f
                $dcDomainName, $dcAttempt, $dcWatch.Elapsed.TotalSeconds, $dcDeadlineSecond, $dcLastError))

    } else {

        Write-Host ('domain {0} (NetBIOS {1}), DN {2}' -f
            $dcDomain.DNSRoot, $dcDomain.NetBIOSName, $dcDomain.DistinguishedName)
        Write-Host ('domain mode {0}, PDC emulator {1}, infrastructure master {2}' -f
            $dcDomain.DomainMode, $dcDomain.PDCEmulator, $dcDomain.InfrastructureMaster)
        Write-Host ('replica directory servers: {0}' -f ((@($dcDomain.ReplicaDirectoryServers) -join ', ')))

        if (-not ([string] $dcDomain.DNSRoot).Equals($dcDomainName, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void] $dcProblem.Add(('the directory reports its root as {0}, and this sequence asked for {1}' -f
                    $dcDomain.DNSRoot, $dcDomainName))
        }

        $dcForest = Get-ADForest -ErrorAction SilentlyContinue
        if ($null -ne $dcForest) {
            Write-Host ('forest {0}, mode {1}, schema master {2}, global catalogs {3}' -f
                $dcForest.RootDomain, $dcForest.ForestMode, $dcForest.SchemaMaster,
                ((@($dcForest.GlobalCatalogs) -join ', ')))
        } else {
            [void] $dcProblem.Add('Get-ADForest returned nothing, so the forest object is not readable from its own root domain controller')
        }
    }
}

# ----------------------------------------------------- 4. THE SRV RECORDS -----
#
# WHAT A JOINING CLIENT ACTUALLY LOOKS UP, in the order it looks it up. The
# _msdcs one is the important half: it is how a client finds a DOMAIN
# CONTROLLER rather than a host that happens to answer for the domain name, and
# it lives in a separate delegated zone that can fail to register on its own.

foreach ($dcRecord in ('_ldap._tcp.{0}' -f $dcDomainName),
    ('_ldap._tcp.dc._msdcs.{0}' -f $dcDomainName),
    ('_kerberos._tcp.{0}' -f $dcDomainName)) {

    $dcAnswer = @(Resolve-DnsName -Name $dcRecord -Type SRV -ErrorAction SilentlyContinue)

    if (@($dcAnswer).Count -eq 0) {
        [void] $dcProblem.Add(('{0} resolves to nothing. A client does not look up the domain by name - it looks up these records and follows the answer, so a forest whose records did not register is a forest nothing can join' -f $dcRecord))
        continue
    }

    foreach ($dcSrv in $dcAnswer) {
        Write-Host ('{0} -> {1}' -f $dcRecord, ($dcSrv | Out-String).Trim())
    }
}

# ---------------------------------------------------------- 5. THE SHARES -----

foreach ($dcShareName in 'SYSVOL', 'NETLOGON') {

    $dcShare = Get-SmbShare -Name $dcShareName -ErrorAction SilentlyContinue

    if ($null -eq $dcShare) {
        [void] $dcProblem.Add(('{0} is not shared. Group Policy and the logon scripts live there, and a controller that never finished sharing it will accept a join and then fail every policy application on the machine that joined' -f $dcShareName))
        continue
    }

    Write-Host ('share {0}: {1}' -f $dcShare.Name, $dcShare.Path)
}

# ------------------------------------------- THE ADDRESS THE CLIENT NEEDS -----
#
# Logged rather than asserted - this server's address came from the LAN's own
# DHCP and is a lease, not a fact about HDT - but it is the number AD-JOIN's
# HDTDomainDnsServer has to be set to before a client can find this domain at
# all. It is printed last so it is the thing at the bottom of the log.

$dcOwnAddress = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })

foreach ($dcIp in $dcOwnAddress) {
    Write-Host ('This controller answers DNS and LDAP on {0}/{1} ({2}). Set HDTDomainDnsServer to this address in rules.yaml before running AD-JOIN.' -f
        $dcIp.IPAddress, $dcIp.PrefixLength, $dcIp.InterfaceAlias)
}

# ------------------------------------------------------------------ VERDICT --

if ($dcProblem.Count -gt 0) {
    Write-Host ('{0} problem(s) found:' -f $dcProblem.Count)
    foreach ($dcLine in $dcProblem) { Write-Host ('  - {0}' -f $dcLine) }
    throw ("this domain controller is not ready to be joined: {0}. Every one of these is silent on the server and shows up on the client as 'a domain controller for the domain could not be contacted', which is why they are checked here." -f
        ($dcProblem -join '; '))
}

Write-Host ('{0} is up: the services are running, the directory answers, the SRV records a client follows resolve, and SYSVOL and NETLOGON are shared.' -f $dcDomainName)
