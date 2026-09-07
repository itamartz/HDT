# PROMOTE THIS SERVER TO THE FIRST DOMAIN CONTROLLER OF A NEW FOREST.
#
# A PowerShell step script - a USER extension point, not an HDT command, so it
# carries no HDT prefix. It defines no functions and prefixes its variables dc*,
# for WDS-2025's reason: the engine invokes a step script in its own session, so
# a function declared here would shadow whatever else answered to that name for
# the rest of the deployment.
#
# -NoRebootOnCompletion, AND IT IS THE WHOLE REASON THIS IS AN HDT STEP.
# Install-ADDSForest restarts the machine by itself the moment it finishes.
# Left to do that, it would take the machine away from underneath the engine
# between one step and the next: no checkpoint written, no autologon armed for
# the leg that follows, no RunOnce to bring the sequence back. The deployment
# would come up as a domain controller with the task sequence abandoned at
# whatever step.json last recorded, which looks exactly like a crash.
#
# So promotion is told not to reboot, and the sequence's own Restart step does
# it - checkpointed, with autologon armed and AutoLogonCount set, which is the
# path DESIGN 4.5 built and the only one that comes back.
#
# -Force IS NOT A SHORTCUT AROUND A WARNING, IT IS WHAT MAKES IT UNATTENDED.
# Install-ADDSForest prompts to confirm and stops on several warnings that are
# EXPECTED here and none of which is a reason to abandon a lab build:
#
#   * "the physical network adapter does not have a static IP address" - true,
#     deliberately, and the sequence header says why: this server holds a DHCP
#     lease from the home router and CLAUDE.md forbids assigning an address on
#     somebody else's network without asking. The resolver is pinned instead,
#     by Set-DcDnsConfiguration.ps1, which is the part that actually matters;
#   * "a delegation for this DNS server cannot be created" - correct and
#     unavoidable: '.test' is an RFC 2606 reserved TLD with no parent zone
#     anywhere in the world to delegate from. That is the property that makes
#     it safe to use here;
#   * the cryptography-algorithm and default-security-settings notices, which
#     every new forest emits.
#
# Every one of them is logged below before promotion is attempted, so the log
# says what was accepted rather than hiding it behind a switch.
#
# THE DSRM PASSWORD IS THE ONE THING THAT CAN BLOCK THIS STEP TODAY, and the
# refusal below is deliberate rather than defensive - see the sequence header.
# DESIGN 4.5.2: a leg that resumes after a reboot rehydrates its variable bag
# from state.json, where every secret was written as "(set, not shown)". This
# step runs in the full OS, which is by definition such a leg. Promoting with
# that literal as the Directory Services Restore Mode password would SUCCEED -
# it is a perfectly good password - and leave a controller whose recovery
# credential is a sentence out of a log file, discovered by whoever needs DSRM,
# which is by definition the worst afternoon of their year.
#
# Invoke-HDTJoinDomainStep makes the same refusal for the same reason and says
# so at length. The durable answer for both is the LSA-carried secret bag
# DESIGN 4.5.2 names.
#
# IT IS RE-ENTRANT. A step can be re-run after a resume, and asking an existing
# domain controller to create a forest fails with a message about the machine
# already being a domain controller. The DomainRole check below turns that into
# a no-op with a line in the log saying which domain it is already the
# controller of.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'IScriptInvoker captures InformationRecords into the step log; Write-Host is the documented idiom for a step script.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Install-ADDSForest takes -SafeModeAdministratorPassword as a SecureString and the value arrives as a string in the engine variable bag. The conversion is the only way to hand it over; the value is never written to disk, and Test-HDTSecretVariable redacts the name everywhere it is logged or checkpointed.')]
param([System.Collections.IDictionary] $Variable)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------ WHAT WAS ASKED --
#
# READ WITH DEFAULTS AND THEN LOGGED, name and value together, because a
# promotion that built the wrong forest is not undoable and the log is the only
# record of what it was told.

$dcDomainName = 'hdtlab.test'
if ($Variable.Contains('HDTDomainDnsName') -and
    -not [string]::IsNullOrWhiteSpace([string] $Variable['HDTDomainDnsName'])) {
    $dcDomainName = ([string] $Variable['HDTDomainDnsName']).Trim()
}

