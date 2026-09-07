# PROVE THE MACHINE IS REALLY A MEMBER - THE STEP THAT DECIDES WHETHER
# JoinDomain HAS HARDWARE EVIDENCE BEHIND IT OR STILL HAS NONE.
#
# A PowerShell step script - a USER extension point, not an HDT command, so it
# carries no HDT prefix. It defines no functions and prefixes its variables join*.
#
# WHY IT EXISTS. Invoke-HDTJoinDomainStep returning Completed proves that
# NetJoinDomain accepted the call. That is worth something and it is not the
# claim being made. The claim is that HDT can join a machine to a real
# directory and leave it working, and the things that go wrong between those two
# statements are all invisible to the step:
#
#   * THE COMPUTER OBJECT EXISTS BUT THE SECURE CHANNEL DOES NOT. A join onto a
#     pre-existing, stale computer account leaves a machine that is nominally a
#     member and cannot authenticate anything.
#   * THE MACHINE JOINED THE WRONG DOMAIN. With one controller on the segment
#     this is unlikely; the check costs one line and catches the case where
#     HDTJoinDomain and HDTDomainDnsServer disagree.
#   * DNS WENT BACK TO THE ROUTER. The resolver was pinned before the join, and
#     this leg is after a restart - so this is where a setting that did not
#     stick shows up, and it shows up as everything else failing.
#
# THIS LEG IS AFTER THE RESTART, WHICH IS THE ONLY PLACE THE QUESTION IS
# ANSWERABLE. A membership check in the leg that ran the join asks a machine
# that has not established its secure channel yet, and gets an answer that means
# nothing either way.
#
# IT USES NO RSAT. A client has no ActiveDirectory module and installing one to
# run a test would be testing a different machine. Everything here is either a
# .NET type present on every Windows install, a cmdlet in the box, or one of the
# two console tools - klist and nltest - that have shipped in System32 since
# Vista.
#
# IT REPORTS AND THEN DECIDES, rather than throwing at the first problem, so one
# run produces the whole picture instead of the first line of it -
# Test-WdsServerReady.ps1's shape, for its reason.
#
# ---------------------------------------------------------------------------
# IT WAITS BEFORE IT JUDGES, AND THE WAIT LIVES HERE RATHER THAN IN THE YAML.
# ---------------------------------------------------------------------------
#
# This leg runs seconds after a boot, and the secure channel is the one fact
# below that is genuinely still settling then: Netlogon starts, finds a
# controller and establishes the channel a little after the logon screen
# appears. So the secure channel is POLLED against a deadline, with every
# attempt and its elapsed time logged - AD-DC-2025's
# Test-DomainControllerReady.ps1 does the same thing for the same reason.
#
# The step used to carry retry: count 3 in sequence.yaml instead, and that was
# removed deliberately. A retry on an ACTION means "do it until it takes"; a
# retry on an ASSERTION means "it held at least once in three", which is not the
# claim this file makes, and it hides how long the machine took - a run that
# passed on attempt three reads in the log exactly like one that passed
# immediately. Waiting here instead puts the number of seconds in the log.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'IScriptInvoker captures InformationRecords into the step log; Write-Host is the documented idiom for a step script.')]
param([System.Collections.IDictionary] $Variable)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$joinDomainName = ''
if ($Variable.Contains('HDTJoinDomain')) { $joinDomainName = ([string] $Variable['HDTJoinDomain']).Trim() }

# The credential the join already used, read up here because section 4 needs the
# domain's NetBIOS name for a lookup that uses no credential at all.
$joinBindUser = ''
if ($Variable.Contains('HDTDomainAdmin')) { $joinBindUser = ([string] $Variable['HDTDomainAdmin']).Trim() }

$joinBindDomain = ''
if ($Variable.Contains('HDTDomainAdminDomain')) { $joinBindDomain = ([string] $Variable['HDTDomainAdminDomain']).Trim() }

$joinBindPassword = ''
if ($Variable.Contains('HDTDomainAdminPassword')) { $joinBindPassword = [string] $Variable['HDTDomainAdminPassword'] }

$joinBindAccount = $joinBindUser
if (-not [string]::IsNullOrWhiteSpace($joinBindDomain)) {
    $joinBindAccount = '{0}\{1}' -f $joinBindDomain, $joinBindUser
}

