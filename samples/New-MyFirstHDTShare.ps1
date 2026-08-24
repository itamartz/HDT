#Requires -Version 5.1
<#
    .SYNOPSIS
        A guided, end-to-end walkthrough: build a deployment share called
        MyFirstHDT and take it as far as a bootable ISO.

    .DESCRIPTION
        EVERY STEP IS A REAL COMMAND, in the order somebody standing up their
        first share actually runs them. Nothing here is pseudo-code and nothing
        is a wrapper invented for the walkthrough - if a line works here it works
        typed at a prompt, which is the only way a tutorial stays true after the
        module changes underneath it.

        THE TWELVE STEPS:

           1  Prerequisites          module, elevation, powershell-yaml, the ADK
           2  New-HDTWorkspace       the share's folder tree and its documents
           3  New-HDTWorkspaceShare  publish it over SMB, so a booted machine
                                     can read it
           4  Import-HDTOperatingSystem   register the staged Windows media
           5  New-HDTTaskSequence    a sequence from the client template
           6  Add-HDTRule            rules.yaml - what CustomSettings.ini was
           7  bootstrap-rules.yaml   which share to connect to, before there is
                                     a share to read it from
           8  Import-HDTApplication  put software in the catalog...
           9  Set-HDTStepPropertyList ...and name it in the sequence
          10  Add-HDTStep            a CommandLine step that creates C:\Temp
          11  Add-HDTStep            a PowerShell step that turns the firewall
                                     off on all three profiles
          12  Update-HDTBootImage    the .wim for WDS and the .iso for a VM

        RUN IT WHOLE OR ONE STEP AT A TIME. -Step 6 runs only the rules, against
        the share the earlier steps left behind; -From 6 runs six onwards. Every
        step is written to be safe to run twice, so a re-run after a fix is not a
        rebuild from nothing.

        THE YAML IS EDITED BY SPLICING, NEVER BY RE-SERIALISING. Add-HDTRule and
        Add-HDTStep take the file's lines and hand back lines - the comments in
        a template are half of what a template is worth, and a parse-and-emit
        would drop every one of them. That is why each authoring step here reads
        the file into $line, changes it, and saves $line.

    .PARAMETER Root
        Where the share is created. Defaults to C:\HDTLab\MyFirstHDT.

    .PARAMETER MediaPath
        The install.wim to register in step 4. Defaults to the staged Windows 11
        LTSC media in the lab.

    .PARAMETER ApplicationSource
        The folder holding the installer imported in step 8. When it does not
        exist the step explains what to put there and carries on - the catalog
        entry is the lesson, not the payload.

    .PARAMETER Step
        Run only these steps, by number.

    .PARAMETER From
        Run from this step to the end.

    .PARAMETER SkipBootImage
        Stop after step 11. The boot image build is the only step here that
        takes minutes rather than seconds and needs the ADK.

    .EXAMPLE
        .\New-MyFirstHDTShare.ps1

        The whole walkthrough, ending with Boot\HDTPE_x64.iso.

    .EXAMPLE
        .\New-MyFirstHDTShare.ps1 -SkipBootImage

        Everything up to the ISO - the authoring, which is where the learning is.

    .EXAMPLE
        .\New-MyFirstHDTShare.ps1 -Step 10, 11

        Add just the two custom steps to a share that already exists.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Root = 'C:\HDTLab\MyFirstHDT',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $MediaPath = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ApplicationSource = 'C:\HDTLab\media\apps\7Zip',

    [Parameter()]
    [ValidateRange(1, 12)]
    [int[]] $Step,

    [Parameter()]
    [ValidateRange(1, 12)]
    [int] $From = 1,

    [Parameter()]
    [switch] $SkipBootImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# The walkthrough's own plumbing. Two helpers, deliberately - a tutorial that
# needs a framework to read has stopped being a tutorial.
# ---------------------------------------------------------------------------

function Write-Heading {
    param([int] $Number, [string] $Title)

    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host ("  STEP {0,-2}  {1}" -f $Number, $Title) -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}

function Test-Wanted {
    param([int] $Number)

    if ($null -ne $Step -and @($Step).Count -gt 0) {
        return (@($Step) -contains $Number)
    }

    if ($Number -eq 12 -and $SkipBootImage) { return $false }

    return ($Number -ge $From)
}

# THE MODULE IS IMPORTED HERE, NOT INSIDE STEP 1, and that is a correctness
# point rather than tidiness: -Step 6 skips step 1, and a step that skipped the
# import fails on the first HDT command with "not recognized", which reads like
# a broken install rather than a script that was run out of order.
#
# The repository copy first, so this works from a clone with nothing installed.
# On a machine where HDT is installed properly this is just Import-Module
# Hephaestus.
$script:HDTManifest = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'src\Hephaestus\Hephaestus.psd1'

