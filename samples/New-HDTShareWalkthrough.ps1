# Import Hephaestus module
Import-Module -Name Hephaestus -Force

# Where the deployment share lives on this machine
$root = 'C:\HDTLab\MySecondHDT'

# The UNC path a booted machine uses to reach it. The trailing $ hides it from
# network browsing, which is MDT's default.
$share = Get-HDTWorkspaceShareName -Path $root

# Create the deployment unc share with hidden ($)
New-HDTWorkspace -Path $root -Id 'MySecondHDT' -DeployRoot $share.DeployRoot

# A second share on the same host, kept separate - New-HDTWorkspace refuses to
# write into a folder that already holds one.
$visibleRoot = 'C:\HDTLab\MyVisibleHDT'

# The same UNC without the trailing $, so the share shows up in network browsing.
# Composed by hand - Get-HDTWorkspaceShareName appends the $ whatever you pass it.
$visibleDeployRoot = '\\{0}\MyVisibleHDT' -f [System.Environment]::MachineName

# Create the second deployment share, this one not hidden
New-HDTWorkspace -Path $visibleRoot -Id 'MyVisibleHDT' -DeployRoot $visibleDeployRoot

# The deployment account's password, in clear text. New-LocalUser takes a
# SecureString, so it is converted here rather than stored as one.
$password = ConvertTo-SecureString 'P@ssw0rd-CHANGE-ME' -AsPlainText -Force

# The account a booted machine opens the share as. HDT does not create one for
# you - it only grants it access.
New-LocalUser -Name 'svc-hdt-deploy' -Password $password -PasswordNeverExpires -UserMayNotChangePassword

# The account as the share will name it, machine-qualified
$account = '{0}\svc-hdt-deploy' -f [System.Environment]::MachineName

# Publish the folder over SMB and grant the account both ACLs - read at the share,
# read on the tree and modify on Logs and Captures. Needs elevation.
New-HDTWorkspaceShare -Path $root -Account $account

# Read the ACL rows off the folders that matter. This is the only command in HDT
# that calls Get-Acl; the checker below is pure logic over what it returns.
$accessRule = @{
    '.'        = @(Get-HDTShareAccessRule -Path $root)
    'Logs'     = @(Get-HDTShareAccessRule -Path (Join-Path $root 'Logs'))
    'Captures' = @(Get-HDTShareAccessRule -Path (Join-Path $root 'Captures'))
}

# Judge whether the account is least-privileged. It warns, it never throws -
# a domain admin credential in a boot image is the failure worth catching.
Test-HDTShareAcl -WorkspaceRoot $root -Identity $account -AccessRule $accessRule

# Declare the account in workspace.yaml. The document you commit names it; the
# password goes somewhere else, below.
$line = [string[]] @([System.IO.File]::ReadAllLines((Join-Path $root 'workspace.yaml')))
$line = Set-HDTWorkspaceProperty -Line $line -CredentialUser $account

# Save it back
Save-HDTWorkspaceDocument -Path (Join-Path $root 'workspace.yaml') -Line $line

# The account's secret, into Control\share-credential.json where the boot image
# build reads it. Without this the image ASKS THE TECHNICIAN at boot.
$deployCredential = New-Object PSCredential($account, $password)

# Write it
Set-HDTShareCredential -WorkspaceRoot $root -Credential $deployCredential

# Register the Windows media in place - seconds, not gigabytes. -Copy would bring
# it into the share instead.
Import-HDTOperatingSystem -WorkspaceRoot $root -Id 'Win11-LTSC-2024' `
    -SourcePath 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim' `
    -Name 'Windows 11 Enterprise LTSC 2024' `
    -ImageService (New-HDTImageService) -Clock (New-HDTClock)

# What templates a sequence can be created from
Get-HDTSequenceTemplate | Format-Table Id, Name

# Create the task sequence from the client template - MDT's phases in MDT's order
New-HDTTaskSequence -Workspace $root -Id 'WIN11' -Name 'Windows 11 bare metal' -Template client

# rules.yaml - what CustomSettings.ini was. Read the lines, splice, save the
# lines; a parse and re-emit would drop every comment in the file.
$rulePath = Join-Path $root 'rules.yaml'
$line = [string[]] @([System.IO.File]::ReadAllLines($rulePath))

# At the top, so it wins - first match wins per variable, so -First is an
# override and an appended rule is a fallback.
$line = Add-HDTRule -Line $line -First -Name 'MySecondHDT defaults' -Set @{
    HDTTaskSequenceID = 'WIN11'
    HDTSkipWizard     = $true
    HDTJoinWorkgroup  = 'WORKGROUP'
    HDTComputerName   = 'HDT-%HDTSerialNumber%'
    HDTApplications   = '7Zip-24.09'

    # Readable on purpose - WinPE uses it with no human present. Change it.
    HDTAdminPassword  = 'P@ssw0rd-CHANGE-ME'
}

# A conditional rule. `when` matches gathered facts and supports wildcards.
$line = Add-HDTRule -Line $line -Name 'Laptop naming' -After 'MySecondHDT defaults' `
    -When @{ HDTIsLaptop = $true } -Set @{ HDTComputerName = 'LT-%HDTSerialNumber%' }

# Save the rules
Save-HDTRuleDocument -Path $rulePath -Line $line