$joinProblem = New-Object System.Collections.ArrayList

# WHAT WAS ACTUALLY PROVEN, collected as each check passes, because the closing
# line is assembled from this rather than written in advance. A success message
# naming a check that did not run is the defect this file shipped with: it
# claimed "the directory holds this machine's computer object" on runs where the
# directory was never read.
$joinProven = New-Object System.Collections.ArrayList

Write-Host ('verifying that {0} is a member of {1}' -f $env:COMPUTERNAME, $joinDomainName)

# ------------------------------------------------------- 1. WHAT WINDOWS SAYS --
#
# DomainRole 1 is a member workstation and 3 a member server; 0 and 2 are the
# standalone forms. PartOfDomain is the same fact said twice, and both are
# logged because a machine that reports PartOfDomain true with a workgroup name
# in Domain is a real and thoroughly confusing state.

$joinComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
Write-Host ('name {0}, DomainRole {1}, Domain {2}, PartOfDomain {3}, Workgroup {4}' -f
    $joinComputerSystem.Name, $joinComputerSystem.DomainRole, $joinComputerSystem.Domain,
    $joinComputerSystem.PartOfDomain,
    $(if ($null -eq $joinComputerSystem.Workgroup) { '(none)' } else { $joinComputerSystem.Workgroup }))

if (-not $joinComputerSystem.PartOfDomain) {
    [void] $joinProblem.Add('Windows reports this machine as not part of a domain, so the join did not survive the restart')
} else {
    [void] $joinProven.Add('Windows reports it as a domain member')
}

if (-not [string]::IsNullOrWhiteSpace($joinDomainName) -and
    -not ([string] $joinComputerSystem.Domain).Equals($joinDomainName, [System.StringComparison]::OrdinalIgnoreCase)) {

    [void] $joinProblem.Add(('this machine reports its domain as {0} and the sequence asked for {1}' -f
            $joinComputerSystem.Domain, $joinDomainName))
}

# THE INSTALL TIME, WHICH IS ALSO THE EARLIEST MOMENT THIS DEPLOYMENT COULD HAVE
# TOUCHED THE DIRECTORY. Section 5 uses it to tell a computer object this run
# wrote from one that was already there - the stale-account case in the header.
$joinInstalledAt = [datetime] (Get-CimInstance -ClassName Win32_OperatingSystem).InstallDate
Write-Host ('this operating system was installed at {0} ({1} UTC), which is the floor for anything this deployment wrote into the directory' -f
    $joinInstalledAt, $joinInstalledAt.ToUniversalTime())

# --------------------------------------------------- 2. THE SECURE CHANNEL ----
#
# THE ONE THAT MATTERS. A computer object can exist and be joined to on paper
# while the machine holds no working password for it - which is what a join onto
# a stale account leaves behind, and what a technician sees weeks later as "the
# trust relationship between this workstation and the primary domain failed".
# Test-ComputerSecureChannel asks the controller to verify it, right now.
#
# POLLED, because this leg starts seconds after a boot and Netlogon has not
# necessarily found a controller yet. A one-second poll against a two-minute
# deadline returns the moment the channel is up and records how long that took.
#
# BUT ONLY WHERE WAITING COULD CHANGE THE ANSWER. A channel that has not come up
# YET is a machine that IS a member; a machine Windows reports as not part of a
# domain at all will still not be one in two minutes, and polling it just makes
# the run that already failed take two minutes longer to say so. Section 1 has
# already recorded that as the problem it is, so this takes one reading for the
# log and moves on.

$joinSecureChannel = $false
$joinChannelError = ''
$joinChannelAttempt = 0
$joinChannelWatch = [System.Diagnostics.Stopwatch]::StartNew()
$joinChannelDeadlineSecond = 120
$joinChannelPoll = [bool] $joinComputerSystem.PartOfDomain

if (-not $joinChannelPoll) {
    Write-Host 'the secure channel is read once and not polled: Windows already reports this machine as not part of a domain, which is not a state that settles'
}