if (Test-Path -LiteralPath $script:HDTManifest) {
    Import-Module -Name $script:HDTManifest -Force
}
else {
    $script:HDTManifest = 'Hephaestus, from PSModulePath'
    Import-Module -Name 'Hephaestus' -Force
}

$sequenceId = 'WIN11'
$osId = 'Win11-LTSC-2024'
$applicationId = '7Zip-24.09'
$sequencePath = [System.IO.Path]::Combine($Root, 'TaskSequences', $sequenceId, 'sequence.yaml')
$rulePath = [System.IO.Path]::Combine($Root, 'rules.yaml')
$bootstrapPath = [System.IO.Path]::Combine($Root, 'bootstrap-rules.yaml')
$workspacePath = [System.IO.Path]::Combine($Root, 'workspace.yaml')

# ===========================================================================
#  STEP 1 - PREREQUISITES
#
#  Four things, and each of them fails LATER and less clearly if it is missing
#  now: the module itself, elevation (step 3 publishes an SMB share and step 12
#  mounts a WIM), powershell-yaml (without it not one document can be written),
#  and the ADK (step 12 only).
# ===========================================================================

if (Test-Wanted 1) {
    Write-Heading 1 'Prerequisites'

    Write-Host ("module   : {0}" -f $script:HDTManifest) -ForegroundColor Green
    Write-Host ("version  : {0}" -f (Get-HDTModuleVersion))

    # Test-HDTElevation is the adapter that asks. Publishing a share and mounting
    # an image both need it; authoring documents does not, which is why this
    # warns rather than throws.
    if (Test-HDTElevation) {
        Write-Host 'elevated : yes' -ForegroundColor Green
    }
    else {
        Write-Warning 'not elevated - steps 3 and 12 will refuse. Authoring steps are fine.'
    }

    # THE DEPENDENCY THAT IS NOT OPTIONAL. Every document this share holds is
    # YAML, and this module is what reads and writes it.
    if (Get-Module -ListAvailable -Name 'powershell-yaml') {
        Write-Host 'yaml     : powershell-yaml present' -ForegroundColor Green
    }
    else {
        Write-Warning 'powershell-yaml is missing. Install-Module powershell-yaml -Scope AllUsers'
    }

    # ADK, for step 12 only. Resolve it through Get-HDTAdkPath rather than a
    # hard-coded folder - the layout has moved between ADK releases, and oscdimg
    # in particular is in Deployment Tools, NOT in the WinPE Media\EFI tree that
    # looks like it should hold it.
    #
    # THE ASSET IS NAMED. -Asset is mandatory in this command's default
    # parameter set, so a bare Get-HDTAdkPath does not fail - it PROMPTS, which
    # in a script reads as a hang. -All is the set that answers "what is
    # installed", and it is the right question here.
    try {
        $adk = @(Get-HDTAdkPath -All)
        $missing = @($adk | Where-Object { -not $_.Exists })

        Write-Host ("adk      : {0}" -f (@($adk | Where-Object { $_.Name -eq 'Root' })[0].Path)) -ForegroundColor Green

        if (@($missing).Count -gt 0) {
            Write-Warning ("ADK assets missing, so step 12 may refuse: {0}" -f (@($missing | ForEach-Object { $_.Name }) -join ', '))
        }
    }
    catch {
        Write-Warning ("ADK not found - step 12 will refuse. {0}" -f $_.Exception.Message)
    }

    # WHERE THE BOOTED MACHINE WILL LOOK FOR THIS HOST. In this lab the host's
    # address is a DHCP lease and it moves, so it is read now and never
    # remembered - it gets baked into the boot image in step 12.
    $address = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -eq 'vEthernet (HDT External)' })

    if (@($address).Count -gt 0) {
        Write-Host ("lab ip   : {0} on {1}" -f $address[0].IPAddress, $address[0].InterfaceAlias) -ForegroundColor Green
    }
}

# ===========================================================================
#  STEP 2 - THE WORKSPACE
#
#  MDT's "New Deployment Share" wizard. It creates the folder tree
#  (TaskSequences, OperatingSystems, Applications, Drivers, Boot, Logs,
#  Captures, Control, Scripts, Modules) and the two documents that make a
#  directory a share: workspace.yaml and rules.yaml.
#
#  deployRoot IS THE UNC PATH A BOOTED MACHINE WILL USE, not the local path.
#  It goes into the boot image verbatim in step 12, so a machine in WinPE has
#  to be able to resolve it - which is why it is \\host\share$ and never C:\.
# ===========================================================================