$dcNetbiosName = 'HDTLAB'
if ($Variable.Contains('HDTDomainNetbiosName') -and
    -not [string]::IsNullOrWhiteSpace([string] $Variable['HDTDomainNetbiosName'])) {
    $dcNetbiosName = ([string] $Variable['HDTDomainNetbiosName']).Trim().ToUpperInvariant()
}

$dcForestMode = 'Default'
if ($Variable.Contains('HDTDomainForestMode') -and
    -not [string]::IsNullOrWhiteSpace([string] $Variable['HDTDomainForestMode'])) {
    $dcForestMode = ([string] $Variable['HDTDomainForestMode']).Trim()
}

Write-Host ('forest to create: {0} (NetBIOS {1}), functional level {2}' -f
    $dcDomainName, $dcNetbiosName, $dcForestMode)

# THE NAME IS CHECKED BEFORE THE PASSWORD, because a typo'd domain name is the
# cheap failure and it should not be found after the expensive one.
if ($dcDomainName -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') {
    throw ("'{0}' is not a usable forest root name. It needs at least two labels - a single-label domain is refused by every modern Windows client - and each label may hold only letters, digits and hyphens." -f $dcDomainName)
}

if ($dcDomainName -match '(?i)\.local$') {
    throw ("'{0}' ends in .local, which is multicast DNS (RFC 6762). An AD zone there competes with Bonjour and every Apple device and printer on the segment. Use a name under .test, which RFC 2606 reserves and no registry can delegate." -f $dcDomainName)
}

# --------------------------------------------------------- ALREADY PROMOTED? --
#
# Win32_ComputerSystem.DomainRole: 0 standalone workstation, 1 member
# workstation, 2 standalone server, 3 member server, 4 backup domain
# controller, 5 primary domain controller. 4 and 5 both mean "this is a DC".

$dcComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
Write-Host ('this machine is {0}, DomainRole {1}, domain {2}' -f
    $dcComputerSystem.Name, $dcComputerSystem.DomainRole, $dcComputerSystem.Domain)

if ($dcComputerSystem.DomainRole -ge 4) {
    Write-Host ('already a domain controller for {0} - nothing to promote. This step is re-entrant on purpose: an engine resume can land on it a second time, and asking an existing controller to create a forest fails with a message about the machine already being one.' -f
        $dcComputerSystem.Domain)
    return
}

# ------------------------------------------------------- THE DSRM PASSWORD ----

$dcSafeModePassword = ''
if ($Variable.Contains('HDTDsrmPassword')) { $dcSafeModePassword = [string] $Variable['HDTDsrmPassword'] }

if ([string]::IsNullOrWhiteSpace($dcSafeModePassword)) {
    throw ("nothing supplies HDTDsrmPassword, and Install-ADDSForest cannot promote without a Directory Services Restore Mode password. Set it in the fallback rule of rules.yaml (MDT's [Default] section) or in Control\machines\<UUID>.yaml for this machine. It is classified secret by name, so it is redacted in every log, checkpoint and report without anything asking.")
}

# THE REDACTION, RECOGNISED RATHER THAN USED. The literal is
# Protect-HDTSecretValue's, and it is written out here rather than imported
# because a payload script has no HDT module in its session.
if ($dcSafeModePassword -eq '(set, not shown)') {
    throw ("HDTDsrmPassword arrived as the checkpoint's redaction rather than as a value, so this leg does not have the password. That is DESIGN 4.5.2: this step runs in the full OS, which is the leg AFTER a restart, and Save-HDTRunState writes '(set, not shown)' in place of every secret on the way to state.json - a file that is copied to the deployment share. Promoting with that literal would succeed and would leave this controller's DSRM password set to a sentence out of a log. The durable fix is the LSA-carried secret bag DESIGN 4.5.2 names and ROADMAP tracks; until it lands, HDTDsrmPassword has to be set in the leg that runs this step.")
}

if ($dcSafeModePassword.Length -lt 8) {
    throw ('HDTDsrmPassword is {0} character(s). The default domain password policy of a new forest requires at least 7 and complexity, and a DSRM password that fails the policy fails the promotion after the schema has already been written.' -f $dcSafeModePassword.Length)
}

$dcSecurePassword = ConvertTo-SecureString -String $dcSafeModePassword -AsPlainText -Force