while ($joinChannelAttempt -eq 0 -or
    ($joinChannelPoll -and $joinChannelWatch.Elapsed.TotalSeconds -lt $joinChannelDeadlineSecond)) {

    $joinChannelAttempt++

    try {
        $joinSecureChannel = Test-ComputerSecureChannel -ErrorAction Stop

        if ($joinSecureChannel) {
            Write-Host ('attempt {0}: the secure channel verified after {1:n1}s' -f
                $joinChannelAttempt, $joinChannelWatch.Elapsed.TotalSeconds)
            break
        }

        $joinChannelError = 'Test-ComputerSecureChannel returned False'
    } catch {
        $joinChannelError = [string] $_.Exception.Message
    }

    # EVERY ATTEMPT IS LOGGED WITH ITS ELAPSED TIME, which is the number an
    # administrator needs a week later to say whether two minutes is the right
    # ceiling for this lab.
    Write-Host ('attempt {0} at {1:n1}s: the secure channel does not verify yet - {2}' -f
        $joinChannelAttempt, $joinChannelWatch.Elapsed.TotalSeconds, $joinChannelError)

    if (-not $joinChannelPoll) { break }

    Start-Sleep -Seconds 1
}

$joinChannelWatch.Stop()

if (-not $joinSecureChannel) {
    [void] $joinProblem.Add(('the secure channel to the domain does not verify: {0} attempt(s) over {1:n1}s ({2}), last answer "{3}". The computer object may exist while this machine holds no working password for it, which is what a join onto a stale account leaves behind and what shows up later as a broken trust relationship' -f
            $joinChannelAttempt, $joinChannelWatch.Elapsed.TotalSeconds,
            $(if ($joinChannelPoll) { 'deadline {0}s' -f $joinChannelDeadlineSecond } else { 'not polled - Windows reports no domain membership at all' }),
            $joinChannelError))
} else {
    [void] $joinProven.Add(('the secure channel verifies, after {0:n1}s' -f $joinChannelWatch.Elapsed.TotalSeconds))
}

# ------------------------------------------------------ 3. THE RESOLVER -------
#
# STILL POINTED AT THE CONTROLLER? This leg is after a restart, which is where a
# DNS setting that did not stick reappears - and when it does, everything else
# on this machine fails for reasons that name anything but DNS.