if (Test-Wanted 2) {
    Write-Heading 2 'Create the deployment share'

    # Composed rather than typed, so the share name and the UNC path agree with
    # what step 3 will actually publish.
    $name = Get-HDTWorkspaceShareName -Path $Root
    Write-Host ("share    : {0}" -f $name.ShareName)
    Write-Host ("deployRoot: {0}" -f $name.DeployRoot)

    if (Test-Path -LiteralPath $workspacePath) {
        Write-Host 'workspace.yaml already here - New-HDTWorkspace never replaces one, so skipping.' -ForegroundColor Yellow
    }
    else {
        $workspace = New-HDTWorkspace -Path $Root -Id 'MyFirstHDT' -Name 'My First HDT Share' -DeployRoot $name.DeployRoot
        Write-Host ("created  : {0}" -f $workspace.Path) -ForegroundColor Green
    }

    Get-ChildItem -LiteralPath $Root | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host ("  {0}" -f $_) }
}

# ===========================================================================
#  STEP 3 - PUBLISH IT OVER SMB
#
#  A share a booted machine cannot read is a deployment that stops at the first
#  file. This publishes the folder and grants the deployment account BOTH ACLS -
#  read at the share, read on the tree, and modify on Logs\ and Captures\ - then
#  writes that account's password into Control\share-credential.json, which is
#  where the boot image picks it up.
#
#  BOTH HALVES, BECAUSE ONE IS NOT ENOUGH. SMB gates the connection and NTFS
#  gates the file, and the effective right is the more restrictive of the two.
#
#  THE ACCOUNT IS DECLARED IN workspace.yaml AND ITS SECRET IS WRITTEN
#  SEPARATELY, on purpose: workspace.yaml is the document you hand-edit and
#  commit, and a password in it ends up in git.
# ===========================================================================

if (Test-Wanted 3) {
    Write-Heading 3 'Publish the share over SMB'

    if (-not (Test-HDTElevation)) {
        Write-Warning 'Publishing a share needs elevation. Re-run this step from an elevated session.'
    }
    else {
        $account = ('{0}\{1}' -f [System.Environment]::MachineName, 'svc-hdt-deploy')

        # The account itself is yours to create - HDT does not make one, because
        # a toolkit that creates local accounts on its own is a toolkit nobody
        # audits. A read-only local account is enough:
        #
        #   New-LocalUser -Name svc-hdt-deploy -Password (Read-Host -AsSecureString) `
        #       -PasswordNeverExpires -UserMayNotChangePassword
        #
        # See docs/share-account.md for the full account and ACL story.
        if (-not (Get-LocalUser -Name 'svc-hdt-deploy' -ErrorAction SilentlyContinue)) {
            Write-Warning 'svc-hdt-deploy does not exist. Publishing the share anyway; create the account and re-run this step to grant it access.'
            $null = New-HDTWorkspaceShare -Path $Root
        }
        else {
            $share = New-HDTWorkspaceShare -Path $Root -Account $account
            Write-Host ("published: {0}" -f $share.DeployRoot) -ForegroundColor Green

            # Declare the account in workspace.yaml...
            $line = [string[]] @([System.IO.File]::ReadAllLines($workspacePath))
            $line = Set-HDTWorkspaceProperty -Line $line -CredentialUser $account
            $null = Save-HDTWorkspaceDocument -Path $workspacePath -Line $line

            # ...and write its secret where the boot image build reads it. Without
            # this the built image ASKS THE TECHNICIAN for the account at boot,
            # which is MDT's behaviour for a Bootstrap.ini with no UserID.
            Write-Host 'Enter the password for svc-hdt-deploy (it is written to Control\share-credential.json):'
            $credential = Get-Credential -UserName $account -Message 'HDT deployment account'
            Set-HDTShareCredential -WorkspaceRoot $Root -Credential $credential
            Write-Host 'credential: written' -ForegroundColor Green
        }

        # PROVE IT FROM THE OUTSIDE. A share that exists but refuses the account
        # fails at boot, not here, unless it is checked here.
        #
        # THE CHECKER IS PURE LOGIC and reads no ACL of its own -
        # Get-HDTShareAccessRule is the one command in HDT that calls Get-Acl,
        # and its rows are what gets judged. Hand it the root and the two
        # folders the account writes to; a folder not passed is not judged.
        $accessRule = @{
            '.'        = @(Get-HDTShareAccessRule -Path $Root)
            'Logs'     = @(Get-HDTShareAccessRule -Path (Join-Path $Root 'Logs'))
            'Captures' = @(Get-HDTShareAccessRule -Path (Join-Path $Root 'Captures'))
        }

        $acl = Test-HDTShareAcl -WorkspaceRoot $Root -Identity $account -AccessRule $accessRule

        if ($acl.Compliant) {
            Write-Host 'acl      : least-privileged' -ForegroundColor Green
        }
        else {
            $acl.Finding | Format-Table Severity, Path, Message -AutoSize
        }
    }
}

