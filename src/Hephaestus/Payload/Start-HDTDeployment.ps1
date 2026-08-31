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
        asserts that too. A lab test measured WinPE handing the CONTENT DISK
        the letter a developer's machine calls its system drive, and the RAM disk
        X:. A deployRoot baked into bootstrap.json at build time therefore cannot
        know what this machine will be given - so the volume carrying the content
        is DISCOVERED, by enumerating the drives this machine actually has and
        handing them to Resolve-HDTDeployRoot. Phase 04's stand-in scanned a
        hard-coded run of letters; this one may not.

        POWERSHELL-YAML IS IMPORTED FIRST, and its version is logged.
        ConvertFrom-HDTYaml imports it lazily and reports HDTDependencyError
        without it, so the engine cannot read one YAML document - not a sequence,
        not a rule, not an image catalog - until that import has happened. A lab
        test proved it loads inside WinPE from a staged copy; the log line is how
        the next run proves it again.

        IT ENDS THE MACHINE IN EVERY PATH, because a VM left at a WinPE prompt
        tells nobody anything except that somebody's timeout expired. And it
        writes RESULT.json to the deploy root's Logs folder BEFORE it does -
        X:\HDT\RESULT.json is a fallback and not the record, because X: is a RAM
        disk and the machine is about to power off. 05-05's zero-keystroke proof
        reads launchedBy out of that file.

        THE TECHNICIAN UI IS HERE NOW, AND IT STILL RUNS UNATTENDED. This header
        used to say the UI was deliberately absent because it was a later
        milestone. That milestone arrived: the Welcome screen appears when this
        machine has no network, and the wizard appears when the SHARE declares
        pages in Scripts\UI\wizard.yaml. A share that declares none has no
        wizard, so every image built before this deploys with nobody present
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

# The share password a bootstrap rule chose arrives as text, because
# bootstrap-rules.yaml is a document inside the boot image and MDT's
# Bootstrap.ini carried UserPassword the same way. PSCredential requires a
# SecureString, so the conversion happens at the last possible moment rather
# than the file pretending the value was ever secret - anybody holding the
# image already holds the credential baked into it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The share password comes from bootstrap-rules.yaml inside the boot image, as MDT Bootstrap.ini UserPassword did. PSCredential requires a SecureString; the value was never protected and this does not pretend otherwise. The control is the one DESIGN 14 names - treat the boot media as a credential.')]
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $BootstrapPath = 'X:\HDT\bootstrap.json',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ModuleRoot = 'X:\HDT\Modules',

    # HOW MANY TIMES THE SHARE IS TRIED BEFORE ANYBODY IS ASKED OR ANYTHING IS
    # REPORTED. WinPE has just brought a network up when the first attempt
    # happens, which makes it the least likely one to succeed - and until this
    # existed it was the only one there was. Measured in this lab: one transient
    # failure left a machine at the Welcome screen for two hours and forty-five
    # minutes, on a host that was up the whole time.
    [Parameter()]
    [ValidateRange(1, 60)]
    [int] $ConnectAttempt = 5,

    # HOW LONG TO WAIT FOR THE NETWORK TO CARRY TRAFFIC once the machine holds
    # an address. Those are two different moments: on a Latitude into a real
    # switch there is roughly fifteen seconds between them, during which every
    # SMB attempt returns "The network path was not found" - which reads like a
    # wrong address and is not one.
    #
    # 60 RATHER THAN THE 20 THE RETRIES COVERED. A switch port that is learning,
    # or a link still negotiating, is routinely slower than five attempts with a
    # doubling back-off. Waiting costs a machine that is already up nothing: the
    # first ping answers and this returns immediately.
    [Parameter()]
    [ValidateRange(0, 600)]
    [int] $LinkTimeoutSecond = 60,

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

    # THE SCREEN A FAILED MACHINE SHOWS. In the image rather than on the share
    # for the same reason the others are: a run that never reached the share is
    # exactly the run that needs it.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $FailureXamlPath = 'X:\HDT\UI\HDTFailure.xaml',

    # THE ONE SCREEN THAT RUNS BEFORE THE SHARE IS REACHABLE, so it cannot live
    # on the share with the others (DESIGN 11.2's correction).
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WelcomeXamlPath = 'X:\HDT\UI\HDTWelcome.xaml',

    # AND THE ONE THAT RUNS BEFORE ANY OF THEM. The transparent panel that
    # replaces the WinPE console between startnet.cmd and the first real window
    # - see step 4a for why there has to be one.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $BootStatusXamlPath = 'X:\HDT\UI\HDTBootStatus.xaml'
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

# DECLARED HERE BECAUSE THE TAIL READS IT, and the tail runs after a failure.
# FOUND ON A LIVE MACHINE: the wizard threw, the catch recorded it, and then the
# tail added a second error of its own -
#
#     The variable '$display' cannot be retrieved because it has not been set.
#
# - because step 10b, which assigns it, is inside the try the run never finished.
# Under Set-StrictMode even `$null -ne $display` throws. The tail is the part
# that writes RESULT.json, so the run whose evidence matters most was the one
# that lost it.
$display = $null

# WHETHER ANYBODY IS STANDING AT THIS MACHINE, and $display is not the answer.
# It is created with the PROGRESS window, which opens after the wizard - so a
# run that died in the wizard had $display still $null, the failure screen was
# skipped for "nobody is watching", and wpeutil powered the machine off five
# seconds later with the exception unread. That is exactly the run somebody was
# standing at: they had just clicked Next.
#
# The wizard and the Welcome screen are windows too, and either one having been
# drawn is proof a human is here.
$windowShown = $false

# WHETHER THIS PAYLOAD HID THE WinPE CONSOLE, declared out here for the same
# reason $display is: the tail restores it, and the tail runs after a failure.
$shellHidden = $false

# THE BOOT STATUS OVERLAY, AND $say WRITES TO IT. Declared before $say for that
# reason, and read by the tail, which runs after a failure. Null until step 4a
# opens one, and null again once the progress window has taken the screen over.
$status = $null

# One sentence, to the console and to LAUNCHER.log, and - once there is a log
# context - to the engine's own stream as well. Step 5's failure is logged
# rather than printed and lost precisely because step 4 built that context
# first.
# ONE WINDOW AT A TIME, AND FOUR ATTEMPTS ON A BOOTED VM ARE WHY THAT IS A RULE
# RATHER THAN A PREFERENCE.
#
# THE MEASUREMENT. The panel is a transparent WPF window. WinPE runs no desktop
# compositor, so when a transparent window repaints, its pixels go to the screen
# WITHOUT BEING CLIPPED by whatever sits above it - and its lines were drawn
# across the Welcome screen's share box and credential fields. Pushing it to the
# bottom of the z-order with SetWindowPos(HWND_BOTTOM) did not help, and could
# not: z-order is not what is being violated. Two frames proved it - an OPAQUE
# cmd.exe window covered the panel completely, while the Welcome screen, opened
# before the panel's next repaint, was bled through the moment it repainted.
#
# WHAT DID NOT WORK, IN ORDER, EACH FIX BUYING THE NEXT DEFECT:
#
#   close it before each window     the only thing reporting anything was gone,
#                                   so pressing Next gave five share connection
#                                   attempts on a blank wallpaper
#   hide it instead                 the window was modal, and hiding a
#                                   ShowDialog window MAKES ShowDialog RETURN -
#                                   the panel was destroyed and never came back
#   push it to the bottom           z-order was never the problem
#
# SO THE PANEL EXISTS ONLY WHILE NOTHING ELSE DOES. It is closed before a window
# opens and OPENED AGAIN once that window has gone, which is what a technician
# who presses Next needs: the five connection attempts are the whole reason they
# are standing there.
#
# THE HISTORY IS REPLAYED, so reopening is not starting again. $transcript is
# every line this payload has said; the new window is seeded with the last of
# them and a technician reads one continuous account rather than a panel that
# forgets whenever a screen was shown.
$closeStatus = {
    if ($null -eq $status) { return }

    $status.StatusHost.Close()
    $script:status = $null
}

# HOW MANY LINES OF HISTORY A REOPENED PANEL IS GIVEN. The window keeps twelve;
# handing it more would just be lines it drops on the way in.
$statusReplay = 12

$openStatus = {

    # ALREADY OPEN IS NOT AN ERROR. Two windows in a row - the Welcome screen and
    # then the wizard - would otherwise open a second runspace and orphan the
    # first.
    if ($null -ne $status) { return }

    $script:status = Start-HDTBootStatus -XamlPath $BootStatusXamlPath -FileSystem $fileSystem

    $history = @($transcript)
    if ($history.Count -gt $statusReplay) {
        $history = @($history[($history.Count - $statusReplay)..($history.Count - 1)])
    }

    foreach ($line in $history) { $script:status.StatusHost.Write([string] $line) }
}