# bootstrap-rules.yaml - MDT's Bootstrap.ini. It travels INSIDE the boot image and
# chooses which share to connect to before there is a share to read. It may set
# only HDTDeployRoot, HDTUserId, HDTUserDomain and HDTUserPassword.
$bootstrapPath = Join-Path $root 'bootstrap-rules.yaml'
[System.IO.File]::WriteAllLines($bootstrapPath, [string[]] @(
        'schemaVersion: 1'
        'rules:'
        '  - name: Lab subnet'
        '    when: { HDTDefaultGateway: "192.168.1.*" }'
        '    set:'
        ('      HDTDeployRoot: {0}' -f $share.DeployRoot)
        ''
        '  - name: Fallback'
        '    set:'
        ('      HDTDeployRoot: {0}' -f $share.DeployRoot)
    ))

# This machine's own facts, which is what a bootstrap rule matches on
$fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
    -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)

# Prove the rules parse and resolve - the closest thing to a dry run there is
Resolve-HDTBootstrapRule -RuleDocument (Import-HDTBootstrapRuleDocument -Path $bootstrapPath) `
    -Fact $fact -DeployRoot $share.DeployRoot

# Where the installer sits. Put 7z2409-x64.msi here before deploying.
$applicationSource = 'C:\HDTLab\appsource\7Zip'

# Add the software to the catalog. The detection rule is what makes a second run
# install it once.
Import-HDTApplication -WorkspaceRoot $root -Id '7Zip-24.09' `
    -Name '7-Zip 24.09 x64' -Publisher 'Igor Pavlov' -Version '24.09' `
    -Install 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart' `
    -Uninstall 'msiexec.exe /x "{23170F69-40C1-2702-2409-000001000000}" /qn /norestart' `
    -SuccessCode 0, 3010 -RebootCode 3010 -RunIn FullOS `
    -Detect @{ type = 'msiProduct'; productCode = '{23170F69-40C1-2702-2409-000001000000}' } `
    -SourcePath $applicationSource

# The sequence document, which the next four edits splice
$sequencePath = Join-Path $root 'TaskSequences\WIN11\sequence.yaml'
$line = [string[]] @([System.IO.File]::ReadAllLines($sequencePath))

# Add the software to the task sequence. The template's step reads
# %HDTApplications%; this pins the list on the step instead.
$line = Set-HDTStepPropertyList -Line $line -Name 'Install Applications' `
    -Property 'selection' -Item @('7Zip-24.09')

# A CommandLine step. `command:` runs through %ComSpec% /c, so `if not exist`
# works - and md against an existing folder exits 1, which is not in
# successCodes, so the guard is what makes the step safe on a resume.
$line = Add-HDTStep -Line $line -After 'Install Applications' -Name 'Create C:\Temp' -Type CommandLine

# Give it the command
$line = Set-HDTStepProperty -Line $line -Name 'Create C:\Temp' `
    -Property 'command' -Value 'if not exist C:\Temp md C:\Temp'

# A PowerShell step, which names a script in the workspace rather than inline code
$line = Add-HDTStep -Line $line -After 'Create C:\Temp' -Name 'Disable the firewall' -Type PowerShell

# The path is relative to the workspace root, so the sequence still works from media
$line = Set-HDTStepProperty -Line $line -Name 'Disable the firewall' `
    -Property 'script' -Value 'Scripts\Disable-HDTFirewall.ps1'

# Save all four edits at once
Save-HDTSequenceDocument -Path $sequencePath -Line $line

# The script that step runs. NetSecurity does not exist in WinPE, so this runs
# after the restart. Everything it writes lands in the log.
$firewallScript = @'
[CmdletBinding()]
param(
    # The engine passes the live variable dictionary.
    [Parameter()]
    [AllowNull()]
    [object] $Variable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False

foreach ($profileState in @(Get-NetFirewallProfile -Profile Domain, Private, Public)) {
    Write-Host ('firewall {0}: enabled = {1}' -f $profileState.Name, $profileState.Enabled)
}
'@

# Write it into the workspace
[System.IO.File]::WriteAllText((Join-Path $root 'Scripts\Disable-HDTFirewall.ps1'), $firewallScript)

# The finished sequence, flattened
$sequence = Import-HDTSequenceDocument -Path $sequencePath

# Twelve steps: the template's ten, plus the two added above
$sequence.Step | Format-Table Index, Name, Type, RunIn -AutoSize

# Every variable the rules set, so the check can tell a real one from a typo
$knownVariable = @((Import-HDTRuleDocument -Path $rulePath).Rule |
        Where-Object { $null -ne $_.Set } | ForEach-Object { $_.Set.Keys })

# Check the whole sequence before building anything
Test-HDTTaskSequence -Sequence $sequence -KnownVariable $knownVariable

# Build the boot image. One build, two artefacts: Boot\HDTPE_x64.wim for WDS and
# Boot\HDTPE_x64.iso for a VM. About 100 seconds, and quiet for most of them -
# killing it strands a mounted image that needs dism /cleanup-wim.
Update-HDTBootImage -WorkspaceRoot $root -Firmware UEFI

# Attach the ISO to a Generation 2 HDT-* VM on the 'HDT External' switch - it
# needs a DHCP lease on the real LAN to reach the share. Logs come back to
# Logs\ under the share; Start-HDTConsole opens it in a window.