# ===========================================================================
#  STEP 4 - IMPORT THE OPERATING SYSTEM
#
#  Registers staged media IN PLACE - seconds, not gigabytes. The catalog entry
#  records where the .wim is and what indexes it holds; -Copy would bring the
#  media into the share instead, which is what you want for standalone media
#  and not what you want on a laptop.
#
#  The id used here, Win11-LTSC-2024, is what the sequence's HDTOSImage
#  variable names in step 5. They have to match.
# ===========================================================================

if (Test-Wanted 4) {
    Write-Heading 4 'Register the Windows media'

    if (-not (Test-Path -LiteralPath $MediaPath)) {
        Write-Warning ("no media at '{0}'. Point -MediaPath at an install.wim and re-run step 4." -f $MediaPath)
    }
    elseif (@(Get-HDTOperatingSystem -WorkspaceRoot $Root | Where-Object { $_.Id -eq $osId }).Count -gt 0) {
        Write-Host ("{0} is already in the catalog." -f $osId) -ForegroundColor Yellow
    }
    else {
        # The two adapters this command takes rather than creates: the image
        # service reads the WIM's indexes through DISM, the clock stamps the
        # catalog entry. Injected so the command is provable under Pester.
        $os = Import-HDTOperatingSystem -WorkspaceRoot $Root -Id $osId `
            -SourcePath $MediaPath -Name 'Windows 11 Enterprise LTSC 2024' `
            -ImageService (New-HDTImageService) -Clock (New-HDTClock)

        Write-Host ("imported : {0} - {1} index(es)" -f $os.Id, @($os.Image).Count) -ForegroundColor Green
        $os.Image | Format-Table Index, Name, Edition, Architecture
    }
}

# ===========================================================================
#  STEP 5 - THE TASK SEQUENCE, FROM THE CLIENT TEMPLATE
#
#  MDT's New Task Sequence wizard asks for an id, a name and a template, then
#  copies that template into the new sequence's folder. This does the same into
#  TaskSequences\<Id>\sequence.yaml.
#
#  A TEMPLATE IS A REAL sequence.yaml ON DISK - open it, read it, diff it. The
#  client one carries MDT's phases in MDT's order: Initialization, Validation,
#  Preinstall, Install, Postinstall, State Restore.
# ===========================================================================

if (Test-Wanted 5) {
    Write-Heading 5 'Create the task sequence'

    Write-Host 'Templates available:'
    Get-HDTSequenceTemplate | Format-Table Id, Name, Description -AutoSize

    if (Test-Path -LiteralPath $sequencePath) {
        Write-Host ("{0} already exists - New-HDTTaskSequence never writes over one." -f $sequenceId) -ForegroundColor Yellow
    }
    else {
        $sequence = New-HDTTaskSequence -Workspace $Root -Id $sequenceId `
            -Name 'Windows 11 bare metal' -Template client

        Write-Host ("created  : {0}" -f $sequence.Path) -ForegroundColor Green
    }

    # What the template gave us, flattened. Every -After anchor used later in
    # this script is a Name out of this list.
    $document = Import-HDTSequenceDocument -Path $sequencePath
    $document.Step | Format-Table Index, Name, Type, RunIn -AutoSize
}

# ===========================================================================
#  STEP 6 - RULES.YAML
#
#  What CustomSettings.ini was. Rules are walked top to bottom and a `set` key
#  only takes effect if that variable is NOT already resolved - so FIRST MATCH
#  WINS PER VARIABLE, and a rule added at the top is an override while one
#  added at the bottom is a fallback. That is why Add-HDTRule takes -First and
#  -After rather than only appending.
#
#  Everything resolved here is recorded with its PROVENANCE - which rule set it
#  and why - because the single biggest debugging pain in MDT is not knowing
#  why a variable ended up as it did.
# ===========================================================================

if (Test-Wanted 6) {
    Write-Heading 6 'Rules - what CustomSettings.ini was'

    # Read the lines, splice, save the lines. Never parse-and-re-emit: the
    # comments New-HDTWorkspace wrote into rules.yaml are the documentation.
    $line = [string[]] @([System.IO.File]::ReadAllLines($rulePath))

    # WHAT IS ALREADY THERE, so this step can be run twice. Add-HDTRule refuses
    # a duplicate name outright - provenance reports which rule set a variable,
    # and two rules sharing a name would make that answer ambiguous - so the
    # re-run has to skip rather than retry.
    $existingRule = @((Import-HDTRuleDocument -Path $rulePath).Rule | ForEach-Object { $_.Name })

    # AT THE TOP, so it wins: this deployment is unattended, and these are the
    # answers the wizard would otherwise ask for.
    if ($existingRule -contains 'MyFirstHDT defaults') {
        Write-Host "'MyFirstHDT defaults' is already in rules.yaml - skipping." -ForegroundColor Yellow
    }
    else {
        $line = Add-HDTRule -Line $line -First -Name 'MyFirstHDT defaults' -Set @{
            HDTTaskSequenceID = $sequenceId
            HDTSkipWizard     = $true
            HDTJoinWorkgroup  = 'WORKGROUP'
            HDTComputerName   = 'HDT-%HDTSerialNumber%'
            HDTApplications   = $applicationId

            # READABLE ON PURPOSE. WinPE has to use it with no human present,
            # so encrypting it would buy obfuscation and a key-management
            # surface rather than security. Treat the share and the boot media
            # as credentials, and change this before it deploys anything real.
            HDTAdminPassword  = 'P@ssw0rd-CHANGE-ME'
        }
    }

    # A CONDITIONAL RULE. `when` matches gathered facts - model, chassis,
    # gateway, MAC - and supports wildcards. This one names laptops differently,
    # which is the classic CustomSettings.ini example.
    if ($existingRule -contains 'Laptop naming') {
        Write-Host "'Laptop naming' is already in rules.yaml - skipping." -ForegroundColor Yellow
    }
    else {
        $line = Add-HDTRule -Line $line -Name 'Laptop naming' -After 'MyFirstHDT defaults' `
            -When @{ HDTIsLaptop = $true } -Set @{ HDTComputerName = 'LT-%HDTSerialNumber%' }
    }

    $null = Save-HDTRuleDocument -Path $rulePath -Line $line

    # Read it back and show what a machine would resolve. This is the check that
    # matters: a rule that does not parse is a deployment that stops at boot.
    $rules = Import-HDTRuleDocument -Path $rulePath
    # Set is $null on a setFrom rule - a rule that runs a script to decide a
    # variable has not said which one it will decide.
    $rules.Rule | Format-Table Index, Name,
        @{ n = 'Sets'; e = { if ($null -eq $_.Set) { $_.SetFrom } else { ($_.Set.Keys -join ', ') } } } -AutoSize
}

