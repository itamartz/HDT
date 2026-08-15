<#
    .SYNOPSIS
        THE WinPE ENTRY POINT - what startnet.cmd runs. It reads the boot
        image's bootstrap document, finds its content, runs the task sequence
        once, and ends the machine.

    .DESCRIPTION
        This is the file 05-04 stages into the boot image at X:\HDT\ and
        startnet.cmd launches. Nobody is at the keyboard when it runs.

        IT CONTAINS NO DEPLOYMENT LOGIC, AND THAT IS THE POINT. Phase 05's claim
        is that a machine deploys ITSELF from a boot image; an entry point that
        partitioned a disk or applied an image itself would make that claim a lie
        while still producing a deployed machine, and nobody would notice,
        because the machine would deploy. So
        tests/unit/StartHDTDeploymentPayload.Tests.ps1 PARSES this file and
        asserts it names no Storage cmdlet, no DISM cmdlet, no native boot tool,
        no step function, and calls Invoke-HDTTaskSequence exactly once.

        X: IS THE ONLY DRIVE LETTER THIS FILE MAY ASSUME, and the same test
        asserts that too. SPIKES S9.1 measured WinPE handing the CONTENT DISK
        the letter a developer's machine calls its system drive, and the RAM disk
        X:. A deployRoot baked into bootstrap.json at build time therefore cannot
        know what this machine will be given - so the volume carrying the content
        is DISCOVERED, by enumerating the drives this machine actually has and
        handing them to Resolve-HDTDeployRoot. Phase 04's stand-in scanned a
        hard-coded run of letters; this one may not.

        POWERSHELL-YAML IS IMPORTED FIRST, and its version is logged.
        ConvertFrom-HDTYaml imports it lazily and reports HDTDependencyError
        without it, so the engine cannot read one YAML document - not a sequence,
        not a rule, not an image catalog - until that import has happened. SPIKES
        S9.1 proved it loads inside WinPE from a staged copy; the log line is how
        the next run proves it again.

        IT ENDS THE MACHINE IN EVERY PATH, because a VM left at a WinPE prompt
        tells nobody anything except that somebody's timeout expired. And it
        writes RESULT.json to the deploy root's Logs folder BEFORE it does -
        X:\HDT\RESULT.json is a fallback and not the record, because X: is a RAM
        disk and the machine is about to power off. 05-05's zero-keystroke proof
        reads launchedBy out of that file.

        DESIGN 11'S TECHNICIAN UI IS HERE NOW, AND IT STILL RUNS UNATTENDED.
        This header used to say the UI was deliberately absent because it was a
        later milestone. That milestone arrived: the Welcome screen appears when
        this machine has no network, and the wizard appears when the SHARE
        declares pages in Scripts\UI\wizard.yaml. A share that declares none has
        no wizard, so every image built before this deploys with nobody present
        exactly as it did.

        WHAT THE AST TEST STILL REFUSES is this file naming PresentationFramework,
        System.Windows.Forms or XamlReader. Every window goes through an injected
        host, which is why a machine that cannot draw one still deploys - the
        progress display falls back to console lines rather than dying here.

        FOURTEEN THINGS, IN THIS ORDER, AND NOTHING ELSE:

          1. StrictMode, ErrorActionPreference, InformationPreference.
          2. The module root on PSModulePath; powershell-yaml, then Hephaestus.
          3. The real service adapters. A fake never appears in this file.
          4. A log context, before anything can fail.
          5. The bootstrap document.
          6. Wait for an address - ONLY for an Smb provider. A Local provider
             does not wait, and that is the difference between a lab run starting
             in five seconds and starting in two minutes. NO ADDRESS IS WHAT THE
             WELCOME SCREEN IS FOR: a static address is typed there and applied
             through WMI, and only an image that SKIPS that screen fails instead.
          7. Resolve the deploy root from the volumes this machine has.
          8. The credential, or the one deliberate prompt.
          9. The content provider, and Connect().
         10. Facts, the per-machine override, the rules, the resolution.
         10a. The wizard, if the share declares one - then resolve AGAIN with
             what was typed, so DESIGN 3.1's precedence applies rather than
             being patched around.
         10b. The progress display, before the engine starts.
         11. The run state and the execution context.
         12. ONE call to Invoke-HDTTaskSequence.
         13. The tail: the progress window down, RESULT.json where it will still
             exist tomorrow, the log copy-back, Disconnect(), and wpeutil. All of
             it AFTER the catch, never inside the try.

    .PARAMETER BootstrapPath
        The document Update-HDTBootImage wrote into the image.

    .PARAMETER ModuleRoot
        Where powershell-yaml and Hephaestus are staged.

    .PARAMETER SequenceId
        Overrides both the bootstrap and the rules. Empty is the normal case.

    .PARAMETER LogRoot
        The live log directory. Defaults to Get-HDTLogPath for the WinPE phase,
        which owns that answer.

    .PARAMETER NetworkTimeoutSecond
        How long to wait for a usable address before giving up and letting the
        provider fail with a sentence of its own. Only used for Smb.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1

        What startnet.cmd runs.