# ------------------------------------------------------------- THE MODULE -----
#
# ADDSDeployment ships with the AD DS role's MANAGEMENT TOOLS, not with the role.
# The InstallRoles step sets includeManagementTools for exactly this, and the
# check is here so a missing module reads as the flag it is rather than as
# "the term Install-ADDSForest is not recognized" on a server that has just
# installed Active Directory.

if (-not (Get-Module -ListAvailable -Name 'ADDSDeployment')) {
    throw ('the ADDSDeployment module is not on this server, so Install-ADDSForest does not exist here. It comes with the AD DS role''s MANAGEMENT TOOLS - set includeManagementTools: true on the InstallRoles step. Installed modules found: {0}.' -f
        ((@(Get-Module -ListAvailable | ForEach-Object { $_.Name }) | Sort-Object -Unique) -join ', '))
}

Import-Module -Name 'ADDSDeployment' -ErrorAction Stop
Write-Host 'ADDSDeployment imported'

# THE ADAPTER, LOGGED BEFORE THE WARNING IS ACCEPTED. This is the thing
# Install-ADDSForest is about to complain about, so the log should show what it
# was actually looking at - the address is a DHCP lease and is a fact about
# this afternoon, not about HDT.
foreach ($dcAddress in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {

    Write-Host ('adapter {0}: {1}/{2}, prefix origin {3}, suffix origin {4}' -f
        $dcAddress.InterfaceAlias, $dcAddress.IPAddress, $dcAddress.PrefixLength,
        $dcAddress.PrefixOrigin, $dcAddress.SuffixOrigin)
}

Write-Host ('accepting, deliberately: the static-address warning (this server keeps its DHCP lease - see the sequence header) and the delegation warning (.test has no parent zone anywhere, which is what makes it safe here).')

# ----------------------------------------------------------- THE PROMOTION ----
#
# -InstallDns IS EXPLICIT rather than left to its default. It defaults to true
# for a new forest, and a default that changes underneath a lab is a lab that
# stops working for no visible reason. This forest's DNS is its own: nothing
# else on the segment can resolve hdtlab.test and nothing else should try.
#
# -CreateDnsDelegation IS EXPLICITLY FALSE for the reason above - there is no
# parent zone to delegate from - and saying so is what stops the promotion
# pausing to ask about it.

$dcArgument = @{
    DomainName                    = $dcDomainName
    DomainNetbiosName             = $dcNetbiosName
    ForestMode                    = $dcForestMode
    DomainMode                    = $dcForestMode
    InstallDns                    = $true
    CreateDnsDelegation           = $false
    SafeModeAdministratorPassword = $dcSecurePassword
    NoRebootOnCompletion          = $true
    Force                         = $true
    SkipPreChecks                 = $false
    Confirm                       = $false
}

Write-Host ('Install-ADDSForest: DomainName={0} DomainNetbiosName={1} ForestMode={2} DomainMode={2} InstallDns=True CreateDnsDelegation=False NoRebootOnCompletion=True' -f
    $dcDomainName, $dcNetbiosName, $dcForestMode)

$dcResult = Install-ADDSForest @dcArgument

# WHAT IT SAID, NOT JUST THAT IT RETURNED. Install-ADDSForest emits a result
# object carrying Status, Message and RebootRequired, and a promotion that
# reports Error while returning normally is a real shape - the deployment
# operation can fail after the cmdlet has decided not to throw.
if ($null -ne $dcResult) {
    Write-Host ('Install-ADDSForest returned Status={0} RebootRequired={1}' -f
        $dcResult.Status, $dcResult.RebootRequired)

    if (-not [string]::IsNullOrWhiteSpace([string] $dcResult.Message)) {
        Write-Host ('Install-ADDSForest message: {0}' -f $dcResult.Message)
    }

    if (([string] $dcResult.Status) -match '(?i)error|fail') {
        throw ('the promotion of this server to a domain controller of {0} reported {1}: {2}' -f
            $dcDomainName, $dcResult.Status, $dcResult.Message)
    }
}

Write-Host ('{0} has been created and this server is its first domain controller. It is NOT one yet: NTDS, Netlogon, the SYSVOL and NETLOGON shares and every _ldap._tcp record arrive on the next boot, which the sequence''s Restart step performs.' -f
    $dcDomainName)