# ===========================================================================
#  STEP 7 - BOOTSTRAP-RULES.YAML
#
#  MDT's Bootstrap.ini, and the one file that cannot live on the share: it is
#  what CHOOSES the share. It travels inside the boot image, is matched against
#  facts the machine already knows about itself (gateway, MAC, model, UUID),
#  and picks a deployRoot before anything has been connected to.
#
#  SAME GRAMMAR, SMALLER VOCABULARY. It is a rules.yaml - same when:, same set:,
#  same first-match-wins - but it may only set four variables, because it runs
#  before there is a share, a workspace or a task sequence to make sense of
#  anything else: HDTDeployRoot, HDTUserId, HDTUserDomain, HDTUserPassword.
#
#  IT IS OPTIONAL, AND MOST SHARES HAVE NONE. Without it the image deploys from
#  the share it was built for, which is what step 2's deployRoot already said.
#  One is written here because one boot image serving two sites is the reason
#  this file exists at all.
# ===========================================================================

if (Test-Wanted 7) {
    Write-Heading 7 'Bootstrap rules - choosing the share before there is one'

    $name = Get-HDTWorkspaceShareName -Path $Root

    # No command composes this file - it is short, hand-written, and read by the
    # boot image rather than by the share, so it is written out here and then
    # validated by the same importer the boot image uses.
    $bootstrapLine = [string[]] @(
        '# MDT''s Bootstrap.ini. It travels INSIDE the boot image and chooses which'
        '# share this machine connects to, from facts it knows before it has'
        '# connected to anything.'
        '#'
        '# First match wins. A machine matching no rule uses the deployRoot the'
        '# image was built with, which is what workspace.yaml said.'
        'schemaVersion: 1'
        'rules:'
        '  - name: Lab subnet'
        '    when: { HDTDefaultGateway: "192.168.2.*" }'
        '    set:'
        ('      HDTDeployRoot: {0}' -f $name.DeployRoot)
        ''
        '  # No when: at all - MDT''s [Default] section. Anything here is what a'
        '  # machine gets when nothing above matched it.'
        '  - name: Fallback'
        '    set:'
        ('      HDTDeployRoot: {0}' -f $name.DeployRoot)
    )

    [System.IO.File]::WriteAllLines($bootstrapPath, $bootstrapLine)

    # Prove it parses, and prove it resolves - with THIS machine's facts, which
    # is the closest thing to a dry run there is.
    $document = Import-HDTBootstrapRuleDocument -Path $bootstrapPath
    # THE THREE ADAPTERS THE GATHER NEEDS, injected rather than reached for.
    # Get-HDTMachineFact takes them mandatory because the engine is provable
    # under Pester only if nothing underneath it touches the machine directly.
    $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
        -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)

    $answer = Resolve-HDTBootstrapRule -RuleDocument $document -Fact $fact -DeployRoot $name.DeployRoot

    Write-Host ("written  : {0}" -f $bootstrapPath) -ForegroundColor Green
    Write-Host ("resolves : {0}  (source: {1}, rule: '{2}')" -f $answer.DeployRoot, $answer.Source, $answer.RuleName)
}