#>
# $WelcomeXamlPath is used inside the $showWelcome closure, which the analyzer
# does not follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Used inside a closure, which PSReviewUnusedParameter does not follow.')]
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $BootstrapPath = 'X:\HDT\bootstrap.json',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ModuleRoot = 'X:\HDT\Modules',

    [Parameter()]
    [AllowEmptyString()]
    [string] $SequenceId = '',

    [Parameter()]
    [AllowEmptyString()]
    [string] $LogRoot = '',

    [Parameter()]
    [ValidateRange(0, 3600)]
    [int] $NetworkTimeoutSecond = 120,

    # THE THREE WINDOWS, STAGED INTO THE IMAGE BY Update-HDTBootImage. The PAGES
    # live on the share (DESIGN 11.2) and are named by Scripts\UI\wizard.yaml;
    # the shell, the theme and the progress window ship in the boot image
    # because they must exist before the share is reachable.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WizardShellPath = 'X:\HDT\UI\HDTWizardShell.xaml',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WizardThemePath = 'X:\HDT\UI\HDTTheme.xaml',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ProgressXamlPath = 'X:\HDT\UI\HDTProgress.xaml',

    # THE ONE SCREEN THAT RUNS BEFORE THE SHARE IS REACHABLE, so it cannot live
    # on the share with the others (DESIGN 11.2's correction).
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WelcomeXamlPath = 'X:\HDT\UI\HDTWelcome.xaml'
)

# -- 1. the preferences ------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Visible at the WinPE console without Write-Host, which the analyzer refuses.
$InformationPreference = 'Continue'

$runId = 'run-{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$started = [System.Diagnostics.Stopwatch]::StartNew()
$transcript = New-Object -TypeName System.Collections.ArrayList

$log = $null
$content = $null

# One sentence, to the console and to LAUNCHER.log, and - once there is a log
# context - to the engine's own stream as well. Step 5's failure is logged
# rather than printed and lost precisely because step 4 built that context
# first.
$say = {
    param([string] $Message, [string] $Severity = 'Info')

    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    [void] $transcript.Add($line)
    Write-Information $line

    if ($null -ne $log) {
        Write-HDTLog -Context $log -Severity $Severity -Component 'Bootstrap' -Message $Message
    }
}

$result = [ordered] @{
    runId              = $runId
    status             = 'Failed'
    failedStep         = ''
    message            = ''
    computerName       = ''
    sequenceId         = ''
    provider           = ''
    deployRoot         = ''
    resolvedDeployRoot = ''
    deployRootSource   = ''
    candidateRoot      = @()
    connected          = $false
    yamlLoaded         = $false
    yamlVersion        = ''
    yamlBase           = ''
    engineVersion      = ''
    psVersion          = [string] $PSVersionTable.PSVersion
    elapsedSecond      = 0
    logPath            = ''
    logDestination     = ''
    endedWith          = ''

    # SET BY startnet.cmd (05-04) AND BY NOTHING ELSE. A human typing this
    # command at the prompt does not set it, so 05-05 reads this one field to
    # prove the deployment started itself.
    launchedBy         = [string] $env:HDT_LAUNCHED_BY
}