foreach ($joinRow in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {

    $joinResolver = Get-DnsClientServerAddress -InterfaceIndex $joinRow.InterfaceIndex -AddressFamily IPv4
    Write-Host ('adapter {0}: address {1}, resolver {2}' -f
        $joinRow.InterfaceAlias, $joinRow.IPAddress, ((@($joinResolver.ServerAddresses) -join ', ')))
}

if (-not [string]::IsNullOrWhiteSpace($joinDomainName)) {

    $joinSrv = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.{0}' -f $joinDomainName) -Type SRV -ErrorAction SilentlyContinue)

    if (@($joinSrv).Count -eq 0) {
        [void] $joinProblem.Add(('_ldap._tcp.dc._msdcs.{0} no longer resolves from this machine. The resolver was pinned before the join; if it has gone back to the router, a DHCP renewal replaced a setting that was meant to be static' -f $joinDomainName))
    } else {
        foreach ($joinRow in $joinSrv) {
            Write-Host ('_ldap._tcp.dc._msdcs.{0} -> {1}' -f $joinDomainName, ($joinRow | Out-String).Trim())
        }
        [void] $joinProven.Add('the controller still resolves')
    }
}

# --------------------------- 4. WHO THIS MACHINE IS, WITH NO CREDENTIAL -------
#
# THE HONEST VERSION OF WHAT SECTION 5 USED TO PRETEND TO BE, and the part of
# this file that cannot be skipped, because none of it needs a domain password.
#
# THE OLD SECTION 5 CLAIMED AN "LDAP BIND AS THE MACHINE ACCOUNT" AND DID A
# SERVERLESS ONE, which runs as the CALLING USER. By DESIGN 4.5.3 the leg that
# runs this step is logged on as the LOCAL Administrator - autologon deliberately
# keeps DefaultDomainName local so that a domain credential is never written into
# Winlogon on a bench machine - so the bind ran as a local account, which cannot
# authenticate to a directory at all. It failed on a real run, 2026-09-07, FOUR
# TIMES OVER, thirty seconds apart, identically, and it was not a race: the same
# machine in the same session, at the same moment, answered
#
#   serverless, as HDT-M6-CL01\Administrator : FAILED
#   with HDTLAB\Administrator                : OK, CN=HDT-M6-CL01,CN=Computers,DC=hdtlab,DC=test
#
# The three checks below are what a local-Administrator session CAN honestly ask
# about this machine's own identity, and every one of them goes to a controller:
#
#   a. LSA NAME TRANSLATION of DOMAIN\COMPUTERNAME$ to a SID. The lookup travels
#      over this machine's own secure channel, so a SID coming back means a
#      controller resolved THIS MACHINE'S ACCOUNT - and that SID is the value
#      section 5 compares against, which is what turns a name match into an
#      identity match.
#   b. nltest /sc_verify, which forces a secure-channel verification and names
#      the controller that answered.
#   c. klist -li 0x3e7, the SYSTEM logon session's ticket cache. A Kerberos TGT
#      issued to COMPUTERNAME$ is the strongest single statement that this
#      machine holds that account's current password, because a ticket cannot be
#      obtained without it.

$joinMachineAccount = '{0}$' -f $env:COMPUTERNAME
$joinMachineSid = $null

# The LSA takes a NetBIOS or a DNS domain name and which one answers depends on
# the forest, so the candidates are tried in order and the one that worked is
# logged. Blanks and duplicates fall out on the way in.
$joinDomainCandidate = @($joinBindDomain, [string] $joinComputerSystem.Domain, $joinDomainName,
    @(([string] $joinComputerSystem.Domain) -split '\.')[0]) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

foreach ($joinCandidate in @($joinDomainCandidate)) {

    try {
        $joinAccount = New-Object System.Security.Principal.NTAccount($joinCandidate, $joinMachineAccount)
        $joinMachineSid = $joinAccount.Translate([System.Security.Principal.SecurityIdentifier])

        Write-Host ('the directory resolved {0}\{1} to {2}. That lookup travelled over this machine''s own secure channel, so a controller answered it for this machine rather than for its name' -f
            $joinCandidate, $joinMachineAccount, $joinMachineSid.Value)
        break
    } catch {
        Write-Host ('{0}\{1} did not translate: {2}' -f $joinCandidate, $joinMachineAccount, [string] $_.Exception.Message)
    }
}

if ($null -eq $joinMachineSid) {
    [void] $joinProblem.Add(('no controller would translate {0} to a SID under any domain name this run knows ({1}). A machine whose own account cannot be looked up is not usably a member however it describes itself' -f
            $joinMachineAccount, (@($joinDomainCandidate) -join ', ')))
} else {
    [void] $joinProven.Add(('a controller resolved this machine''s own account {0} to {1}' -f $joinMachineAccount, $joinMachineSid.Value))
}

# nltest AND klist ARE NATIVE, so the error preference is dropped around them: a
# console tool writing a line to stderr is output to be logged, not a step to
# fail. The exit code is what decides.
$joinNlTest = Get-Command -Name 'nltest.exe' -ErrorAction SilentlyContinue

if ($null -eq $joinNlTest) {

    # Not a membership finding, and not a silent narrowing either.
    # Test-ComputerSecureChannel above asks a controller the same question, so
    # the evidence is not lost - only the controller's NAME is, and the closing
    # line will not claim what nltest did not say.
    Write-Host 'nltest.exe is not on this machine, so the secure channel rests on Test-ComputerSecureChannel alone and no controller name is recorded here'

} elseif (-not [string]::IsNullOrWhiteSpace($joinDomainName)) {

    $joinNlTestOutput = @()
    $joinNlTestExit = 0

    try {
        $ErrorActionPreference = 'Continue'
        $joinNlTestOutput = @(& $joinNlTest.Source ('/sc_verify:{0}' -f $joinDomainName) 2>&1 | ForEach-Object { [string] $_ })
        $joinNlTestExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
    }

    foreach ($joinRow in @($joinNlTestOutput)) { Write-Host ('nltest: {0}' -f $joinRow) }

    if ($joinNlTestExit -ne 0) {
        [void] $joinProblem.Add(('nltest /sc_verify:{0} exited {1}. It asks a controller to verify the secure channel and names the controller that answered, so a non-zero exit is the channel failing under a second, independent tool' -f
                $joinDomainName, $joinNlTestExit))
    } else {
        [void] $joinProven.Add('nltest /sc_verify agrees, against a named controller')
    }
}

# 0x3e7 IS THE SYSTEM LOGON SESSION - where the machine account's tickets live,
# and not the interactive session this script runs in. Reading it needs
# elevation, which every HDT leg has.
$joinKlist = Get-Command -Name 'klist.exe' -ErrorAction SilentlyContinue

if ($null -eq $joinKlist) {

    [void] $joinProblem.Add('klist.exe is not on this machine. It has shipped in System32 since Vista, so its absence is a broken image rather than a broken join - but either way this machine''s Kerberos identity cannot be read, and that is a finding and not a reason to check less')

} else {

    $joinTicket = @()

    try {
        $ErrorActionPreference = 'Continue'
        $joinTicket = @(& $joinKlist.Source '-li' '0x3e7' 2>&1 | ForEach-Object { [string] $_ })

        # AN EMPTY CACHE IS NOT A FAILURE ON ITS OWN. A machine that has needed
        # no ticket since boot holds none, so one is REQUESTED before anything
        # is concluded - and that request is the real assertion, because a KDC
        # will not issue to an account whose current password this machine does
        # not hold.
        if ([string] (@($joinTicket) -join "`n") -notmatch '(?i)krbtgt/') {

            Write-Host 'the SYSTEM ticket cache holds no TGT yet, so one is being requested - a KDC that issues it has authenticated this machine as its own account'

            $joinRequest = @(& $joinKlist.Source '-li' '0x3e7' 'get' ('krbtgt/{0}' -f $joinDomainName) 2>&1 |
                    ForEach-Object { [string] $_ })

            foreach ($joinRow in @($joinRequest)) { Write-Host ('klist get: {0}' -f $joinRow) }

            $joinTicket = @(& $joinKlist.Source '-li' '0x3e7' 2>&1 | ForEach-Object { [string] $_ })
        }
    } finally {
        $ErrorActionPreference = 'Stop'
    }

    foreach ($joinRow in @($joinTicket)) { Write-Host ('klist: {0}' -f $joinRow) }

    $joinTicketText = [string] (@($joinTicket) -join "`n")

    if ($joinTicketText -match '(?i)LsaCallAuthenticationPackage.*:\s*5') {

        [void] $joinProblem.Add('klist -li 0x3e7 was refused with access denied, so this leg is not running elevated. Every HDT leg is meant to be - autologon logs on as the local Administrator - so this is a finding about the run, and it leaves this machine''s Kerberos identity unproven')

    } elseif ($joinTicketText -notmatch '(?i)krbtgt/') {

        [void] $joinProblem.Add(('the SYSTEM logon session holds no Kerberos TGT for {0} even after asking for one. A domain member gets a ticket as {1} because it holds that account''s current password; a machine that cannot is joined on paper only' -f
                $joinDomainName, $joinMachineAccount))

    } elseif ($joinTicketText -notmatch ('(?i)' + [regex]::Escape($joinMachineAccount))) {

        [void] $joinProblem.Add(('the SYSTEM logon session holds a TGT, but not one issued to {0} - so whatever identity this machine authenticates as, it is not its own computer account' -f
                $joinMachineAccount))

    } else {
        [void] $joinProven.Add(('the SYSTEM session holds a Kerberos TGT issued to {0}' -f $joinMachineAccount))
    }
}

# ----------------------------------------- 5. THE COMPUTER OBJECT ITSELF ------
#
# READ OUT OF THE DIRECTORY OVER LDAP WITH THE DOMAIN CREDENTIAL, AND COMPARED
# AGAINST THE SID A CONTROLLER GAVE SECTION 4.
#
# WHAT A cn= MATCH IS WORTH, WHICH IS LESS THAN IT LOOKS. The filter finds AN
# object with this machine's name, read by a domain admin. That passes on a
# machine whose own membership is dead, and it cannot catch the stale-computer-
# account case this file's header says it exists to catch - the leftover object
# from a previous build wearing the same name. So the object is accepted only
# when
#
#   * its objectSid EQUALS the SID a controller resolved this machine's own
#     account to in section 4 - the difference between "an object called
#     HDT-M6-CL01" and "the account this machine authenticates as"; and
#   * its pwdLastSet is at or after this operating system's install time - the
#     cheapest discriminator there is for a leftover, because a join sets that
#     password and this OS was installed minutes ago.
#
# THERE IS NO SKIP PATH, AND THAT IS THE CORRECTION. This block used to skip
# itself when HDTDomainAdminPassword arrived as '(set, not shown)' and let the
# step pass anyway, while the closing line went on claiming the directory had
# been read. A verification that quietly reduces its own scope and stays green
# is indistinguishable from one that passed, so a missing credential is now a
# finding in its own right.
#
# IT IS ALSO NOT A CONDITION THAT SHOULD ARISE ANY MORE. Restore-HDTRuleVariable
# re-resolves rules.yaml into a leg that rehydrated from a redacted checkpoint,
# so the password is refilled before any step runs - and the join, one leg
# earlier, needed the same value and got it. A redaction here therefore says the
# refill did not happen for THIS leg, which is a defect worth a red step rather
# than a reason to check less.

if ([string]::IsNullOrWhiteSpace($joinBindUser)) {

    [void] $joinProblem.Add('this leg''s variable bag carries no HDTDomainAdmin, so the directory cannot be read. The join one leg earlier required that name, which means it was there then and is missing now - a variable that did not survive the checkpoint, not a machine that failed to join')

} elseif ([string]::IsNullOrWhiteSpace($joinBindPassword) -or $joinBindPassword -eq '(set, not shown)') {

    [void] $joinProblem.Add(('HDTDomainAdminPassword arrived as the redaction Save-HDTRunState writes into state.json, so the directory cannot be read as {0}. Restore-HDTRuleVariable re-resolves rules.yaml into exactly this case, and the join one leg earlier got a live value, so the refill did not run or did not find the name for this leg (DESIGN 4.5.2)' -f
            $joinBindAccount))

} else {

    try {
        Write-Host ('searching the directory as {0} - NOT serverless, because this leg is logged on as the local Administrator by design (DESIGN 4.5.3)' -f $joinBindAccount)

        $joinRoot = New-Object System.DirectoryServices.DirectoryEntry(
            ('LDAP://{0}' -f $joinDomainName), $joinBindAccount, $joinBindPassword)

        $joinSearcher = New-Object System.DirectoryServices.DirectorySearcher($joinRoot)
        $joinSearcher.Filter = ('(&(objectCategory=computer)(cn={0}))' -f $env:COMPUTERNAME)

        foreach ($joinAttribute in 'distinguishedName', 'dNSHostName', 'operatingSystem',
            'whenCreated', 'objectSid', 'objectGUID', 'pwdLastSet') {

            [void] $joinSearcher.PropertiesToLoad.Add($joinAttribute)
        }

        $joinFound = $joinSearcher.FindOne()

        if ($null -eq $joinFound) {

            [void] $joinProblem.Add(('the directory holds no computer object named {0}, so whatever this machine joined, it is not represented there' -f $env:COMPUTERNAME))

        } else {

            Write-Host ('computer object: {0}' -f $joinFound.Properties['distinguishedname'][0])
            Write-Host ('the directory records its DNS host name as: {0}' -f
                $(if ($joinFound.Properties['dnshostname'].Count -gt 0) { $joinFound.Properties['dnshostname'][0] } else { '(not set)' }))
            Write-Host ('the directory records its operating system as: {0}' -f
                $(if ($joinFound.Properties['operatingsystem'].Count -gt 0) { $joinFound.Properties['operatingsystem'][0] } else { '(not set)' }))
            Write-Host ('created in the directory at: {0}' -f $joinFound.Properties['whencreated'][0])

            # IDENTITY. objectSid comes back as the raw byte array, which is what
            # SecurityIdentifier's (byte[], int) constructor takes.
            $joinObjectSid = $null
            if ($joinFound.Properties['objectsid'].Count -gt 0) {
                $joinObjectSid = New-Object System.Security.Principal.SecurityIdentifier(
                    ([byte[]] $joinFound.Properties['objectsid'][0]), 0)
            }

            # Logged rather than compared: the GUID is what an administrator
            # takes to the controller to look this object up by hand, and unlike
            # the SID there is no credential-free way to read this machine's own.
            if ($joinFound.Properties['objectguid'].Count -gt 0) {
                Write-Host ('objectGUID: {0}' -f (New-Object System.Guid(, [byte[]] $joinFound.Properties['objectguid'][0])))
            }

            if ($null -eq $joinObjectSid) {

                [void] $joinProblem.Add(('the computer object named {0} has no readable objectSid, so nothing can say whether it is this machine''s account or another object wearing its name' -f $env:COMPUTERNAME))

            } elseif ($null -eq $joinMachineSid) {

                Write-Host ('the directory object''s SID is {0}. Section 4 got no SID for this machine, so the two cannot be compared - and that failure is already recorded there rather than being restated here as a second one' -f $joinObjectSid.Value)

            } elseif (-not $joinObjectSid.Equals($joinMachineSid)) {

                [void] $joinProblem.Add(('the computer object named {0} has SID {1}, and a controller resolves this machine''s own account to {2}. They are different objects: the directory holds SOMETHING with this machine''s name, and it is not the account this machine authenticates as - which is exactly the stale-computer-account case this check exists for' -f
                        $env:COMPUTERNAME, $joinObjectSid.Value, $joinMachineSid.Value))

            } else {
                Write-Host ('objectSid {0} matches the SID a controller resolved this machine''s own account to, so this object IS this machine and not a namesake' -f $joinObjectSid.Value)
                [void] $joinProven.Add('the directory object with this name carries this machine''s own SID')
            }

            # FRESHNESS. DirectorySearcher hands Integer8 attributes back as Int64
            # file times.
            if ($joinFound.Properties['pwdlastset'].Count -eq 0) {

                [void] $joinProblem.Add(('the computer object named {0} has no pwdLastSet, so there is no way to tell an account this deployment joined from one that was already there' -f $env:COMPUTERNAME))

            } else {

                $joinPasswordSetAt = [datetime]::FromFileTimeUtc([int64] $joinFound.Properties['pwdlastset'][0])
                Write-Host ('pwdLastSet {0} UTC, against an install time of {1} UTC' -f
                    $joinPasswordSetAt, $joinInstalledAt.ToUniversalTime())

                # Five minutes of slack for clock skew between this machine and
                # the controller - well inside Kerberos's own tolerance, and
                # nowhere near the age of a leftover object from another build.
                if ($joinPasswordSetAt -lt $joinInstalledAt.ToUniversalTime().AddMinutes(-5)) {

                    [void] $joinProblem.Add(('the computer object named {0} last had its password set at {1} UTC, BEFORE this operating system was installed at {2} UTC. A join sets that password, so an older value means this object was not written by this deployment - a stale account from a previous build, which is the failure this check exists to catch' -f
                            $env:COMPUTERNAME, $joinPasswordSetAt, $joinInstalledAt.ToUniversalTime()))

                } else {
                    [void] $joinProven.Add(('its password was set at {0} UTC, after this operating system was installed' -f $joinPasswordSetAt))
                }
            }
        }

    } catch {
        [void] $joinProblem.Add(('the directory could not be searched from this machine as {0}: {1}. That is an authenticated LDAP bind against the domain this machine believes it joined, so it failing means the membership is not usable whatever Windows reports about it' -f
                $joinBindAccount, [string] $_.Exception.Message))
    }
}

# ------------------------------------------------------------------ VERDICT --

if ($joinProblem.Count -gt 0) {
    Write-Host ('{0} problem(s) found:' -f $joinProblem.Count)
    foreach ($joinLine in $joinProblem) { Write-Host ('  - {0}' -f $joinLine) }
    throw ("this machine is not usably a member of {0}: {1}. JoinDomain returning Completed proves NetJoinDomain accepted the call and nothing more, which is why these are checked separately." -f
        $joinDomainName, ($joinProblem -join '; '))
}

# THE CLOSING LINE IS ASSEMBLED FROM WHAT ACTUALLY RAN. It used to be a fixed
# sentence claiming four things, one of them a directory read the block above
# was allowed to skip - which is how a narrowed check reported a full one.
Write-Host ('{0} is a member of {1}. What that rests on, in the order it was proven:' -f
    $env:COMPUTERNAME, $joinDomainName)
foreach ($joinLine in $joinProven) { Write-Host ('  - {0}' -f $joinLine) }
Write-Host 'JoinDomain has hardware evidence behind it.'