# ===========================================================================
#  STEP 8 - IMPORT AN APPLICATION
#
#  Two halves, and this is the first: the CATALOG ENTRY. It says what the
#  installer is, what exit codes mean success, whether a reboot was requested,
#  and - the part worth the most - HOW TO TELL IT IS ALREADY INSTALLED.
#
#  A detection rule is why running the sequence twice installs 7-Zip once.
#  Without one every re-run reinstalls everything, which on a failed deployment
#  resumed from a checkpoint is exactly the wrong behaviour.
#
#  runIn: FullOS because MSIs do not install into WinPE.
# ===========================================================================

if (Test-Wanted 8) {
    Write-Heading 8 'Import an application into the catalog'

    if (@(Get-HDTApplication -WorkspaceRoot $Root | Where-Object { $_.Id -eq $applicationId }).Count -gt 0) {
        Write-Host ("{0} is already in the catalog." -f $applicationId) -ForegroundColor Yellow
    }
    else {
        if (-not (Test-Path -LiteralPath $ApplicationSource)) {
            # The entry is the lesson; the payload is yours. Create the folder so
            # the import succeeds and the sequence can be inspected, and say what
            # is missing rather than failing three steps later at deploy time.
            $null = New-Item -ItemType Directory -Path $ApplicationSource -Force
            Write-Warning ("no installer in '{0}'. Copy 7z2409-x64.msi there before deploying - the catalog entry is written either way." -f $ApplicationSource)
        }

        $application = Import-HDTApplication -WorkspaceRoot $Root -Id $applicationId `
            -Name '7-Zip 24.09 x64' -Publisher 'Igor Pavlov' -Version '24.09' `
            -Install 'msiexec.exe /i "7z2409-x64.msi" /qn /norestart' `
            -Uninstall 'msiexec.exe /x "{23170F69-40C1-2702-2409-000001000000}" /qn /norestart' `
            -SuccessCode 0, 3010 -RebootCode 3010 -RunIn FullOS `
            -Detect @{ type = 'msiProduct'; productCode = '{23170F69-40C1-2702-2409-000001000000}' } `
            -SourcePath $ApplicationSource

        Write-Host ("imported : {0} -> {1}" -f $application.Id, $application.Path) -ForegroundColor Green
    }

    Get-HDTApplication -WorkspaceRoot $Root | Format-Table Id, Name, RunIn -AutoSize
}

# ===========================================================================
#  STEP 9 - NAME THE APPLICATION IN THE SEQUENCE
#
#  The second half. A catalog entry nothing selects never installs.
#
#  THE TEMPLATE'S STEP READS A VARIABLE: `selection: '%HDTApplications%'`, which
#  is what the wizard's application page fills in and what step 6's rule already
#  set. That is the right answer for a share where different machines get
#  different software.
#
#  PINNING THE LIST ON THE STEP is the other answer, and it is what this step
#  shows: this sequence installs these applications, whatever the variable says.
#  Dependencies are still resolved and still ordered - a pinned selection cannot
#  drop something another application needs.
# ===========================================================================