$say = {
    param([string] $Message, [string] $Severity = 'Info')

    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    [void] $transcript.Add($line)
    Write-Information $line

    # THE OVERLAY GETS THE SAME SENTENCE, and there is no branch on its Mode:
    # Start-HDTBootStatus hands back a host either way and the console one
    # writes nothing, because Write-Information above already did.
    if ($null -ne $status) { $status.StatusHost.Write($line) }

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

    # THE TWO ENDS OF THE RUN, IN UTC. deploymentStart is what the sequence saw
    # as HDTDeploymentStart; deploymentEnd is the true final value, stamped
    # after the last step, which no step could have read.
    deploymentStart    = ''
    deploymentEnd      = ''
    logPath            = ''
    logDestination     = ''

    # WHERE THE LOGS ACTUALLY LANDED, which is not the same question as where
    # they were meant to. Empty means the copy-back did not happen or did not
    # work, and RESULT.json is where somebody reading a failed run finds that
    # out - rather than looking for a log on a share it never reached.
    logCopyBack        = ''

    # HDTFinishAction, AS RESOLVED, and initialised here for the reason every
    # field in this hashtable is: the tail runs after a failure and may only
    # read what a failed run has. A run that died before the rules resolved
    # never had a $variable dictionary at all.
    finishAction       = ''

    # HDTSLShare, DeployRoot, or None - so a run that put its logs somewhere
    # unexpected says which rule sent them there.
    logDestinationSource = ''
    endedWith          = ''

    # THE ONE FIELD THAT STOPS THIS SCRIPT POWERING THE MACHINE OFF. A
    # technician who pressed Open CMD is standing in front of the machine with
    # something to look at, and the tail must leave it running for them.
    leftAtCommandPrompt = $false

    # WHICH BUTTON THE TECHNICIAN PRESSED ON THE FAILURE SCREEN, or empty when
    # there was nobody there to press one.
    failureScreen      = ''

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

    # -- 3a. IS A TASK SEQUENCE ALREADY RUNNING ON THIS MACHINE? -------------
    #
    # THE QUESTION THIS FILE NEVER ASKED, AND THE DISK IT COST.
    #
    # Every WinPE boot used to mint a NEW run at step 1. That is right for every
    # boot but one: the boot a reference build does AFTER SYSPREP, when it comes
    # back into WinPE to capture itself (reference.yaml, DESIGN 9.3). On that
    # boot the old behaviour reached the sequence's own DiskPartition step and
    # would have formatted the volume it had just generalized - and nothing
    # about it would have looked wrong, because a machine deploying is what a
    # machine deploying looks like.
    #
    # BEFORE THE LOG, SO THE LOG BELONGS TO THE RIGHT RUN. A resumed leg keeps
    # the run id that is already on the disk: minting a fresh one would split one
    # deployment into two runs in the log, and the monotonic seq that exists to
    # order them across a reboot would restart at 1 (DESIGN 4.4.2). So the
    # discovery runs here, with no log context of its own, and its decision is
    # written a few lines below once there is somewhere to write it.
    #
    # AND BEFORE EVERYTHING ELSE THAT COSTS ANYTHING - the network, the share,
    # the credential, the wizard. A resumed leg has a technician's answers
    # already, carried in the state document's variable bag; opening the wizard
    # again on the capture boot would stop a reference build dead waiting for
    # somebody who went home hours ago.
    $resume = Get-HDTResumeCandidate -Disk $diskService -FileSystem $fileSystem -Clock $clock

    # AMBIGUOUS STOPS THE DEPLOYMENT. It means "there may be a run in progress
    # and I cannot tell" - a half-written state document, two volumes carrying
    # one, a run gone stale, or a Storage stack that did not answer. The only
    # safe act is to refuse, because the alternative to stopping is minting a run
    # and reaching a partition step. A warning would be a warning printed onto a
    # screen nobody is watching while the disk is being formatted.
    #
    # THE MESSAGE IS THE DISCOVERY'S OWN, because it is the one that knows which
    # file it found - and the operator's way out is to delete that file, which is
    # an explicit act of consent in a way that "it started a new deployment"
    # never is.
    if ([string] $resume.Action -eq 'Ambiguous') {
        throw ("HDTStateAmbiguous: {0}" -f [string] $resume.Reason)
    }

    # NULL UNLESS THERE IS ONE, so every test below reads as "is this a resumed
    # leg" rather than comparing a string in six places.
    $resumedState = $null

    if ([string] $resume.Action -eq 'Resume') {
        $resumedState = $resume.State
        $runId = [string] $resume.State.runId
    }

    # -- 4. the log, before anything else can fail ---------------------------

    $logDirectory = $LogRoot
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Get-HDTLogPath -Phase WinPE
    }

    $fileSystem.CreateDirectory($logDirectory)

    $log = New-HDTLogContext -RunId $runId -Phase WinPE -LogPath $logDirectory `
        -FileSystem $fileSystem -Clock $clock -Level Debug

    # AND THE REGISTRY ADAPTER GETS IT, now that there is one to give. It is
    # built above, before any log exists, so it is told afterwards rather than at
    # construction. Without this every key it created, found, overwrote or found
    # already gone is a silent no-op - which is how a set that was really a
    # delete reached a log with nothing in it but the exception.
    $registry.LogContext = $log

    $result['logPath'] = $logDirectory

    & $say ("powershell-yaml {0} loaded from {1}" -f $yaml.Version, $yaml.ModuleBase)
    & $say ("Hephaestus {0} loaded from {1}" -f $engine.Version, $engine.ModuleBase)
    & $say ("PowerShell {0}; launched by '{1}'" -f $PSVersionTable.PSVersion, $result['launchedBy'])

    # THE DECISION TAKEN ABOVE, RECORDED NOW THAT THERE IS SOMEWHERE TO RECORD
    # IT. Both answers are worth a line: "resuming" is the unusual one, and "no
    # run in progress" is the sentence that explains why this machine is about
    # to be partitioned.
    if ($null -ne $resumedState) {
        $result['resumed'] = $true

        & $say ("RESUMING a task sequence already in progress: {0}" -f [string] $resume.Reason) 'Warning'
        & $say ("this leg will not partition or re-image this machine; the steps that would are refused outright")
    } else {
        & $say ([string] $resume.Reason)
    }

    # -- 4a. the overlay goes up and the console goes away -------------------
    #
    # BECAUSE THE CONSOLE IS WHAT THE TECHNICIAN IS LOOKING AT INSTEAD OF THE
    # SCREEN THIS TOOLKIT BUILT. WinPE boots into cmd.exe running startnet.cmd
    # and that black full-screen window covers the desktop for as long as it is
    # up. A BGInfo start command - the machine's serial, model and address on
    # the wallpaper, which is why an administrator puts one in the image at all
    # - paints BEHIND it, so nothing was visible until this payload hid the
    # console for the wizard, minutes later. MDT has no console to hide:
    # winpeshl.ini makes LiteTouch.wsf the shell, so its BGInfo is on screen
    # from the first second. This is that, without replacing the shell.
    #
    # THE OVERLAY OPENS FIRST AND THE CONSOLE GOES ONLY IF IT DREW, and that
    # order is the whole safety of this. Hiding the console leaves a technician
    # with whatever is on screen instead - and on a boot image built without
    # WinPE-NetFx there is no WPF, so 'instead' would be an empty wallpaper for
    # the twenty seconds before a Welcome screen that also cannot be drawn.
    # Start-HDTBootStatus reports Console for exactly that machine, this leaves
    # the console alone, and $say keeps writing to it.
    #
    # AFTER THE LOG CONTEXT, NOT AT THE TOP OF THE FILE. The two failures that
    # cannot be logged - powershell-yaml or Hephaestus refusing to import, and
    # a log directory that cannot be created - happen above this line and must
    # still leave their message on a console somebody can read. Everything
    # below here is logged, the overlay repeats it on the wallpaper, and step 13
    # puts the console back before the machine ends.
    $status = Start-HDTBootStatus -XamlPath $BootStatusXamlPath -FileSystem $fileSystem

    if ($status.Mode -eq 'Window') {
        $shellHidden = [bool] (Hide-HDTShellWindow)
    }

    $result['bootStatusMode'] = [string] $status.Mode
    & $say ("boot status: {0} {1}; the WinPE console was hidden: {2}" -f
        $status.Mode, $status.Reason, $shellHidden)

    # -- 5. the bootstrap document -------------------------------------------

    $bootstrap = Get-HDTBootstrapConfiguration -Path $BootstrapPath -FileSystem $fileSystem

    # -- 5a. AND THE LEVEL THE SHARE ASKED FOR ------------------------------
    #
    # DESIGN 4.4.5 makes LogLevel a setting in workspace.yaml, Update-HDTBootImage
    # writes it into bootstrap.json, and Get-HDTBootstrapConfiguration has parsed
    # it since the file existed - and NOTHING HAS EVER READ IT. The context above
    # is built at Debug and stayed there, so a share that said logLevel: Info got
    # Debug anyway and the setting meant nothing on either leg.
    #
    # SET HERE RATHER THAN AT CONSTRUCTION, because the context is deliberately
    # built before the first thing that can fail (step 4's comment) and the
    # bootstrap document is one of the things that can. Debug is the right floor
    # for those few records: the window this cannot cover is the window where the
    # log is all there is.
    #
    # AND IT IS THIS VALUE THAT REACHES THE SECOND LEG. Invoke-HDTTaskSequence
    # copies $log.Level into state.json at every checkpoint, which is what
    # Start-HDTResume.ps1 reads back - the share is not reachable at the moment
    # the resumed leg needs an answer.
    $log.Level = [string] $bootstrap.LogLevel

    $result['logLevel'] = [string] $log.Level

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
    #
    # AND IT RETURNS THE SHARE AND THE ACCOUNT, because harvesting a value is
    # not consuming it. Get-HDTWizardHarvest reads nine controls off this
    # window; for a long time one of them was ever looked at again, so a
    # technician told their credential was rejected could retype it, press Next,
    # and watch the retry reconnect with the rejected one. See the two blocks at
    # the end of this closure.
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
            # THE PANEL GOES FIRST. A transparent window and this screen cannot
            # share a display in WinPE - see the header above $closeStatus.
            & $closeStatus

            # ONLY IF STEP 4a DID NOT ALREADY. Hiding twice is harmless; the
            # RESTORE below is not, because it would put the console back over
            # the wallpaper in the middle of a run that meant to keep it away.
            if (-not $shellHidden) { $hidden = [bool] (Hide-HDTShellWindow) }

            # THE SAME THEME THE WIZARD PAGES GET. This screen used to carry its
            # own copy of every style and was the one window a palette change
            # could not reach; it asks for the theme now like everything else.
            $answer = Show-HDTWizard -XamlPath $WelcomeXamlPath -ThemeXamlPath $WizardThemePath `
                -Title 'Hephaestus Deployment Toolkit' `
                -Field $field -Pane $skip.Pane -Collect (Get-HDTWizardHarvest)
        } finally {
            if ($hidden) { [void] (Hide-HDTShellWindow -Restore) }

            # AND BACK, BECAUSE Next IS NOT THE END OF THE STORY. What follows
            # this screen is a poll for an address and up to five attempts at the
            # share, and those attempts are what the technician came to watch. In
            # the finally, so a screen that threw still leaves the machine with
            # something that reports.
            & $openStatus
        }

        # THE SAME SHAPE FROM EVERY EXIT, so a caller reading .Credential or
        # .DeployRoot under Set-StrictMode gets an answer rather than an
        # exception on the one path where the screen did not come back.
        if ($null -eq $answer) {
            return [pscustomobject] @{ Retry = $false; DeployRoot = ''; Credential = $null }
        }

        & $say ("the Welcome screen answered: {0}" -f $answer.Action)

        if ($answer.Action -eq 'CommandPrompt') {
            $prompt = Start-HDTCommandPrompt
            & $say ("command prompt: started {0} ({1})" -f $prompt.Started, $prompt.FilePath)

            # AND THE MACHINE STAYS ON. Recorded on $result rather than in a
            # variable because the tail reads $result and nothing else, and
            # because "why is this machine still running?" is a question
            # RESULT.json should answer.
            $result['leftAtCommandPrompt'] = $true

            return [pscustomobject] @{ Retry = $false; DeployRoot = ''; Credential = $null }
        }

        # WHAT WAS TYPED COMES BACK WITH THE ANSWER. Until Get-HDTWizardHarvest
        # existed this screen returned an Action alone, so a technician could
        # correct the share, press Next, and watch the machine fail on the
        # address that was already wrong.
        #
        # HARVESTING A VALUE IS NOT CONSUMING IT, and this screen proved that
        # twice more after the share box was fixed. Get-HDTWizardHarvest reads
        # NINE controls off the window; for a long time exactly one of them was
        # ever looked at again. Everything below is the other eight.
        $boxed = {
            param([string] $Name)

            # A NAME THE SCREEN DOES NOT CARRY IS AN ORDINARY ANSWER, not an
            # error - HDTSkipStaticIp hides the address pane outright, and the
            # host collects nothing for a control that is not there.
            if ($null -eq $answer.Value) { return '' }
            if (-not $answer.Value.ContainsKey($Name)) { return '' }

            return [string] $answer.Value[$Name]
        }

        $typed = & $boxed 'HDTDeployRootBox'

        # -- THE ADDRESS, ACTUALLY APPLIED ------------------------------------
        #
        # THE COMMENT AT THE TOP OF THIS CLOSURE HAS ALWAYS SAID a static
        # address "is applied through WMI (SPIKES S14) by Set-HDTStaticAddress",
        # and Set-HDTStaticAddress had no caller anywhere in the product. A
        # technician on a segment with no DHCP - which is the ONLY reason this
        # screen opens on the no-network path at all - filled in four boxes,
        # pressed Next, and the machine went back to polling for a lease that
        # was never coming, until the timeout brought the same screen back.
        #
        # ONLY WHEN THE RADIO SAYS SO. The address boxes come up holding the
        # lease the machine already has (Get-HDTWizardField), and a box showing
        # what it was prefilled with is not a request to nail that address down.
        # Get-HDTWizardHarvest says exactly this about HDTUseStaticRadio: it "is
        # what says whether any of the four below were meant at all".
        #
        # AND IT NEVER ENDS THE RUN. Set-HDTStaticAddress refuses a malformed
        # address by throwing - deliberately, so a typo cannot become a
        # different machine's address - and the honest response here is to say
        # so and let the caller show the screen again. Powering a machine off in
        # front of the person who is fixing it, over one wrong octet, is the
        # failure this whole screen exists to stop.
        $useStatic = $false
        if ($null -ne $answer.Value -and $answer.Value.ContainsKey('HDTUseStaticRadio')) {
            $useStatic = [bool] $answer.Value['HDTUseStaticRadio']
        }

        $typedAddress = & $boxed 'HDTIpAddressBox'
        $typedMask = & $boxed 'HDTSubnetMaskBox'

        if ($useStatic -and -not [string]::IsNullOrWhiteSpace($typedAddress) -and
            -not [string]::IsNullOrWhiteSpace($typedMask)) {

            try {
                [void] (Set-HDTStaticAddress -IPAddress $typedAddress -SubnetMask $typedMask `
                        -Gateway (& $boxed 'HDTGatewayBox') `
                        -DnsServer @(& $boxed 'HDTDnsBox') -CimProvider $cim)

                & $say ("static address {0} mask {1} gateway '{2}' applied through WMI" -f
                    $typedAddress, $typedMask, (& $boxed 'HDTGatewayBox'))
            } catch {
                & $say ("the static address could not be applied, so the machine keeps the network it had: {0}" -f
                    [string] $_.Exception.Message) 'Warning'
            }
        }

        # -- AND THE ACCOUNT, WHICH WAS THE HALF STILL BEING DISCARDED --------
        #
        # THE STORY THIS EXISTS FOR. A technician at a bench is told the share
        # refused the credential the boot image carries. The screen comes up
        # with the account boxes in front of them. They retype the password,
        # press Next, and watch THE SAME REFUSAL come back - because the retry
        # re-bound $providerArgument['Root'] and nothing else, so the only thing
        # that screen could ever fix was a wrong path. Then they do it again,
        # more carefully, and it fails again.
        #
        # WHICH IS THE DEFECT Get-HDTWizardHarvest'S OWN HELP SAYS IT WAS
        # WRITTEN TO END, one window over: a value read off a window and
        # dropped. It was, and then nobody read the bag.
        #
        # EMPTY MEANS KEEP WHAT THIS RUN ALREADY HAS - NEVER "CONNECT WITH
        # NOTHING". All three boxes are PREFILLED from the embedded account
        # (Get-HDTWizardField, and its comment on why the password is among
        # them), so blank is either a deliberate clearing or an image that
        # carries no account at all. In both cases the useful answer is the
        # credential the run was already using. The alternative turns a working
        # zero-touch image into an anonymous connect the moment somebody clears
        # a box - and DESIGN 6.3 refuses a guest session, so the failure would
        # arrive as a security refusal naming an account nobody chose. $null is
        # therefore "no change", and the loop leaves the credential alone.
        #
        # BOTH HALVES OR NEITHER. A user with no password cannot be composed
        # into a PSCredential at all, and half a typed credential is not a
        # better guess than the whole one already in hand.
        #
        # THE DOMAIN IS SPLIT BY Split-HDTAccountName AND NOT HERE. Technicians
        # type what they know - 'CORP\tech' into the user box as often as 'tech'
        # plus a domain box - and 'CORP\CORP\tech' is what re-parsing it by hand
        # produces on the second try.
        #
        # BLANK DOMAIN MEANS LOCAL, AND LOCAL IS SPELLED SERVER\user - the rule
        # Get-HDTWizardCredential documents, because a technician has to be able
        # to say "this account is LOCAL to that server" without knowing the
        # convention is to type a server name where a domain goes.
        #
        # THAT COMMAND IS NOT CALLED HERE, AND THE REASON IS ITS BEST FEATURE:
        # it CONNECTS to prove the account. Neither caller of this screen can
        # use that. The no-network caller has no network to connect over - it is
        # standing here precisely because there is no address - and the retry
        # caller connects on the very next pass anyway and reports what
        # happened. Composing without connecting is what is wanted; the proof
        # arrives four lines later either way.
        $credential = $null
        $typedUser = & $boxed 'HDTUserIdBox'
        $typedPassword = & $boxed 'HDTPasswordBox'

        if (-not [string]::IsNullOrWhiteSpace($typedUser) -and
            -not [string]::IsNullOrEmpty($typedPassword)) {

            $account = Split-HDTAccountName -Name $typedUser
            $domain = [string] $account.Domain

            if ([string]::IsNullOrWhiteSpace($domain)) { $domain = & $boxed 'HDTUserDomainBox' }

            # THE SERVER, WHEN NOTHING ELSE NAMED A DOMAIN: taken from the share
            # that was just typed, falling back to the one the image was built
            # with - because the share box may have been left alone.
            if ([string]::IsNullOrWhiteSpace($domain)) {
                $share = $typed
                if ([string]::IsNullOrWhiteSpace($share)) { $share = [string] $bootstrap.DeployRoot }

                if ($share.StartsWith('\\')) {
                    $segment = @($share.TrimStart('\').Split('\') | Where-Object { $_ })
                    if ($segment.Count -ge 1) { $domain = [string] $segment[0] }
                }
            }

            $composed = [string] $account.User
            if (-not [string]::IsNullOrWhiteSpace($domain)) {
                $composed = '{0}\{1}' -f $domain, $account.User
            }

            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                $composed,
                (ConvertTo-SecureString -String $typedPassword -AsPlainText -Force)
            )

            # THE ACCOUNT IS SAID OUT LOUD AND THE PASSWORD NEVER IS. A
            # deployment log is copied around far more freely than a password.
            & $say ("the technician gave the account '{0}'" -f $composed)
        }

        return [pscustomobject] @{
            Retry      = ($answer.Action -eq 'Next')
            DeployRoot = $typed
            Credential = $credential
        }
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

    # -- 6b. WHICH SHARE, WHEN THE IMAGE CARRIES RULES ------------------------
    #
    # MDT's Bootstrap.ini, and the reason it is a RULES file rather than a
    # settings one: one boot image, many sites. The machine has just been
    # gathered - it knows its gateway, its MAC, its model - and none of that
    # needed a share, which is what makes choosing one from it possible at all.
    #
    # BEFORE THE DRIVE IS RESOLVED, DELIBERATELY. Resolve-HDTDeployRoot turns a
    # volume-relative path into a letter on THIS machine; running it against the
    # share the rules did not choose would resolve the wrong thing and then
    # connect to it.
    #
    # ABSENT IS THE NORMAL CASE and costs nothing: no file, no change, and the
    # image deploys from what it was built with.

    $bootstrapRulePath = Join-Path -Path (Split-Path -Path $BootstrapPath -Parent) -ChildPath 'bootstrap-rules.yaml'
    $bootstrapRule = $null

    if ($fileSystem.TestPath($bootstrapRulePath)) {
        try {
            $bootstrapRule = Import-HDTBootstrapRuleDocument -Path $bootstrapRulePath -FileSystem $fileSystem
        } catch {
            # A BROKEN RULES FILE MUST NOT STRAND THE MACHINE. It was validated
            # when the image was built, so reaching here means the image was
            # edited or is damaged - and the share it was built for is still a
            # right answer. Logged loudly, because a machine that quietly
            # ignored its site rules deploys from the wrong place.
            & $say ("bootstrap rules at '{0}' could not be read and were ignored: {1}" -f
                $bootstrapRulePath, $_.Exception.Message) 'Warning'
            $bootstrapRule = $null
        }
    }

    $chosen = Resolve-HDTBootstrapRule -RuleDocument $bootstrapRule -Fact $fact `
        -DeployRoot ([string] $bootstrap.DeployRoot)

    $result['bootstrapRuleSource'] = [string] $chosen.Source
    $result['bootstrapRuleName'] = [string] $chosen.RuleName

    if ($chosen.Source -eq 'Rule') {
        & $say ("bootstrap rule '{0}' chose the deployment share '{1}'; the boot image was built with '{2}'." -f
            $chosen.RuleName, $chosen.DeployRoot, [string] $bootstrap.DeployRoot)
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

    $deployRoot = Resolve-HDTDeployRoot -DeployRoot ([string] $chosen.DeployRoot) `
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
            Write-Warning 'This boot image was built with promptForCredential, so it DELIBERATELY STOPS FOR A HUMAN: the deployment waits here until somebody types the deployment account and its password. An image meant to run with nobody present carries an embedded credential instead.'
            & $say 'prompting for the deployment credential - this image deliberately stops for a human' 'Warning'

            $credential = Get-Credential -Message 'The HDT deployment account for the content share'
        } elseif ([string] $chosen.CredentialSource -eq 'Rule') {
            # THE RULE CHOSE THE SHARE AND THE ACCOUNT TO OPEN IT WITH. MDT's
            # Bootstrap.ini did both, and it has to: an image serving many sites
            # that picked SERVER-B while keeping SERVER-A's account has picked a
            # share it cannot open.
            #
            # THE PASSWORD NEVER REACHES THE LOG. It is turned into a credential
            # here and the account name is all that is said out loud.
            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                [string] $chosen.UserName,
                (ConvertTo-SecureString -String ([string] $chosen.Password) -AsPlainText -Force)
            )

            & $say ("bootstrap rule '{0}' chose the deployment account '{1}'" -f $chosen.RuleName, $chosen.UserName)
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

    # A SHARE THAT CANNOT BE REACHED IS A QUESTION, NOT A FATAL ERROR.
    #
    # HDT-Wizard-01 proved why: its lab host's DHCP lease had moved, the image
    # still carried the old address, and this line threw
    #
    #     "NewMapping" ... The network path was not found
    #
    # straight into the fatal catch - which recorded the failure, could not
    # write RESULT.json (that goes to the share too), and powered the machine
    # off. A technician standing at the bench saw the message for a moment and
    # then a dark screen, with no way to say "the share is over here now".
    #
    # THE WELCOME SCREEN ALREADY EXISTED FOR THIS. New-HDTWizardHost's own
    # comment says it is "the window shown when the SHARE CANNOT BE REACHED";
    # what was missing was reading the box back. Now the technician can correct
    # the UNC and the connect is tried again with it.
    #
    # IT ASKS EVEN WHEN THE IMAGE SAYS TO SKIP THE WELCOME SCREEN, and that is
    # deliberate. HDTSkipWelcome defaults to TRUE for any image carrying an
    # embedded credential - MDT's model, because such an image is meant to run
    # with nobody present - so honouring it here meant the one machine that
    # needed a human got a shutdown instead of a window. The skip governs the
    # NORMAL path: whether to stop and ask before a deployment that could
    # otherwise proceed. A share that cannot be reached has no unattended
    # outcome left to protect.
    #
    # THE COST IS THAT AN UNWATCHED MACHINE WAITS instead of powering off. That
    # is the right way round: a machine sitting at a screen can be walked up to
    # and fixed, and one that powered off at 3am tells nobody anything. The
    # screen still has Cancel and a command prompt on it.

    $content = $null

    # -- the network carrying traffic, which is not the same as having an address
    #
    # AN ADDRESS IS NOT A NETWORK. The poll above stops the moment the machine
    # holds an IP, and on a Latitude 5490 into a real switch that is roughly
    # fifteen seconds before anything can be reached through it - link
    # negotiation finishes, then the switch port learns, and only then does a
    # frame get anywhere. In between, every SMB attempt comes back
    #
    #     The network path was not found.
    #
    # which reads like a wrong address and is not one. Measured on that machine:
    # five attempts over twenty seconds all failed, the technician pressed Next
    # about thirty-four seconds in, and it connected instantly with nothing
    # changed. BgInfo had been showing the correct address the whole time.
    #
    # SO IT WAITS FOR THE GATEWAY, which is the nearest thing that answers and
    # the one every route to the share goes through. This costs nothing on a
    # machine that is already up - the first ping answers - and it converts a
    # confusing failure into a few seconds of waiting on one that is not.
    #
    # IT NEVER FAILS THE DEPLOYMENT. A gateway that does not answer pings, a
    # WinPE without Test-Connection, a static configuration with no gateway at
    # all: each of those simply stops the wait and lets the attempts below
    # decide, exactly as before this existed.
    $gateway = ''
    if ($null -ne $fact -and $fact.Contains('HDTDefaultGateway')) {
        # THE FIRST ONE, because a dual-stack machine answers with IPv4 and a
        # link-local IPv6 in one string - the shape that broke a bootstrap rule
        # earlier the same day.
        $gateway = @(([string] $fact['HDTDefaultGateway']) -split '[,\s]+' |
                Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) | Select-Object -First 1
    }

    if (-not [string]::IsNullOrWhiteSpace($gateway)) {
        $reachable = $false
        $waitedForLink = [System.Diagnostics.Stopwatch]::StartNew()

        while ($waitedForLink.Elapsed.TotalSeconds -lt $LinkTimeoutSecond) {
            try {
                if (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction Stop) {
                    $reachable = $true
                    break
                }
            } catch {
                # NOT A REASON TO WAIT ANY LONGER. If pinging cannot be done
                # here at all, waiting for a ping is waiting for nothing.
                & $say ("the gateway could not be pinged, so the share is tried straight away: {0}" -f
                    [string] $_.Exception.Message) 'Warning'
                break
            }

            Start-Sleep -Seconds 2
        }

        $waitedForLink.Stop()

        if ($reachable) {
            & $say ("gateway {0} answered after {1:n0}s; the network carries traffic" -f
                $gateway, $waitedForLink.Elapsed.TotalSeconds)
        } else {
            & $say ("gateway {0} did not answer in {1}s; trying the share anyway" -f
                $gateway, $LinkTimeoutSecond) 'Warning'
        }
    }

    while ($true) {
        $providerArgument['Root'] = [string] $deployRoot.Path

        # TRIED MORE THAN ONCE, BECAUSE THE FIRST ATTEMPT IS THE WORST ONE.
        # WinPE has just finished bringing a network up: the switch may still be
        # learning, the lease may be seconds old, and the server may have no
        # session yet for a client that has only just appeared. Every one of
        # those is over in a few seconds, and none of them is a reason to end a
        # deployment or to wake somebody up.
        $reached = $false
        $lastError = ''

        for ($try = 1; $try -le $ConnectAttempt; $try++) {
            $content = New-HDTContentProvider @providerArgument

            try {
                [void] $content.Connect()
                $reached = $true

                # SAME AS THE FULL-OS LEG: what the provider noticed goes into
                # the log and the panel, not onto a warning stream nobody keeps.
                if ($null -ne $content.PSObject.Properties['Warning']) {
                    foreach ($noticed in @($content.Warning)) { & $say ([string] $noticed) 'Warning' }
                }

                break
            } catch {
                $lastError = [string] $_.Exception.Message

                & $say ("could not reach '{0}' (attempt {1} of {2}): {3}" -f
                    $deployRoot.Path, $try, $ConnectAttempt, $lastError) 'Warning'
            }

            if ($try -lt $ConnectAttempt) { Start-Sleep -Seconds ($try * 2) }
        }

        if ($reached) { break }

        # AND THEN THE SCREEN COMES UP, WHATEVER THE IMAGE SAYS ABOUT WHO IS HERE.
        #
        # This used to refuse instead, on HDTSkipWelcome, so that a ZTI machine
        # could not stop and wait for a Next nobody would press. The retries
        # above were the good half of that change; this was not. A machine whose
        # share had moved spent five attempts and then powered off with NOTHING
        # on screen - and nothing in a log either, because the log destination is
        # the share it could not reach. The report that silence was protecting
        # was never going to be written.
        #
        # THIS IS THE ONE FAILURE WHERE THE SCREEN COSTS NOTHING AND IS THE ONLY
        # THING LEFT. HDTSkipWelcome does not hide what is behind it: StaticIp
        # and DeployRoot default to not-skipped, so what opens is the network
        # pane and the share box, prefilled with the share that just failed -
        # which is exactly the thing the person standing there can correct. In
        # this lab the correction is usually one octet: the server's address is
        # a DHCP lease and the image was built with yesterday's.
        #
        # AND IT IS STILL BOUNDED. Leaving the screen without an answer ends the
        # run below rather than looping on a share that has already failed.
        $corrected = & $showWelcome

        if (-not $corrected.Retry) {
            throw ("HDTDeploymentCancelled: '{0}' could not be reached and the technician left the Welcome screen." -f
                $deployRoot.Path)
        }

        # THE RETYPED ACCOUNT, RE-BOUND THE WAY THE SHARE IS. Without this line
        # the credential quartet on that screen was decorative: a technician
        # told their credential was rejected retyped the password, pressed Next,
        # and pass two reconnected with THE SAME REJECTED ACCOUNT. The only
        # thing this screen could actually fix was a wrong path, and the boxes
        # that would have fixed the other half were read off the window and
        # thrown away.
        #
        # BEFORE THE EMPTY-SHARE-BOX CHECK BELOW, because that one continues the
        # loop - and a technician who corrected only the password, leaving the
        # share alone, is the commonest shape of this. Rebinding after it would
        # skip exactly the case this exists for.
        #
        # $null IS "NO CHANGE", NOT "NO CREDENTIAL" - see $showWelcome. Empty
        # boxes keep whatever this run was already using, which is what stops a
        # cleared box turning an embedded account into an anonymous connect.
        # Assigning unconditionally would do precisely that.
        if ($null -ne $corrected.Credential) {
            $providerArgument['Credential'] = $corrected.Credential
            $result['credentialSource'] = 'Welcome'

            & $say ("the technician gave the account '{0}'; the next attempt uses it" -f
                $corrected.Credential.UserName)
        }

        if ([string]::IsNullOrWhiteSpace($corrected.DeployRoot)) {
            & $say 'the Welcome screen was closed with an empty share box, so the same one is tried again' 'Warning'
            continue
        }

        # RESOLVED AGAIN, NOT ASSIGNED. What was typed is a deployRoot in the
        # same sense bootstrap.json's is - including the volume-relative form -
        # so it goes back through the command that knows what those mean.
        $deployRoot = Resolve-HDTDeployRoot -DeployRoot ([string] $corrected.DeployRoot) `
            -Provider ([string] $bootstrap.Provider) -CandidateRoot $candidateRoot `
            -Marker ([string] $bootstrap.ContentMarker) -FileSystem $fileSystem

        $result['resolvedDeployRoot'] = [string] $deployRoot.Path
        $result['deployRootSource'] = 'Welcome'

        & $say ("the technician gave '{0}'; trying that" -f $deployRoot.Path)
    }

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

    # -- 10a2. the log starts appearing on the share, from here on ------------
    #
    # MDT'S SLShareDynamicLogging. HDTSLShare says where the logs are COPIED
    # when a run ends; this says where they are WRITTEN while it runs, so a
    # deployment can be watched in CMTrace instead of waited for.
    #
    # AS EARLY AS THE ANSWER EXISTS, which is here. The log context was built in
    # the first seconds of the run, long before rules.yaml had been read - and
    # the end-of-run copy is guarded on a destination resolved a further four
    # hundred lines down, so a run that died in the wizard copied nothing and
    # left its reason on a RAM disk. That is the run this exists for, and it
    # happens before the wizard.
    #
    # THE MACHINE KEEPS ITS OWN LOG REGARDLESS. This is a second write, never a
    # redirect: Write-HDTLog appends locally first and unguarded, then mirrors
    # inside a try/catch per file. A share that goes away costs the mirror and
    # nothing else.
    #
    # A COMPUTER NAME IN THE PATH IS THE ONE RULES RESOLVED. If the technician
    # renames the machine on the wizard's Computer Details page, the folder
    # keeps the name it had when logging started - which is the name in the
    # records it holds, so the two agree.
    #
    # AND A FOLDER PER RUN INSIDE THAT ONE, WHICH SetDynamicPath ADDS. The rule
    # resolves to a folder per MACHINE, and nothing ever rolled the file inside
    # it, so one HDT.log accumulated every deployment that machine had ever had
    # - the real one on this lab's share held a pre-CRLF-fix run beside a
    # post-fix one and CMTrace could parse neither. The run folder is composed
    # from the log context's run id, which state.json carries across the reboot,
    # so the full-OS leg appends to the SAME file rather than starting a second
    # half-log. Nothing here composes it: a payload that knew the shape would be
    # a second source of truth the resume leg had to be kept in step with by
    # hand. What this block prepares - and probes for reachability - is
    # therefore $log.DynamicPath, the composed answer, not the raw rule value.
    $dynamicLogPath = ''
    if ($resolved.Variable.Contains('HDTSLShareDynamicLogging')) {
        $dynamicLogPath = [string] $resolved.Variable['HDTSLShareDynamicLogging']
    }

    if (-not [string]::IsNullOrWhiteSpace($dynamicLogPath)) {
        try {
            # NOTHING EXPANDS THE PATH HERE, AND NOTHING MAY. It arrives
            # finished: Add-HDTResolvedVariable expands as it STORES, so
            # $resolved.Variable holds '\\host\HDTShare\Logs\LT-7FJ45S2' and
            # never the '%HDTComputerName%' the rule was written with.
            #
            # THIS FILE IS A SCRIPT, NOT PART OF THE MODULE. It reaches the
            # engine through Import-Module Hephaestus, which imports the
            # MANIFEST - so the only names that exist here are the ones in
            # FunctionsToExport. b08bb91 called Expand-HDTVariableToken on this
            # line; it is a PRIVATE helper, it does not exist in a payload's
            # session, and the call threw CommandNotFoundException on every run.
            #
            # THE CATCH BELOW ATE IT. A share that cannot be written to must
            # never end a deployment, so the catch downgrades anything thrown in
            # here to a Warning and carries on - which is right, and which meant
            # live logging was dead for a day with nothing to show for it but
            # one line in LAUNCHER.log on the share it had failed to write to.
            # CreateDirectory was never reached, the folder never appeared, and
            # every run looked normal.
            #
            # A second expansion of an already-expanded string bought nothing
            # even in the world where the name resolved. tests/contract/
            # PayloadExportedCommand.Contract.Tests.ps1 now refuses the whole
            # class of it across every file in Payload\.
            # Armed first, then the composed folder is prepared. See the run
            # folder note above.
            $log.SetDynamicPath($dynamicLogPath)
            $fileSystem.CreateDirectory($log.DynamicPath)

            & $say ("logging live to '{0}' as well as this machine" -f $log.DynamicPath)
        } catch {
            $log.SetDynamicPath('')

            # NEVER FATAL. A share that cannot be written to is a reason to stop
            # mirroring, not a reason to stop deploying - and the local log,
            # which is the one that matters, is untouched either way.
            & $say ("the live log destination '{0}' could not be prepared, so logs stay on this machine until the run ends: {1}" -f
                $dynamicLogPath, [string] $_.Exception.Message) 'Warning'
        }
    }

    # -- 10a3. and where the log is COPIED when this run ends -----------------
    #
    # MDT'S SLShare, THE OTHER HALF OF THE SAME QUESTION. Ten lines above,
    # HDTSLShareDynamicLogging said where the log is WRITTEN while the run
    # happens; this says where the whole directory is COPIED when it ends, and
    # the tail's copy-back is guarded on nothing else.
    #
    # AND IT USED TO BE ANSWERED FOUR HUNDRED LINES DOWN, after the wizard and
    # after the progress window - which is to say after everything in this file
    # that can throw. A real deployment in this lab died in WinPE before a
    # single step ran and its failure screen read:
    #
    #   HDTConfigurationError: no task sequence was named.
    #   Log: (no log destination was resolved)
    #
    # true, and useless. The guard was still empty, the tail copied nothing, and
    # the entire record of why went away with the RAM disk five seconds later.
    #
    # b08bb91 MADE THIS MOVE FOR THE LIVE MIRROR AND LEFT THIS HALF BEHIND. Two
    # answers to one question, computed four hundred lines apart, is exactly how
    # one of them gets forgotten - so they sit together now, and both are known
    # before the wizard opens.
    #
    # NOTHING DOWNSTREAM CHANGES. $result['logDestination'] is what the failure
    # screen's Log line, the tail's copy-back and RESULT.json all read; this
    # fills it sooner and nothing fills it again.
    $logTarget = Get-HDTLogDestination -WorkspaceRoot $workspaceRoot -Variable $resolved.Variable

    $result['logDestination'] = [string] $logTarget.Path
    $result['logDestinationSource'] = [string] $logTarget.Source

    if ([string]::IsNullOrWhiteSpace([string] $logTarget.Path)) {
        # SAID OUT LOUD, ON THE PANEL. A run with no log destination is a run
        # whose evidence dies with the machine, and the technician in front of
        # it is the only person who can do anything about that.
        & $say 'no log destination was resolved, so this run''s log will not leave this machine' 'Warning'
    } else {
        & $say ("logs will be copied to '{0}' ({1})" -f $logTarget.Path, $logTarget.Source)
    }

    # -- 10b. THE ENGINE'S OWN DEFAULTS, BEFORE ANYTHING READS THEM -----------
    #
    # unattend.xml asks for four locales and a time zone as TOKENS rather than
    # carrying en-US as a literal, and Invoke-HDTApplyUnattend refuses a document
    # with an unresolved token - correctly, because a machine named
    # %HDTComputerName% is worse than a failed step. So a share that never
    # mentions them needs an answer, and it is the one the template hard-coded
    # before it was a variable: US English, and the boot image's own zone.
    #
    # THEY USED TO BE APPLIED A HUNDRED AND FIFTY LINES BELOW, after the wizard
    # had already decided which pages to ask. A zero-touch deployment in this lab
    # died on "the wizard page 'LocaleTime' is skipped by HDTSkipWizard, but
    # nothing supplies HDTTimeZone" - above the line that supplies HDTTimeZone.
    # A default applied after the check that wanted it is not a default; it is a
    # value nobody can use.
    #
    # ONLY WHEN NOTHING ELSE SPOKE. DESIGN 3.1's precedence puts the command
    # line, a machine override and a rule above the engine, and Contains is what
    # keeps them there. Seeding earlier must not turn a default into an override,
    # which is why this is a test rather than a comment.
    #
    # ONE RULE, TWO CALL SITES. The bag the engine finally runs on may be the
    # WIZARD's - a second-passed set built by Start-HDTWizardDeployment - so the
    # same seed is applied to that below. Two copies of a default list would be
    # two default lists as soon as one of them was corrected.
    $seedEngineDefault = {
        param($Bag)

        foreach ($pair in @(
                @{ Name = 'HDTKeyboardLocale'; Value = '0409:00000409' },
                @{ Name = 'HDTSystemLocale'; Value = 'en-US' },
                @{ Name = 'HDTUILanguage'; Value = 'en-US' },
                @{ Name = 'HDTUserLocale'; Value = 'en-US' })) {

            if (-not $Bag.Contains([string] $pair.Name)) {
                $Bag[[string] $pair.Name] = [string] $pair.Value
            }
        }

        # THE TIME ZONE THE DEPLOYED MACHINE GETS, from the boot image, unless a
        # rule already answered. The unattend's specialize pass reads it; without
        # it Windows derives the zone from the locale and every en-US machine
        # comes up on Pacific Standard Time.
        if (-not [string]::IsNullOrWhiteSpace([string] $bootstrap.TimeZone) -and
            -not $Bag.Contains('HDTTimeZone')) {

            $Bag['HDTTimeZone'] = [string] $bootstrap.TimeZone
        }
    }

    & $seedEngineDefault $resolved.Variable

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
    # NULL UNTIL A WIZARD RUNS. A share that declares no pages never opens one,
    # and the tail below reads this to know whether there is a second-passed bag
    # to deploy with or only the first resolution.
    $wizardVariable = $null

    # A RESUMED LEG ASKS NOBODY ANYTHING, AND THAT IS NOT AN OPTIMISATION.
    #
    # The wizard exists to collect what the rules could not supply, and on a
    # resumed leg that collection ALREADY HAPPENED - hours ago, on the WinPE leg
    # that started this run, and its answers are in the state document's
    # variable bag. Asking again would overwrite a technician's answers with a
    # second set, and on the capture boot of a reference build it would stop the
    # machine dead at a screen waiting for somebody who went home.
    $wizard = $null
    if ($null -eq $resumedState) {
        $wizard = Import-HDTWizardDocument -Provider $content
    } else {
        & $say 'this leg is resuming a run in progress, so nothing is asked: the answers are the ones already in the state document.'
    }

    if ($null -eq $wizard) {
        if ($null -eq $resumedState) {
            & $say 'no Scripts\UI\wizard.yaml on this share; nothing is asked and nothing waits.'
        }
    } else {
        $ask = Get-HDTWizardPage -Page $wizard.Page -Variable $resolved.Variable

        & $say ("wizard: {0} page(s) to ask, {1} skipped" -f @($ask.Page).Count, @($ask.Skipped).Count)

        foreach ($skipped in @($ask.Skipped)) {
            & $say ("  {0} skipped by {1}" -f $skipped.Id, $skipped.Rule)
        }

        if ($ask.IsWizardNeeded) {

            # THE CONSOLE GOES AWAY AND COMES BACK IN A finally - UNLESS STEP
            # 4a ALREADY HID IT, in which case this leaves both alone and the
            # tail owns the restore. Hidden is a presentation choice, never a
            # place to get stuck: a hidden console plus a wizard that then
            # throws leaves a technician staring at nothing.
            $consoleHidden = $false

            try {
                # Same rule as the Welcome screen, same reason.
                & $closeStatus

                if (-not $shellHidden) { $consoleHidden = [bool] (Hide-HDTShellWindow) }

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

                # W3: THE TASK SEQUENCE PICKER IS THE FOLDER, NOT A LIST
                # SOMEBODY TYPED. Scripts\UI\TaskSequence.xaml used to carry one
                # row per sequence and a share with eight offered one. This is
                # one more field, applied by name like every other.
                #
                # A PROBLEM IS LOGGED AND THE WIZARD STILL OPENS. A sequence
                # whose document will not parse, or an HDTTaskSequenceID naming
                # something this share does not carry, is a sentence in the log
                # and never a reason to leave the technician with no screen.
                $sequenceChoice = Get-HDTWizardSequence -WorkspaceRoot $workspaceRoot `
                    -FileSystem $fileSystem -Variable $resolved.Variable

                foreach ($problem in @($sequenceChoice.Problem)) {
                    & $say ("task sequence picker: {0}" -f $problem) 'Warning'
                }

                # "opening on ''" IS NOT A SENTENCE. Nothing preselected is the
                # normal state now - MDT's Task Sequence pane preselects nothing
                # and the page will not leave without a choice - so the log says
                # that in words rather than showing an empty pair of quotes and
                # leaving whoever reads it wondering what went wrong.
                $openingOn = 'nothing preselected, so the technician chooses'
                if (-not [string]::IsNullOrWhiteSpace([string] $sequenceChoice.Selected)) {
                    $openingOn = "opening on '{0}'" -f [string] $sequenceChoice.Selected
                }

                & $say ("task sequence picker: {0} sequence(s) on the share, {1}" -f
                    @($sequenceChoice.Choice).Count, $openingOn)

                # W4: THE NAME THE RULES PRODUCED, IN THE BOX BEFORE ANYBODY
                # TYPES. rules.yaml owns the convention - PC-%HDTSerialNumber%
                # and the rest - and this shows what it resolved to, falling
                # back to the serial and then to the machine's own name. The
                # verdict is logged: a rule that built a sixteen-character name
                # is a rule somebody has to fix, and the log is where they will
                # look after the technician has gone home.
                $computerName = Get-HDTWizardComputerName -Variable $resolved.Variable `
                    -Environment (New-HDTEnvironmentProvider)

                & $say ("computer name: '{0}' from {1}{2}" -f $computerName.Value, $computerName.Source,
                    $(if ($computerName.Severity -eq 'None') { '' } else { " - {0}: {1}" -f $computerName.Severity, $computerName.Reason }))

                # THE APPLICATIONS PAGE, AND THE LAST HAND-TYPED LIST IN THE
                # WIZARD. Applications.xaml carried three CheckBoxes somebody
                # wrote and admitted it in its own comment; this reads the
                # share's Applications\ catalog and preticks whatever
                # HDTApplications already resolved to, so a site that selects
                # its standard load in rules.yaml shows the technician what
                # they are about to get rather than an empty page.
                #
                # A PROBLEM IS LOGGED AND THE WIZARD STILL OPENS, exactly as
                # the sequence picker does: one unreadable app.yaml must not
                # cost the technician the whole screen.
                $applicationChoice = Get-HDTWizardApplication -WorkspaceRoot $workspaceRoot `
                    -FileSystem $fileSystem -Variable $resolved.Variable

                foreach ($problem in @($applicationChoice.Problem)) {
                    & $say ("applications page: {0}" -f $problem) 'Warning'
                }

                & $say ("applications page: {0} published on the share, {1} already selected" -f
                    @($applicationChoice.Choice).Count,
                    @($applicationChoice.Choice | Where-Object { $_.IsSelected }).Count)

                # EVERY OTHER BOX THE RULES CAN ALREADY FILL. MDT prefills its
                # panes from CustomSettings.ini; every page here except the
                # computer name came up holding whatever the markup said, so a
                # share whose rules.yaml had answered a question still showed a
                # blank box asking it again.
                #
                # SEEDED FIRST, SO THE COMMANDS ABOVE WIN. Fields are applied in
                # order and the last write to a control is what stays, so the
                # picker, the computer name and the application list overwrite
                # anything the generic seed put in the same box - they know more
                # about their own control than a variable lookup does.
                #
                # AND IT DOES NOT COST THE PROVENANCE. New-HDTWizardHost
                # remembers what was seeded and Test-HDTWizardAnswerChanged
                # drops a value that comes back untouched, so a rule shown to
                # the technician stays a Rule in the report rather than becoming
                # a Wizard answer nobody typed.
                $seed = @(Get-HDTWizardSeed -Page $ask.Page -Variable $resolved.Variable)

                & $say ("prefilled {0} box(es) from the resolved rules" -f @($seed).Count)

                $field = @($seed) + @($field) + @($sequenceChoice.Field) + @($computerName.Field) + @($applicationChoice.Field)

                # HDTBrandingName ON THE RAIL. A technician at a bench is often
                # looking at two toolkits, and the banner is the fastest way to
                # know which one has this machine. Unset leaves it 'Hephaestus'.
                $brandingName = ''
                if ($resolved.Variable.Contains('HDTBrandingName')) {
                    $brandingName = [string] $resolved.Variable['HDTBrandingName']
                }

                # SET BEFORE THE WINDOW OPENS, NOT AFTER IT CLOSES. A wizard
                # that throws while it is being built never reaches the line
                # after it - and that is the run whose failure screen matters
                # most, because a technician is standing in front of it.
                $windowShown = $true

                $answer = Show-HDTWizardShell -ShellXamlPath $WizardShellPath -ThemeXamlPath $WizardThemePath `
                    -Page $ask.Page -Title $wizard.Title -Field $field -BrandingName $brandingName

                $result['wizardAction'] = [string] $answer.Action
                & $say ("the technician chose: {0}" -f $answer.Action)

                # W5: WHAT THE ANSWER MEANS IS NOT THIS FILE'S QUESTION. The
                # allow-list, the second resolution that gives a typed value its
                # provenance, and the engine's own case-insensitive bag all live
                # in Start-HDTWizardDeployment, where a test can reach them
                # without a booted machine.
                $deploy = Start-HDTWizardDeployment -Answer $answer -ResolveArgument $resolveArgument

                # MDT'S "EXIT TO COMMAND PROMPT": the window closes and the
                # technician is left AT a prompt. Opening it is this caller's
                # job - Show-HDTWizardShell reports and opens nothing.
                if ($deploy.Action -eq 'CommandPrompt') {
                    $prompt = Start-HDTCommandPrompt
                    & $say ("command prompt: started {0} ({1})" -f $prompt.Started, $prompt.FilePath)

                    # THE MACHINE STAYS ON, and this is the field that keeps it
                    # on. A VM run found the whole point of this button undone
                    # by the tail: the prompt opened, the throw below was
                    # reported as a FATAL exception in the parent console, and
                    # wpeutil powered the machine off five seconds later - with
                    # the technician's prompt on it.
                    $result['leftAtCommandPrompt'] = $true

                    throw 'HDTDeploymentCancelled: the technician asked for a command prompt instead of a deployment.'
                }

                # A DISMISSED WIZARD IS NOT CONSENT TO PARTITION A DISK.
                if ($deploy.Action -ne 'Deploy') {
                    throw 'HDTDeploymentCancelled: the technician cancelled the wizard.'
                }

                & $say ("the wizard supplied {0} value(s): {1}" -f
                    @($deploy.Applied).Count, (@($deploy.Applied) -join ', '))

                # THE RESOLVED SET, ALREADY SECOND-PASSED. What the wizard typed
                # has been through the resolver as the Wizard source, so DESIGN
                # 3.1's precedence applied rather than being patched around.
                $resolved = $deploy.Resolved
                $wizardVariable = $deploy.Variable
            } finally {
                if ($consoleHidden) { [void] (Hide-HDTShellWindow -Restore) }

                # Between the wizard closing and the progress board opening there
                # is a second resolution, the engine defaults and the run state -
                # seconds of work with nothing else on screen to report it.
                & $openStatus
            }
        }
    }

    # THE BAG THE ENGINE RUNS ON. Start-HDTWizardDeployment built it when there
    # was a wizard; a share that declares none never opened one, and the first
    # resolution is what the machine deploys with.
    $variable = $wizardVariable
    if ($null -eq $variable) {
        $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($resolved.Variable.Keys)) {
            $variable[[string] $name] = $resolved.Variable[$name]
        }
    }

    # WHEN THIS RUN STARTED, IN UTC. A tattoo step subtracts it from a matching
    # end value to say how long the deployment took, and UTC is the decision
    # rather than a detail: WinPE runs on the hardware clock and the deployed OS
    # is put into a time zone half way through, so two local readings are hours
    # apart for reasons that have nothing to do with the duration.
    #
    # ISO 8601 WITH THE Z, invariant culture, because this value is read back by
    # code and by a person on a machine whose regional format is unknown.
    $variable['HDTDeploymentStart'] = [System.DateTime]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

    $result['deploymentStart'] = [string] $variable['HDTDeploymentStart']

    # AND THE SAME DEFAULTS ON THE BAG THE ENGINE ACTUALLY RUNS ON. When a wizard
    # ran, this is its second-passed set rather than the one seeded above, so the
    # seed is applied again - idempotently, because every line of it is guarded
    # by Contains. It is the same rule, not a second one: see $seedEngineDefault.
    & $seedEngineDefault $variable

    # -- WHAT THE MACHINE SAID ABOUT ITSELF, WRITTEN WHERE IT CAN BE DIFFED ---
    #
    # DESIGN 4.4 names three files under Gather\, and for eight milestones this
    # lab produced two of them. Export-HDTMachineFact was written, exported,
    # helped, unit tested and later taught to redact secrets - and it had NO
    # CALLER, so facts.json never existed on any run. That is the same defect
    # Export-HDTVariableProvenance had immediately below, found the same way: by
    # looking in the folder rather than at the tests.
    #
    # A FILE, NOT JUST THE VARIABLES. The twenty facts are already in the
    # variable bag and therefore in provenance.json, but mixed in with every
    # rule, wizard answer and sequence default around them. facts.json is what
    # the MACHINE said, on its own, so two runs of two machines diff to the
    # hardware difference and nothing else.
    #
    # $fact IS THE LAST POLL OF THE NETWORK LOOP, which is the fact set the
    # rules were resolved against - not a second, later reading that could
    # disagree with the resolution this run actually used.
    #
    # AND IT MAY NOT END A DEPLOYMENT, for the reason the two writes below may
    # not: this is evidence ABOUT the run, not part of it. A full disk or a
    # read-only log share costs the explanation, never the machine.
    try {
        [void] (Export-HDTMachineFact -Fact $fact `
                -Path ([System.IO.Path]::Combine($logDirectory, 'Gather', 'facts.json')) `
                -FileSystem $fileSystem -Timestamp ([System.DateTime]::UtcNow))
    } catch {
        & $say ("Gather\facts.json could not be written: {0}" -f $_.Exception.Message)
    }

    # -- WHERE EVERY VARIABLE CAME FROM, SAID ONCE, BEFORE ANYTHING RUNS -------
    #
    # DESIGN 3.1's whole promise is that the engine can explain every value it
    # resolved, and for eight milestones nothing asked it to. Write-HDTVariableLog
    # and Export-HDTVariableProvenance were both written, helped, exported and
    # unit tested - and neither had a single caller, so the report's Variables
    # section said "No variable resolutions were recorded" on every deployment
    # this lab has run, and DESIGN 4.4's Gather\provenance.json never existed.
    # This is MDT's ZTIGather writing "Property X is now = Y", which is the line
    # an administrator goes looking for first.
    #
    # HERE, AND NOT EARLIER. $resolved is the SECOND-PASSED set when a wizard ran
    # - a typed computer name has been back through the resolver as the Wizard
    # source, so both the value and its provenance differ from the first pass.
    # Logging before the wizard would describe a deployment that did not happen.
    #
    # AND NOT LATER. A run that dies on step two must already have said what it
    # was going to run with; provenance written at the end is provenance the
    # interesting runs never reach.
    #
    # THE RECORDS ARE Debug, which is DESIGN 4.4's decision, not a hedge: an Info
    # run drops them and a share that wants them sets logLevel: Debug. The one
    # exception is already inside the command - an unresolved %Var% comes out at
    # Warning, because that is the half nobody should have to opt in to.
    #
    # NEITHER MAY END A DEPLOYMENT. This is evidence about the run, not part of
    # it: a full disk or a read-only log share must cost the explanation, never
    # the machine.
    try {
        Write-HDTVariableLog -Context $log -Resolution $resolved
    } catch {
        & $say ("the variable provenance could not be logged: {0}" -f $_.Exception.Message)
    }

    try {
        [void] (Export-HDTVariableProvenance -Resolution $resolved `
                -Path ([System.IO.Path]::Combine($logDirectory, 'Gather', 'provenance.json')) `
                -FileSystem $fileSystem)
    } catch {
        & $say ("Gather\provenance.json could not be written: {0}" -f $_.Exception.Message)
    }

    # -- AND WHAT THE MACHINE IS MADE OF, WHICH GATHER NEVER RECORDED ---------
    #
    # The twenty facts above are what a RULE matches on - make, model, serial,
    # chassis, firmware. Not one of them is a hardware id, and the hardware id is
    # the only thing that identifies the specific device that did not come up. A
    # deployment that finished with no network card could be diagnosed as far as
    # "it is a Latitude 5490" and no further.
    #
    # A FILE, NOT VARIABLES. A machine reports dozens of devices with several ids
    # each; as engine variables that would bury the twenty facts a rule reads
    # under a hundred nothing matches on. devices.json sits beside facts.json and
    # provenance.json, which is MDT's shape - ZTIDrivers writes PnpEnum.xml into
    # the log directory for the same reason.
    #
    # HERE RATHER THAN IN THE DRIVER STEP, and that is the difference from MDT.
    # MDT's inventory exists only because its driver step needed one, so a run
    # that died before drivers left none - which is most of the runs somebody
    # wants one for. This is written before the sequence starts.
    #
    # IT MAY NOT END A DEPLOYMENT, for the same reason the two writes above may
    # not: this is evidence ABOUT the run, not part of it.
    try {
        $presentDevice = @(Get-HDTPresentDevice -Cim $cim)

        [void] (Export-HDTDeviceInventory -Device $presentDevice `
                -Path ([System.IO.Path]::Combine($logDirectory, 'Gather', 'devices.json')) `
                -FileSystem $fileSystem -Timestamp ([System.DateTime]::UtcNow))

        # driver.enumerate IS ALREADY THE NAME FOR "how many devices the machine
        # reported" - the driver step's PnP fallback writes it. Reusing it means
        # a technician filtering the log for that name finds the inventory and
        # the fallback's own count together, and it adds nothing to a controlled
        # vocabulary that is pinned to DESIGN 4.4.2.
        Write-HDTLog -Context $log -Event driver.enumerate -Component 'Gather' `
            -Message ('{0} device(s) reported hardware ids; written to Gather\devices.json' -f $presentDevice.Count) `
            -Data ([ordered] @{ deviceCount = [int] $presentDevice.Count })
    } catch {
        & $say ("Gather\devices.json could not be written: {0}" -f $_.Exception.Message)
    }

    # WHAT THIS BOOT IMAGE CARRIES, so a sequence can ask before it acts. The
    # client template's Install Certificates step is conditioned on it, and it
    # is set here rather than gathered because it is a fact about the IMAGE, not
    # about the machine - Get-HDTMachineFact reads hardware and knows nothing of
    # bootstrap.json.
    #
    # SET EITHER WAY, TRUE OR FALSE. An image built before this existed sets
    # neither, the token stays unresolved, and the engine reads that as false -
    # which skips the step, which is right. Writing False here is for the log
    # and for Export-HDTVariableProvenance, so "why did that not run" has an
    # answer on the machine rather than in this file.
    $hasCertificate = (@($bootstrap.RootCertificate).Count -gt 0 -or
        -not [string]::IsNullOrWhiteSpace([string] $bootstrap.ClientCertificate))

    $variable['HDTHasCertificate'] = $hasCertificate

    # WHICH SEQUENCE: the command line, else the boot image, else the rules.
    # None of the three set is a NAMED FAILURE, not a guess.
    $wantedSequence = $SequenceId
    if ([string]::IsNullOrWhiteSpace($wantedSequence)) { $wantedSequence = [string] $bootstrap.SequenceId }
    if ([string]::IsNullOrWhiteSpace($wantedSequence)) { $wantedSequence = [string] $variable['HDTTaskSequenceID'] }

    if ([string]::IsNullOrWhiteSpace($wantedSequence)) {
        throw ("HDTConfigurationError: no task sequence was named. -SequenceId was not given, bootstrap.json at '{0}' carries an empty sequenceId, and nothing in the rules resolved HDTTaskSequenceID for this machine." -f $BootstrapPath)
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

    if ($variable.Contains('HDTFinishAction')) {
        $result['finishAction'] = [string] $variable['HDTFinishAction']
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

    # AND THE OVERLAY COMES DOWN, because the deployment's own screen has taken
    # over and nothing below this line is a boot step. A run that showed a
    # Welcome screen or a wizard closed it there; this is the unattended run
    # that showed neither.
    & $closeStatus

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

    # -LogLevel IS WHAT THE SECOND LEG WILL LOG AT. The share is not reachable
    # when Start-HDTResume.ps1 builds its context, so the level travels in the
    # document rather than being looked up again.
    # A RESUMED LEG CONTINUES THE DOCUMENT IT FOUND; IT DOES NOT MINT ONE.
    #
    # New-HDTRunState builds a document with every step Pending and stepIndex 1,
    # which is exactly the "start from the beginning" this whole feature exists
    # to prevent. The document on the disk already knows which steps ran, on
    # which leg, and where the run had got to.
    #
    # THE LEG NUMBER GOES UP HERE, as Invoke-HDTBootReconciliation does it for
    # the full-OS direction. A leg that did not increment would record its work
    # against the leg before it, and "step 9 completed on leg 3" is the only way
    # to read a four-leg reference build afterwards.
    if ($null -ne $resumedState) {
        $state = $resumedState
        $state.leg = [int] $state.leg + 1
    } else {
        $state = New-HDTRunState -SequenceId $sequence.Id -RunId $runId -Phase WinPE `
            -Clock $clock -Variable $variable -Step $sequence.Step -LogLevel ([string] $log.Level)
    }

    $context = New-HDTExecutionContext -RunId $runId -Phase WinPE -WorkspaceRoot $workspaceRoot `
        -Variable $variable -Service $catalog -Log $log -State $state

    # -- 12. ONE call to the engine ------------------------------------------

    # -LogDestination IS THE LOG ROOT, NOT THE RUN FOLDER: Copy-HDTLog appends
    # <ComputerName>-<RunId> itself.
    #
    # AND WHICH ROOT IS MDT'S QUESTION, ANSWERED MDT'S WAY, AT STEP 10a3 -
    # before the wizard, so a run that dies in it still knows where its log
    # goes. Resolving it a second time here would be a second answer to
    # re-forget.
    $logDestination = [string] $result['logDestination']

    & $say 'running the task sequence'

    # -Resumed IS THE GUARD, AND -StatePath IS WHERE THE ANSWER LIVES.
    #
    # -Resumed refuses the step types that would destroy the installation this
    # run exists to finish - a resumed leg runs on a machine that has already
    # been deployed, so a partition step reaching the disk is a defect, not a
    # deployment.
    #
    # AND THE CHECKPOINT GOES BACK TO THE DOCUMENT IT RESUMED FROM. A leg that
    # read W:\HDT\state.json and then checkpointed to X:\HDT\Logs\state.json
    # would leave the durable copy FROZEN at the moment of the resume, and
    # Copy-HDTLog would ship the frozen one to the share - which is the stale-
    # state failure 05-03 already cost a full lab run, arrived at from the other
    # end.
    # NAMED RATHER THAN SPLATTED, DELIBERATELY. This is the one call to the
    # engine the whole file exists to make, and a contract test reads the
    # arguments off the call site to prove it is made properly. A splat hides
    # them behind a hashtable and the assertion becomes "it passed something".
    $statePath = [System.IO.Path]::Combine($logDirectory, 'state.json')
    if ($null -ne $resumedState) {
        $statePath = [string] $resume.Path
    }

    $run = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state `
        -StatePath $statePath -LogDestination $logDestination `
        -Resumed:($null -ne $resumedState)

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
    $result['message'] = [string] $_.Exception.Message

    # A CHOICE IS NOT A FAULT. Cancel and Open CMD both leave through this
    # catch, because a throw is how this script stops - but a technician who
    # pressed a button did not suffer a failure, and a red FATAL over a
    # deliberate choice is how everybody learns to ignore red. The prefix is
    # the one every deliberate stop in this file already carries.
    if ([string] $_.Exception.Message -like 'HDTDeploymentCancelled*') {
        $result['status'] = 'Cancelled'

        & $say ([string] $_.Exception.Message) 'Warning'
    } else {
        $result['status'] = 'Failed'

        & $say ("FATAL: {0}" -f $_.Exception.Message) 'Error'
        & $say ([string] ($_ | Out-String)) 'Debug'
    }
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

# AND THE CONSOLE COMES BACK, FIRST THING IN THE TAIL. Step 4a hid it for the
# whole run so a BGInfo wallpaper would be visible; from here on the console is
# what is wanted again. The FATAL line the catch just wrote is in that window,
# the failure screen below sits over it exactly as it did before the hide moved,
# and a technician left at a command prompt gets a prompt they can see.
#
# THE OVERLAY GOES DOWN FIRST. Every window this payload opens closes it before
# it draws; this is the run that opened none of them - an unattended machine that
# threw before step 10b - and leaving a transparent panel over the failure screen
# would be leaving one screen to explain another.
& $closeStatus

if ($shellHidden) { [void] (Hide-HDTShellWindow -Restore) }

# AND THE ONE THE WIZARD HID, which is a different flag with a different
# restore - at line 1156, after the wizard returns. A wizard that THREW never
# reaches it, so the console stayed hidden for exactly the run that needed it
# visible: the machine is now left in WinPE on purpose, and a technician
# standing at a black screen with no console has been told nothing.
#
# Get-Variable BECAUSE THE CRASH MAY PREDATE THE ASSIGNMENT. $consoleHidden is
# set on the way into the wizard; a run that died before that has never heard
# of it, and StrictMode throws on an unassigned variable - in the tail, where
# throwing loses the log copy-back as well.
$wizardConsoleHidden = [bool] (Get-Variable -Name 'consoleHidden' -ValueOnly -Scope Script -ErrorAction SilentlyContinue)
if ($wizardConsoleHidden) { [void] (Hide-HDTShellWindow -Restore) }

$result['elapsedSecond'] = [int] $started.Elapsed.TotalSeconds

# THE END, AFTER EVERYTHING. The context refreshes HDTDeploymentEnd before every
# step so a tattoo can read it, but the last refresh is the last STEP, not the
# end of the run - this is.
$result['deploymentEnd'] = [System.DateTime]::UtcNow.ToString(
    'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

if ($null -ne $log) {
    $result['logPath'] = [string] $log.LogPath
}

# WHAT THE MACHINE DOES NEXT, decided before it is recorded, so RESULT.json can
# say which one it was. ROADMAP M2 left "does WinPE need wpeutil reboot rather
# than shutdown.exe" open; this is the first run that can answer it.
# A DEPLOYMENT THAT WORKED RESTARTS INTO WHAT IT BUILT. It used to power the
# machine off, which is MDT's behaviour for nothing at all: LiteTouch restarts,
# and ConfigureBoot has already put the Windows Boot Manager first, so the next
# thing on screen is the machine's own Setup rather than a technician wondering
# whether it finished.
#
# A FAILURE STILL SHUTS DOWN, and that is not timidity. A failed run has usually
# not applied an image, so a machine that restarted would boot the media again
# and start the same deployment for the second time - a loop nobody is watching.
$ending = 'shutdown'
if ([string] $result['status'] -eq 'RebootPending' -or [string] $result['status'] -eq 'Succeeded') {
    $ending = 'reboot'
}

# -- and what an administrator asked for instead -----------------------------
#
# MDT's FinishAction, on the leg where a WinPE-only sequence ENDS. DEMO-M3 and
# DEMO-M4 are exactly that - they finish in WinPE and never reach a full OS - so
# a share that set HDTFinishAction and saw it ignored here would own a variable
# that works on some sequences and not others.
#
# ONLY ON Succeeded, AND THAT IS THE WHOLE CARE IN THIS BLOCK. RebootPending
# means the deployment is NOT over: the machine is going back into what it just
# built to run the rest of the sequence, and a finish action honoured there
# would power it off half way through, leaving an imaged machine that never ran
# a single full-OS step. A Failed run is left to the rule above it, which shuts
# down rather than restarting so a machine with no image does not boot the media
# and start the same deployment again.
#
# IT MOVES BETWEEN THE SAME TWO VERBS, never a third. Get-HDTPowerCommand plans
# reboot and shutdown for WinPE and nothing else, and LOGOFF resolves to no
# action here because WinPE has no session to end - which is why the environment
# passed below has to be the truthful one.
if ([string] $result['status'] -eq 'Succeeded') {
    try {
        $finish = Get-HDTFinishAction -Value ([string] $result['finishAction']) -Environment WinPE

        if (-not $finish.IsRecognised) {
            & $say ([string] $finish.Reason) 'Warning'
        }

        if ([string] $finish.Action -eq 'Restart') { $ending = 'reboot' }
        if ([string] $finish.Action -eq 'Stop') { $ending = 'shutdown' }

        if ([string] $finish.Action -ne 'None') {
            & $say ([string] $finish.Reason)
        }
    } catch {
        # A deployment that succeeded and then could not read a finish action
        # still succeeded. The default two lines above stand.
        & $say ("the finish action could not be read: {0}" -f [string] $_.Exception.Message) 'Warning'
    }
}

$result['endedWith'] = 'wpeutil {0}' -f $ending

# -- the failure screen, before anything is powered off ----------------------
#
# A MACHINE THAT FAILED USED TO TELL THE PERSON IN FRONT OF IT NOTHING. The
# reason went into the JSONL, a FATAL line went into a console this payload had
# hidden, and five seconds later wpeutil ended the machine. MDT shows a summary
# dialog naming the step, and now so does this - with the three things a
# technician does next on it, and the machine obeying whichever they pressed.
#
# IT IS SKIPPED WHEN NOBODY IS THERE TO READ IT: a run that never opened a
# window is a run nobody is standing at (DESIGN 11.1's suppression), and an
# unattended deployment must not wait for a keypress that will never come. That
# is what keeps the zero-keystroke E2E proof true.
# A WINDOW HAVING BEEN DRAWN IS THE TEST, NOT $display. $display is the
# PROGRESS window and it is created after the wizard, so a run that died in the
# wizard had it still $null - and this block, which exists to tell a technician
# what went wrong, decided nobody was there and skipped. Five seconds later
# wpeutil powered the machine off with the exception unread. The one person who
# could have fixed it had just clicked Next.
$technicianPresent = $windowShown -or ($null -ne $display -and $display.Mode -ne 'Suppressed')

if ([string] $result['status'] -eq 'Failed' -and
    -not [bool] $result['leftAtCommandPrompt'] -and
    $technicianPresent) {

    try {
        # A LEG THAT DIED BEFORE THE LOOP HAS NO RECORDS AND NO CONTEXT.
        # $log stays $null until the run id is known, which is after the share
        # is open - so a share that could not be reached made this line throw
        # inside its own try, and the screen was skipped without a word. The
        # same shape cost the full-OS leg its screen on 2026-08-21.
        $record = @()
        if ($null -ne $log) { $record = @(Get-HDTRunLogRecord -Context $log) }

        # AND THE REASON IS ALREADY IN HAND. The catch put the exception in
        # $result['message'] and nothing carried it any further, so a failure
        # with no step.fail record left IsFailure false and the window shut.
        $failure = Get-HDTDeploymentFailure -Record $record `
            -LogPath ([string] $result['logDestination']) `
            -Reason ([string] $result['message'])

        if ($failure.IsFailure) {
            $chosen = Show-HDTDeploymentFailure -Failure $failure -XamlPath $FailureXamlPath

            $result['failureScreen'] = [string] $chosen.Action
            & $say ("the failure screen was answered: {0} (shown: {1})" -f $chosen.Action, $chosen.Shown) 'Warning'

            if ([string] $chosen.Action -eq 'Restart') {
                $ending = 'reboot'
                $result['endedWith'] = 'wpeutil reboot'
            }

            if ([string] $chosen.Action -eq 'CommandPrompt') {
                $prompt = Start-HDTCommandPrompt
                & $say ("command prompt: started {0} ({1})" -f $prompt.Started, $prompt.FilePath)

                $result['leftAtCommandPrompt'] = $true
                $result['endedWith'] = 'nothing - the technician was left at a command prompt'
            }
        }
    } catch {
        # THE SCREEN IS NOT ALLOWED TO BECOME THE FAILURE. This machine has
        # already failed; a window that could not be drawn must not stop the
        # log being written or the machine being ended.
        & $say ("the failure screen could not be shown: {0}" -f [string] $_.Exception.Message) 'Warning'
    }
}

# EXCEPT WHEN A TECHNICIAN IS STANDING AT A PROMPT ON THIS MACHINE. Open CMD
# exists to debug a machine that is behaving badly, and a run that opened the
# prompt and then powered the machine off five seconds later gave the technician
# nothing at all - which is what a real VM run did. This script simply ends
# instead: startnet.cmd's own console is still there, and so is the prompt that
# was asked for.
#
# $ending IS NOT CLEARED TO SAY SO. Its two values are compared against
# Get-HDTPowerCommand's by a test that exists to stop this duplicate going
# stale, and a third value would be a third thing to keep in step. The verb
# stays what the machine WOULD have done; whether it does it is the guard at
# the end of this file.
if ([bool] $result['leftAtCommandPrompt']) {
    $result['endedWith'] = 'nothing - the technician was left at a command prompt'
}

# THE COPY-BACK, AGAIN AND UNCONDITIONALLY. The loop already did it when it got
# that far; this is for the runs that did not.
#
# BEFORE RESULT.json IS SERIALISED, AND THAT ORDER IS THE POINT. This used to be
# the last thing the file did, after the evidence file had already been written
# and after LAUNCHER.log had been closed - so whether the logs reached the share
# was recorded nowhere at all. It ran, it failed, and the only surface that knew
# was a Warning inside the copy of the log that never arrived.
#
# AND THE ANSWER IS READ RATHER THAN PIPED TO Out-Null. Copy-HDTLog is
# documented never to throw; it reports on its result instead, and a caller that
# threw the result away turned "the share is gone" into silence.
if ($null -ne $log -and -not [string]::IsNullOrWhiteSpace([string] $result['logDestination'])) {
    try {
        $copyArgument = @{ Context = $log; Destination = [string] $result['logDestination'] }
        if (-not [string]::IsNullOrWhiteSpace([string] $result['computerName'])) {
            $copyArgument['ComputerName'] = [string] $result['computerName']
        }

        $copied = Copy-HDTLog @copyArgument

        $result['logCopyBack'] = [string] $copied.Path

        if ($copied.Succeeded) {
            & $say ("the log was copied to '{0}'" -f $copied.Path)
        } else {
            $result['logCopyBack'] = ''

            & $say ("the log could NOT be copied to '{0}', so this run's record lives only on this machine: {1}" -f
                $copied.Path, $copied.Message) 'Warning'
        }
    } catch {
        $result['logCopyBack'] = ''

        & $say ("the log could NOT be copied: {0}" -f $_.Exception.Message) 'Warning'
    }
} else {
    & $say 'no log destination was resolved, so this run''s log stays on this machine' 'Warning'
}

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

if ($null -ne $content) {
    try {
        $content.Disconnect()
    } catch {
        Write-Information ("could not disconnect the content provider: {0}" -f $_.Exception.Message)
    }
}

Write-Information ("HDT run {0} ended {1} in {2}s; {3}" -f
    $runId, $result['status'], $result['elapsedSecond'], $result['endedWith'])

# HOW THIS MACHINE ENDS, IN EVERY PATH INCLUDING THE ONES WHERE IT FAILED BEFORE
# IT STARTED. The decision itself lives in Get-HDTMachineEnding, where it can be
# checked without a machine; the verb it is carried out with is $ending above.
#
# A FAILED RUN IS LEFT WHERE IT FAILED. "Do not loop" is answered by "stop", not
# by "power off": a machine sitting in WinPE keeps X:, the console and the error
# on screen and can be walked up to, while one that powered itself off took the
# only copy of the reason with it - and this payload's log lives on a share it
# may never have reached. Only a person ends a failed machine, from the failure
# screen; a command prompt means the machine is theirs and not this script's.
$failureScreenAction = ''
if ($result.Contains('failureScreen')) {
    $failureScreenAction = [string] $result['failureScreen']
}

$machineEnding = Get-HDTMachineEnding -Status ([string] $result['status']) `
    -FailureScreenAction $failureScreenAction `
    -LeftAtCommandPrompt:([bool] $result['leftAtCommandPrompt'])

if (-not $machineEnding.EndMachine) {
    $result['endedWith'] = [string] $machineEnding.Reason

    Write-Information ('HDT is not ending this machine: {0}' -f $machineEnding.Reason)
}

if ($machineEnding.EndMachine) {
    Start-Sleep -Seconds 5

    & "$env:SystemRoot\System32\wpeutil.exe" $ending
}

exit 0