try {
    # -- 2. the two modules, in the order that is the dependency proof --------

    $env:PSModulePath = '{0};{1}' -f $ModuleRoot, $env:PSModulePath

    Import-Module -Name 'powershell-yaml' -Force -ErrorAction Stop
    $yaml = @(Get-Module -Name 'powershell-yaml')[0]
    $result['yamlLoaded'] = $true
    $result['yamlVersion'] = [string] $yaml.Version
    $result['yamlBase'] = [string] $yaml.ModuleBase

    Import-Module -Name 'Hephaestus' -Force -ErrorAction Stop
    $engine = @(Get-Module -Name 'Hephaestus')[0]
    $result['engineVersion'] = [string] $engine.Version

    # -- 3. the real adapters ------------------------------------------------
    #
    # A fake never appears in this file. This is the one place the real ones are
    # built, which is the whole point of the injection.

    $fileSystem = New-HDTFileSystem
    $clock = New-HDTClock
    $diskService = New-HDTDiskService
    $imageService = New-HDTImageService
    $registry = New-HDTRegistryService
    $lsa = New-HDTLsaService
    $environment = New-HDTEnvironmentProvider
    $cim = New-HDTCimProvider
    $processService = New-HDTProcessService

    # WinPE, and it is not a guess: this file IS the WinPE entry point and hard-
    # codes -Phase WinPE everywhere else. 05-06 mounted the boot image and found
    # no shutdown.exe in it, so a power service built for the full OS would give
    # a Restart step a command that does not exist.
    $power = New-HDTPowerService -Environment WinPE

    # -- 4. the log, before anything else can fail ---------------------------

    $logDirectory = $LogRoot
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Get-HDTLogPath -Phase WinPE
    }

    $fileSystem.CreateDirectory($logDirectory)

    $log = New-HDTLogContext -RunId $runId -Phase WinPE -LogPath $logDirectory `
        -FileSystem $fileSystem -Clock $clock -Level Debug

    $result['logPath'] = $logDirectory

    & $say ("powershell-yaml {0} loaded from {1}" -f $yaml.Version, $yaml.ModuleBase)
    & $say ("Hephaestus {0} loaded from {1}" -f $engine.Version, $engine.ModuleBase)
    & $say ("PowerShell {0}; launched by '{1}'" -f $PSVersionTable.PSVersion, $result['launchedBy'])

    # -- 5. the bootstrap document -------------------------------------------

    $bootstrap = Get-HDTBootstrapConfiguration -Path $BootstrapPath -FileSystem $fileSystem

    $result['provider'] = [string] $bootstrap.Provider
    $result['deployRoot'] = [string] $bootstrap.DeployRoot

    & $say ("bootstrap: workspace '{0}', provider {1}, deployRoot '{2}', marker '{3}'" -f
        $bootstrap.WorkspaceId, $bootstrap.Provider, $bootstrap.DeployRoot, $bootstrap.ContentMarker)

    # -- 6. an address, but only when the content is on a share --------------
    #
    # WinPE has no NetTCPIP and no NetAdapter (DESIGN 5.1), so "have I got an
    # address" is answered from Win32_NetworkAdapterConfiguration through
    # ICimProvider - which is where Get-HDTMachineFact's HDTIPAddress already
    # comes from (SPIKES S9.2). This loop is therefore ALSO the gather: one
    # Get-HDTMachineFact in the whole file, and the last poll is the fact set the
    # rules are resolved against.

    # THE WELCOME SCREEN, WHICH IS WHAT A MACHINE WITH NO NETWORK IS FOR.
    # W2 built it - the network pane, the share box, the credential quartet -
    # and nothing ever showed it. A static address is the answer to DHCP that
    # never answered, and WinPE has no NetTCPIP, so it is applied through WMI
    # (SPIKES S14) by Set-HDTStaticAddress.
    #
    # IT RETURNS Retry, NOT AN ADDRESS. What the technician did to the machine
    # has already happened by then; the caller's job is to poll again and find
    # out whether it worked, which is the only honest test of a static address.
    $showWelcome = {

        # IT TAKES NOTHING. The screen shows what the MACHINE reports, read
        # fresh through Get-HDTNetworkConfiguration - a fact set gathered before
        # the technician was asked is a fact set about the state they are being
        # asked to change.
        $skip = Get-HDTWizardSkip -Bootstrap $bootstrap
        $network = $null

        try {
            $network = Get-HDTNetworkConfiguration
        } catch {
            & $say ("no network configuration could be read for the Welcome screen: {0}" -f $_.Exception.Message) 'Warning'
        }

        $field = @(Get-HDTWizardField -NetworkConfiguration $network -Bootstrap $bootstrap)

        $hidden = $false
        $answer = $null

        try {
            $hidden = [bool] (Hide-HDTShellWindow)
            $answer = Show-HDTWizard -XamlPath $WelcomeXamlPath -Title 'Hephaestus Deployment Toolkit' `
                -Field $field -Pane $skip.Pane
        } finally {
            if ($hidden) { [void] (Hide-HDTShellWindow -Restore) }
        }

        if ($null -eq $answer) { return [pscustomobject] @{ Retry = $false } }

        & $say ("the Welcome screen answered: {0}" -f $answer.Action)

        if ($answer.Action -eq 'CommandPrompt') {
            $prompt = Start-HDTCommandPrompt
            & $say ("command prompt: started {0} ({1})" -f $prompt.Started, $prompt.FilePath)

            return [pscustomobject] @{ Retry = $false }
        }

        return [pscustomobject] @{ Retry = ($answer.Action -eq 'Next') }
    }

    $needAddress = ([string] $bootstrap.Provider -eq 'Smb')
    $waited = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    $fact = $null
    $address = ''

    while ($true) {
        $attempt++
        $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $registry -EnvironmentProvider $environment

        # THE DECISION IS Get-HDTUsableAddress'S, AND IT USED TO BE HERE. Inline,
        # it cast a [string[]] to a string - which SPACE-joins - and then split
        # on commas, so a machine holding 192.168.2.39 waited the whole timeout
        # for an address it already had. A decision has to be a command before a
        # test can find anything wrong with it.
        $address = Get-HDTUsableAddress -Fact $fact

        if (-not $needAddress) {
            & $say ("{0} machine fact(s) gathered; a Local provider does not wait for the network" -f $fact.Count)
            break
        }

        if (-not [string]::IsNullOrEmpty($address)) {
            & $say ("address {0} after {1} attempt(s), gateway '{2}'" -f
                $address, $attempt, [string] $fact['HDTDefaultGateway'])
            break
        }

        if ($waited.Elapsed.TotalSeconds -ge $NetworkTimeoutSecond) {

            # A MACHINE WITH NO ADDRESS IS WHAT THE WELCOME SCREEN IS FOR, and
            # ploughing on to fail at the share was the wrong answer: "a machine
            # whose network is wrong is the commonest reason a technician is
            # looking at this screen at all" (WPF-FIRST, W2). DHCP that never
            # answered is a static address somebody has to type.
            #
            # UNLESS THE IMAGE SAID NOT TO ASK. HDTSkipWelcome - or an image
            # built without -PromptForCredential, which is the same decision -
            # means nobody is standing here, and then the honest outcome is a
            # NAMED FAILURE rather than a connect that fails two steps later
            # describing a share instead of a network.
            $networkSkip = Get-HDTWizardSkip -Bootstrap $bootstrap

            if ($networkSkip.Welcome) {
                throw ("HDTNetworkError: no usable IPv4 address after {0}s and {1} attempt(s) - the addresses seen were '{2}'. This image skips the Welcome screen, so there is nobody to ask for a static address. Set one in the image, fix DHCP on this segment, or build with -PromptForCredential so the screen appears." -f
                    $NetworkTimeoutSecond, $attempt, (@($fact['HDTIPAddress']) -join ', '))
            }

            & $say ("no usable IPv4 address after {0}s and {1} attempt(s); asking the technician." -f
                $NetworkTimeoutSecond, $attempt) 'Warning'

            $welcome = & $showWelcome
            if (-not $welcome.Retry) {
                throw 'HDTDeploymentCancelled: the technician left the Welcome screen without setting a network.'
            }

            # Round again with whatever they typed - a static address applies
            # immediately, so the next poll is the honest test of it.
            $waited.Restart()
            $attempt = 0
            continue
        }

        # IT SAYS WHAT IT IS WAITING FOR. This used to read "waiting for an
        # address" while printing the address the machine already had, which is
        # how the bug above stayed invisible in a log somebody had read.
        & $say ("no usable IPv4 address yet, attempt {0}; the adapter reports '{1}'" -f
            $attempt, (@($fact['HDTIPAddress']) -join ', ')) 'Debug'
        $clock.Sleep(5000)
    }

    # -- 7. WHICH DRIVE IS THE CONTENT ON ------------------------------------
    #
    # THE ONLY REASON THIS FILE IS ALLOWED ANYWHERE NEAR A DRIVE LETTER, and it
    # still writes none: the volumes are enumerated off the machine and the
    # decision is Resolve-HDTDeployRoot's (SPIKES S9.1).

    $candidateRoot = [string[]] @([System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and @('Fixed', 'Removable') -contains [string] $_.DriveType } |
            ForEach-Object { [string] $_.RootDirectory.FullName })

    $result['candidateRoot'] = $candidateRoot

    $deployRoot = Resolve-HDTDeployRoot -DeployRoot ([string] $bootstrap.DeployRoot) `
        -Provider ([string] $bootstrap.Provider) -CandidateRoot $candidateRoot `
        -Marker ([string] $bootstrap.ContentMarker) -FileSystem $fileSystem

    $result['resolvedDeployRoot'] = [string] $deployRoot.Path
    $result['deployRootSource'] = [string] $deployRoot.Source

    # WHEN THIS GOES WRONG ON A MACHINE NOBODY IS WATCHING, THIS LOG LINE IS THE
    # WHOLE INVESTIGATION.
    & $say ("deploy root '{0}' ({1}); the volumes considered were: {2}" -f
        $deployRoot.Path, $deployRoot.Source, ((@($candidateRoot) -join ', ')))

    # -- 8. the credential ---------------------------------------------------

    $credential = $null
    if ([string] $bootstrap.Provider -eq 'Smb') {
        if ([bool] $bootstrap.PromptForCredential) {
            # THE ONE PATH IN THIS FILE THAT STOPS FOR A HUMAN, and it says so.
            # DESIGN 6.3 offers that build for a shared lab or for media going
            # offsite; the E2E never uses it.
            Write-Warning 'This boot image was built with promptForCredential, so it DELIBERATELY STOPS FOR A HUMAN: the deployment waits here until somebody types the deployment account and its password (DESIGN 6.3). An image meant to run with nobody present carries an embedded credential instead.'
            & $say 'prompting for the deployment credential - this image deliberately stops for a human' 'Warning'

            $credential = Get-Credential -Message 'The HDT deployment account for the content share'
        } else {
            $credential = $bootstrap.GetCredential()
            & $say ("using the embedded deployment account '{0}'" -f $bootstrap.UserName)
        }
    }

    # -- 9. the provider -----------------------------------------------------

    $providerArgument = @{
        Provider   = [string] $bootstrap.Provider
        Root       = [string] $deployRoot.Path
        FileSystem = $fileSystem
    }
    if ($null -ne $credential) { $providerArgument['Credential'] = $credential }

    $content = New-HDTContentProvider @providerArgument

    [void] $content.Connect()
    $result['connected'] = $true
    & $say ("connected to '{0}' over {1}" -f $deployRoot.Path, $bootstrap.Provider)

    # -- 10. facts, override, rules, resolution, sequence --------------------

    $workspaceRoot = [string] $deployRoot.Path

    & $say ("machine: model '{0}', UEFI {1}, memory {2} MB, UUID {3}" -f
        [string] $fact['HDTModel'], [string] $fact['HDTIsUEFI'],
        [string] $fact['HDTMemory'], [string] $fact['HDTUUID'])

    # DESIGN 3.1's SECOND SOURCE, keyed on the machine's UUID. 04-04 proved it is
    # what makes one machine an exception without editing rules.yaml - and what
    # stops a rules-derived computer name Windows Setup would silently discard.
    $override = Get-HDTMachineOverride -WorkspaceRoot $workspaceRoot `
        -Uuid ([string] $fact['HDTUUID']) -FileSystem $fileSystem

    $rulePath = [System.IO.Path]::Combine($workspaceRoot, [string] $bootstrap.ContentMarker)
    $ruleDocument = $null
    if ($fileSystem.TestPath($rulePath)) {
        $ruleDocument = Import-HDTRuleDocument -Path $rulePath -FileSystem $fileSystem
        & $say ("{0}: {1} rule(s)" -f $bootstrap.ContentMarker, @($ruleDocument.Rule).Count)
    } else {
        & $say ("no '{0}' at the deploy root; the resolution runs on facts and defaults alone" -f $bootstrap.ContentMarker) 'Warning'
    }

    $scriptInvoker = New-HDTScriptInvoker -Root $workspaceRoot

    $resolveArgument = @{
        RuleDocument  = $ruleDocument
        Fact          = $fact
        ScriptInvoker = $scriptInvoker
    }
    if ($null -ne $override) {
        $resolveArgument['MachineOverride'] = $override.Variable
        $resolveArgument['MachineOverridePath'] = [string] $override.Path

        & $say ("machine override: {0}" -f $override.Path)
    } else {
        & $say ("no machine override for UUID {0}" -f [string] $fact['HDTUUID'])
    }

    $resolved = Resolve-HDTVariable @resolveArgument

    # -- 10a. the technician wizard, IF THIS SHARE DECLARES ONE ---------------
    #
    # MDT'S ORDER, AND FOR MDT'S REASON: connect, gather, rules, THEN ask. The
    # wizard exists to collect what the rules could not supply, so it has to run
    # after them - and its answers outrank them, because a technician standing
    # at the machine outranks a guess (DESIGN 3.1).
    #
    # A SHARE WITH NO Scripts\UI\wizard.yaml HAS NO WIZARD, and that is what
    # keeps every image built before this existed deploying with nobody present.
    # Nothing here waits for a human who is not there: no definition, no pages
    # left to ask, or HDTSkipWizard set - and this whole block is a few
    # milliseconds of file test.
    #
    # THE ANSWERS ARE RE-RESOLVED RATHER THAN PATCHED IN. Resolve-HDTVariable is
    # pure, so running it again with -Wizard is how the precedence in DESIGN 3.1
    # actually applies - a typed name beats the rule that guessed one, a rule
    # still wins where the technician left a box empty, and the provenance says
    # which happened.
    $wizardValue = @{}

    $wizard = Import-HDTWizardDocument -Provider $content

    if ($null -eq $wizard) {
        & $say 'no Scripts\UI\wizard.yaml on this share; nothing is asked and nothing waits.'
    } else {
        $ask = Get-HDTWizardPage -Page $wizard.Page -Variable $resolved.Variable

        & $say ("wizard: {0} page(s) to ask, {1} skipped" -f @($ask.Page).Count, @($ask.Skipped).Count)

        foreach ($skipped in @($ask.Skipped)) {
            & $say ("  {0} skipped by {1}" -f $skipped.Id, $skipped.Rule)
        }

        if ($ask.IsWizardNeeded) {

            # THE CONSOLE GOES AWAY AND COMES BACK IN A finally. WinPE boots
            # into cmd.exe running startnet.cmd, and that black window sits
            # behind everything. Hidden is a presentation choice, never a place
            # to get stuck: a hidden console plus a wizard that then throws
            # leaves a technician staring at nothing.
            $consoleHidden = $false

            try {
                $consoleHidden = [bool] (Hide-HDTShellWindow)

                # WHAT GOES IN THE BOXES, worked out by the command that owns
                # that question. A network read that fails leaves the boxes
                # empty and the wizard still opens - a machine with no lease is
                # exactly when a technician needs the screen.
                $network = $null
                try {
                    $network = Get-HDTNetworkConfiguration
                } catch {
                    & $say ("no network configuration could be read for the wizard: {0}" -f $_.Exception.Message)
                }

                $field = @(Get-HDTWizardField -NetworkConfiguration $network -Bootstrap $bootstrap)

                $answer = Show-HDTWizardShell -ShellXamlPath $WizardShellPath -ThemeXamlPath $WizardThemePath `
                    -Page $ask.Page -Title $wizard.Title -Field $field

                $result['wizardAction'] = [string] $answer.Action
                & $say ("the technician chose: {0}" -f $answer.Action)

                # MDT'S "EXIT TO COMMAND PROMPT": the window closes and the
                # technician is left AT a prompt. Opening it is this caller's
                # job - Show-HDTWizardShell reports and opens nothing.
                if ($answer.Action -eq 'CommandPrompt') {
                    $prompt = Start-HDTCommandPrompt
                    & $say ("command prompt: started {0} ({1})" -f $prompt.Started, $prompt.FilePath)

                    throw 'HDTDeploymentCancelled: the technician asked for a command prompt instead of a deployment.'
                }

                # A DISMISSED WIZARD IS NOT CONSENT TO PARTITION A DISK.
                if ($answer.Action -ne 'Next') {
                    throw 'HDTDeploymentCancelled: the technician cancelled the wizard.'
                }

                $wizardValue = $answer.Value
                & $say ("the wizard supplied {0} value(s): {1}" -f
                    @($wizardValue.Keys).Count, ((@($wizardValue.Keys) | Sort-Object) -join ', '))
            } finally {
                if ($consoleHidden) { [void] (Hide-HDTShellWindow -Restore) }
            }
        }
    }

    if (@($wizardValue.Keys).Count -gt 0) {
        $resolveArgument['Wizard'] = $wizardValue
        $resolved = Resolve-HDTVariable @resolveArgument
    }

    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($resolved.Variable.Keys)) {
        $variable[[string] $name] = $resolved.Variable[$name]
    }

    # WHICH SEQUENCE: the command line, else the boot image, else the rules.
    # None of the three set is a NAMED FAILURE, not a guess.
    $wantedSequence = $SequenceId
    if ([string]::IsNullOrWhiteSpace($wantedSequence)) { $wantedSequence = [string] $bootstrap.SequenceId }
    if ([string]::IsNullOrWhiteSpace($wantedSequence)) { $wantedSequence = [string] $variable['HDTTaskSequenceID'] }

    if ([string]::IsNullOrWhiteSpace($wantedSequence)) {
        throw ("HDTConfigurationError: no task sequence was named. -SequenceId was not given, bootstrap.json at '{0}' carries an empty sequenceId, and nothing in the rules resolved HDTTaskSequenceID for this machine (DESIGN 3)." -f $BootstrapPath)
    }

    $result['sequenceId'] = $wantedSequence

    $sequencePath = Get-HDTWorkspacePath -Root $workspaceRoot -Kind TaskSequences `
        -ChildPath $wantedSequence, 'sequence.yaml'

    $sequence = Import-HDTSequenceDocument -Path $sequencePath -FileSystem $fileSystem
    & $say ("sequence '{0}': {1} step(s)" -f $sequence.Id, @($sequence.Step).Count)

    # DESIGN 3.1's LOWEST SOURCE, applied last and only where nothing else spoke.
    # The sequence has to be read AFTER the resolution here, because the rules
    # are one of the three places its id can come from - so its own defaults are
    # merged rather than passed in, which is the same precedence by another
    # route.
    $applied = New-Object -TypeName System.Collections.ArrayList
    foreach ($name in @($sequence.Variable.Keys)) {
        if (-not $variable.Contains([string] $name)) {
            $variable[[string] $name] = $sequence.Variable[$name]
            [void] $applied.Add([string] $name)
        }
    }
    if ($applied.Count -gt 0) {
        & $say ("sequence defaults applied to {0} name(s) nothing else supplied: {1}" -f
            $applied.Count, (@($applied) -join ', '))
    }

    $result['computerName'] = [string] $variable['HDTComputerName']
    & $say ("HDTComputerName resolved to '{0}'" -f $result['computerName'])

    # -- 10b. the progress window --------------------------------------------
    #
    # DESIGN 11.1. It goes up before the engine starts and comes down in the
    # tail, so a technician sees what the machine is doing from the first step
    # rather than a black X:\Windows\system32> prompt with a cursor on it.
    #
    # THREE OUTCOMES AND NONE OF THEM STOPS A DEPLOYMENT: a window, styled
    # console lines when this machine cannot draw one, or nothing at all when
    # HDTSkipProgress said so. Start-HDTProgressDisplay hands back a host either
    # way, so the engine reports progress the same on every machine.
    $display = Start-HDTProgressDisplay -XamlPath $ProgressXamlPath -Variable $variable

    $result['progressMode'] = [string] $display.Mode
    & $say ("progress display: {0} {1}" -f $display.Mode, $display.Reason)

    if ($display.Mode -ne 'Suppressed') {
        # NOT IN THE EVENT STREAM. Every other value on that screen is derived
        # from the log; the machine's own name is a variable, and this is the
        # only place that has it.
        $display.DisplayHost.SetComputerName([string] $variable['HDTComputerName'])
    }

    # -- 11. the context -----------------------------------------------------

    $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
        -Lsa $lsa -Process $processService -Power $power -ScriptInvoker $scriptInvoker -Cim $cim `
        -Environment $environment -Disk $diskService -Image $imageService -Content $content `
        -Progress $display.DisplayHost

    $state = New-HDTRunState -SequenceId $sequence.Id -RunId $runId -Phase WinPE `
        -Clock $clock -Variable $variable -Step $sequence.Step

    $context = New-HDTExecutionContext -RunId $runId -Phase WinPE -WorkspaceRoot $workspaceRoot `
        -Variable $variable -Service $catalog -Log $log -State $state

    # -- 12. ONE call to the engine ------------------------------------------

    # -LogDestination IS THE LOG ROOT, NOT THE RUN FOLDER: Copy-HDTLog appends
    # <ComputerName>-<RunId> itself.
    $logDestination = Get-HDTWorkspacePath -Root $workspaceRoot -Kind Logs
    $result['logDestination'] = $logDestination

    & $say 'running the task sequence'

    $run = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state `
        -StatePath ([System.IO.Path]::Combine($logDirectory, 'state.json')) `
        -LogDestination $logDestination

    $result['status'] = [string] $run.Status
    & $say ("sequence finished: {0}" -f $run.Status)

    foreach ($step in @($run.Result)) {
        & $say ("  step {0} {1}: {2}" -f $step.Index, $step.Name, $step.Status)

        if ([string] $step.Status -eq 'Failed' -and [string]::IsNullOrEmpty([string] $result['failedStep'])) {
            $result['failedStep'] = [string] $step.Name
            $result['message'] = [string] $step.Message
        }
    }
} catch {
    $result['status'] = 'Failed'
    $result['message'] = [string] $_.Exception.Message

    & $say ("FATAL: {0}" -f $_.Exception.Message) 'Error'
    & $say ([string] ($_ | Out-String)) 'Debug'
}

# -- 13. the tail: evidence, then the power state ----------------------------
#
# ALL OF IT AFTER THE CATCH, NEVER INSIDE THE TRY. A run that died before the
# loop never reached the loop's own copy-back, and that run is precisely the one
# whose log is wanted.

# THE PROGRESS WINDOW COMES DOWN HERE, AFTER THE CATCH, for the same reason
# everything else in this block is here: a run that died is exactly the run
# whose screen must not be left up over a machine that is about to power off.
# It is full-screen and has no way out of it, so a payload that returned without
# this would leave a technician looking at a frozen status board.
if ($null -ne $display -and $display.Mode -ne 'Suppressed') {
    $display.DisplayHost.Close()
}

$result['elapsedSecond'] = [int] $started.Elapsed.TotalSeconds

if ($null -ne $log) {
    $result['logPath'] = [string] $log.LogPath
}

# WHAT THE MACHINE DOES NEXT, decided before it is recorded, so RESULT.json can
# say which one it was. ROADMAP M2 left "does WinPE need wpeutil reboot rather
# than shutdown.exe" open; this is the first run that can answer it.
$ending = 'shutdown'
if ([string] $result['status'] -eq 'RebootPending') {
    $ending = 'reboot'
}
$result['endedWith'] = 'wpeutil {0}' -f $ending

# UTF-8 WITHOUT A BOM, EXPLICITLY. SPIKES S6's third finding: the default under
# 5.1 is UTF-16, which half the tooling cannot read.
$utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$document = ConvertTo-Json -InputObject $result -Depth 4

# THE PRIMARY DESTINATION IS THE DEPLOY ROOT, AND THE FALLBACK IS THE RAM DISK,
# in that order and not the other way round. X: does not survive the power-off
# this script is about to perform, so a result written only there is a result
# nobody will ever read - and 05-05's whole zero-keystroke proof reads this file.
$written = @()

if (-not [string]::IsNullOrWhiteSpace([string] $result['resolvedDeployRoot'])) {
    try {
        $destination = Get-HDTWorkspacePath -Root ([string] $result['resolvedDeployRoot']) -Kind Logs

        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            New-Item -Path $destination -ItemType Directory -Force | Out-Null
        }

        # AT THE ROOT OF THE LOG FOLDER, one file, whatever happened: a run that
        # died before the resolution has no computer name to nest under, and
        # whoever comes looking must always know where to look.
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($destination, 'RESULT.json'), $document, $utf8)
        [System.IO.File]::WriteAllLines([System.IO.Path]::Combine($destination, 'LAUNCHER.log'),
            [string[]] @($transcript), $utf8)

        $written += $destination
    } catch {
        Write-Information ("could not write RESULT.json to the deploy root: {0}" -f $_.Exception.Message)
    }
} else {
    [void] $transcript.Add('no deploy root was resolved, so X:\HDT\RESULT.json is the only copy and it dies with the RAM disk')
    $result['message'] = ('{0} (no deploy root was resolved, so this result exists only on the RAM disk)' -f $result['message']).Trim()
    $document = ConvertTo-Json -InputObject $result -Depth 4
}

try {
    New-Item -Path 'X:\HDT' -ItemType Directory -Force | Out-Null
    [System.IO.File]::WriteAllText('X:\HDT\RESULT.json', $document, $utf8)
    [System.IO.File]::WriteAllLines('X:\HDT\LAUNCHER.log', [string[]] @($transcript), $utf8)
} catch {
    Write-Information ("could not write the fallback RESULT.json: {0}" -f $_.Exception.Message)
}

# THE COPY-BACK, AGAIN AND UNCONDITIONALLY. The loop already did it when it got
# that far; this is for the runs that did not.
if ($null -ne $log -and -not [string]::IsNullOrWhiteSpace([string] $result['logDestination'])) {
    try {
        $copyArgument = @{ Context = $log; Destination = [string] $result['logDestination'] }
        if (-not [string]::IsNullOrWhiteSpace([string] $result['computerName'])) {
            $copyArgument['ComputerName'] = [string] $result['computerName']
        }

        Copy-HDTLog @copyArgument | Out-Null
    } catch {
        Write-Information ("could not copy the deployment logs: {0}" -f $_.Exception.Message)
    }
}

if ($null -ne $content) {
    try {
        $content.Disconnect()
    } catch {
        Write-Information ("could not disconnect the content provider: {0}" -f $_.Exception.Message)
    }
}

Write-Information ("HDT run {0} ended {1} in {2}s; {3}" -f
    $runId, $result['status'], $result['elapsedSecond'], $result['endedWith'])

Start-Sleep -Seconds 5

# HOW THIS MACHINE ENDS, IN EVERY PATH INCLUDING THE ONES WHERE IT FAILED BEFORE
# IT STARTED. RebootPending means the deployment wants the machine back; anything
# else means it is finished with it.
& "$env:SystemRoot\System32\wpeutil.exe" $ending

exit 0