if (Test-Wanted 9) {
    Write-Heading 9 'Add the application to the task sequence'

    $line = [string[]] @([System.IO.File]::ReadAllLines($sequencePath))

    $line = Set-HDTStepPropertyList -Line $line -Name 'Install Applications' `
        -Property 'selection' -Item @($applicationId)

    $null = Save-HDTSequenceDocument -Path $sequencePath -Line $line

    Write-Host ("selection: {0}" -f $applicationId) -ForegroundColor Green
    $line | Select-String -Pattern 'Install Applications' -Context 0, 4 | ForEach-Object { Write-Host $_ }
}

# ===========================================================================
#  STEP 10 - A COMMANDLINE STEP: CREATE C:\TEMP
#
#  MDT's Run Command Line. `command:` is a single shell line, run through
#  %ComSpec% /c - so redirection, chaining and built-ins like `if not exist`
#  behave the way an administrator expects.
#
#  WHY `if not exist` AND NOT JUST `md`: md against an existing folder exits 1,
#  and 1 is not in successCodes, so the second run of an otherwise identical
#  sequence would fail. A step that is not safe to run twice is a step that
#  breaks every resume.
#
#  WHERE IT GOES: after Install Applications, inside the State Restore group,
#  which the template declares runIn: FullOS. Steps inherit their group's phase,
#  so this one runs in the Windows that has just started - which is the only
#  place C:\ means what it says. In WinPE, C: is frequently the content disk.
# ===========================================================================

if (Test-Wanted 10) {
    Write-Heading 10 'Add a CommandLine step that creates C:\Temp'

    $line = [string[]] @([System.IO.File]::ReadAllLines($sequencePath))

    # SO THE STEP CAN BE RUN TWICE. Adding it again would put a second step of
    # the same name in the sequence, and Set-HDTStepProperty would then refuse
    # to guess which of the two was meant.
    $existingStep = @((Import-HDTSequenceDocument -Path $sequencePath).Step | ForEach-Object { $_.Name })

    if ($existingStep -contains 'Create C:\Temp') {
        Write-Host "'Create C:\Temp' is already in the sequence - skipping." -ForegroundColor Yellow
    }
    else {
        # Add-HDTStep with -Type builds the step from that type's template, which
        # is where its default properties come from - successCodes: [0, 3010].
        $line = Add-HDTStep -Line $line -After 'Install Applications' `
            -Name 'Create C:\Temp' -Type CommandLine

        $line = Set-HDTStepProperty -Line $line -Name 'Create C:\Temp' `
            -Property 'command' -Value 'if not exist C:\Temp md C:\Temp'

        $null = Save-HDTSequenceDocument -Path $sequencePath -Line $line

        Write-Host 'added    : Create C:\Temp (CommandLine, State Restore)' -ForegroundColor Green
    }
}

# ===========================================================================
#  STEP 11 - A POWERSHELL STEP: TURN THE FIREWALL OFF ON ALL THREE PROFILES
#
#  The extensibility point. A PowerShell step names a SCRIPT IN THE WORKSPACE,
#  not inline code - the script is a file you can lint, sign, diff and run by
#  hand, and a relative path is resolved against the workspace root so the same
#  sequence works from a share or from standalone media.
#
#  EVERYTHING THE SCRIPT WRITES IS LOGGED. It runs through the injected script
#  invoker, whose transcript goes to HDT.jsonl, HDT.log and the step's own log
#  at once - so an existing script that only uses Write-Host lands in the log
#  with no modification.
#
#  A SCRIPT THAT THREW IS A FAILED STEP, NOT A FAILED RUN. The exception is
#  caught and returned as Failed; continueOnError and the retry policy belong to
#  the engine loop, which cannot make those decisions about an exception that
#  flew past it.
#
#  AND THE OBVIOUS: turning the firewall off is a lab convenience and a
#  production defect. It is here because it is the shortest honest example of a
#  step that has to run in the full OS with real privileges.
# ===========================================================================

if (Test-Wanted 11) {
    Write-Heading 11 'Add a PowerShell step that disables the firewall'

    $scriptPath = [System.IO.Path]::Combine($Root, 'Scripts', 'Disable-HDTFirewall.ps1')

    $scriptBody = @'
<#
    .SYNOPSIS
        Turns the Windows firewall off on all three profiles.

    .DESCRIPTION
        A LAB CONVENIENCE AND A PRODUCTION DEFECT, and it is worth being blunt
        about which one this is. It exists so a freshly deployed machine answers
        WinRM and SMB without anybody touching it; on anything that leaves the
        lab, delete the step rather than the comment.

        The step that calls this runs in the full OS, after the restart, which is
        the only place Set-NetFirewallProfile exists - WinPE does not carry the
        NetSecurity module.

        Write-Host IS DELIBERATE. The engine's script invoker captures the
        transcript and writes every line into HDT.log and this step's own log, so
        an ordinary script needs no logging code of its own.
#>
[CmdletBinding()]
param(
    # The engine passes the LIVE variable dictionary. Reading it is how a script
    # sees what the rules resolved; assignments a previous step made are visible
    # here too, because it is live rather than a copy.
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

    [System.IO.File]::WriteAllText($scriptPath, $scriptBody)
    Write-Host ("script   : {0}" -f $scriptPath) -ForegroundColor Green

    $line = [string[]] @([System.IO.File]::ReadAllLines($sequencePath))
    $existingStep = @((Import-HDTSequenceDocument -Path $sequencePath).Step | ForEach-Object { $_.Name })

    if ($existingStep -contains 'Disable the firewall') {
        Write-Host "'Disable the firewall' is already in the sequence - skipping." -ForegroundColor Yellow
    }
    else {
        $line = Add-HDTStep -Line $line -After 'Create C:\Temp' `
            -Name 'Disable the firewall' -Type PowerShell

        # A path relative to the workspace root - never an absolute one, or the
        # sequence stops working from media.
        $line = Set-HDTStepProperty -Line $line -Name 'Disable the firewall' `
            -Property 'script' -Value 'Scripts\Disable-HDTFirewall.ps1'

        $null = Save-HDTSequenceDocument -Path $sequencePath -Line $line

        Write-Host 'added    : Disable the firewall (PowerShell, State Restore)' -ForegroundColor Green
    }

    # ---- VALIDATE THE WHOLE SEQUENCE ------------------------------------
    #
    # Before building anything. Test-HDTTaskSequence checks step types resolve,
    # references exist and conditions parse; -KnownVariable lets it tell "a
    # variable the rules set" from "a typo nothing will ever resolve".
    $document = Import-HDTSequenceDocument -Path $sequencePath
    $rules = Import-HDTRuleDocument -Path $rulePath
    $known = @($rules.Rule | Where-Object { $null -ne $_.Set } | ForEach-Object { $_.Set.Keys })

    $finding = @(Test-HDTTaskSequence -Sequence $document -KnownVariable $known)

    Write-Host ''
    Write-Host 'The finished sequence:' -ForegroundColor Cyan
    $document.Step | Format-Table Index, Name, Type, RunIn -AutoSize

    if (@($finding).Count -eq 0) {
        Write-Host 'validation: clean' -ForegroundColor Green
    }
    else {
        Write-Host 'validation:' -ForegroundColor Yellow
        $finding | Format-Table Severity, Index, Step, Message -AutoSize
    }
}

# ===========================================================================
#  STEP 12 - BUILD THE BOOT IMAGE AND THE ISO
#
#  ONE BUILD, TWO ARTEFACTS, HASH-IDENTICAL CONTENT: Boot\HDTPE_x64.wim for
#  WDS/PXE and Boot\HDTPE_x64.iso for a VM. Debugging in a VM and deploying to
#  metal have to be the same image or the VM proves nothing.
#
#  WHAT GOES INTO IT: the WinPE optional components, this module, the YAML
#  module, bootstrap.json (carrying the deployRoot from step 2 verbatim),
#  bootstrap-rules.yaml from step 7, and the share credential from step 3.
#
#  IT TAKES MINUTES, NOT SECONDS, and it is silent for most of them - which is
#  why -Progress exists. A build killed halfway strands a mounted image that
#  needs `dism /cleanup-wim` before anything can build again, so let it finish.
# ===========================================================================

if (Test-Wanted 12) {
    Write-Heading 12 'Build the boot image and the ISO'

    if (-not (Test-HDTElevation)) {
        Write-Warning 'Mounting a WIM needs elevation. Re-run this step from an elevated session.'
    }
    else {
        Write-Host 'Building - this takes a few minutes and is quiet for most of them.'

        $image = Update-HDTBootImage -WorkspaceRoot $Root -Firmware UEFI

        Write-Host ''
        Write-Host ("wim      : {0}  ({1:N0} bytes)" -f $image.WimPath, $image.WimSizeBytes) -ForegroundColor Green
        Write-Host ("iso      : {0}  ({1:N0} bytes)" -f $image.IsoPath, $image.IsoSizeBytes) -ForegroundColor Green
        Write-Host ("built in : {0:N0}s" -f $image.DurationSecond)
    }
}

# ===========================================================================
#  WHAT TO DO WITH IT
# ===========================================================================

Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host '  DEPLOY IT' -ForegroundColor Cyan
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host @"

  IN A VM - attach Boot\HDTPE_x64.iso to a Generation 2 HDT-* machine on the
  'HDT External' switch. It needs DHCP from the real LAN to reach this host's
  share; the isolated 'HDT Lab' switch gets no lease and cannot open a share on
  the host, which is the wrong choice for anything over SMB.

  OVER PXE - Import-HDTBootImageToWds puts the .wim into WDS. Only on the
  isolated switch, where a second PXE responder cannot answer first.

  WHAT HAPPENS AT BOOT - WinPE starts, gathers the machine's facts, reads
  bootstrap-rules.yaml to choose this share, connects as svc-hdt-deploy,
  resolves rules.yaml (which pins the task sequence and skips the wizard), and
  runs $($sequenceId): validate, partition, apply the image, stage the answer file,
  configure boot, restart - then, in Windows, install 7-Zip, create C:\Temp and
  turn the firewall off.

  WHEN SOMETHING GOES WRONG - the logs come back to $Root\Logs. HDT.log reads
  like MDT's BDD.log; HDT.jsonl is the same events as data. Every variable
  carries its provenance: Get-HDTVariableProvenance says which rule set it and
  what it beat.

  THE CONSOLE - Start-HDTConsole opens the same share in a window, where the
  sequence editor edits this sequence and the rules editor edits these rules.

"@
