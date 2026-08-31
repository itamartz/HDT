<#
    .SYNOPSIS
        The RunOnce payload: reconcile the boot, then resume the task sequence.

    .DESCRIPTION
        The engine is launched at logon by a RunOnce entry re-registered each
        leg, pointing at C:\HDT\Start-HDTResume.ps1, which loads state.json and
        continues at the next step.

        THIS IS NOT A MODULE FILE. The loader dot-sources Private\ and Public\
        only, so Payload\ ships as a script, is staged to C:\HDT\, and is
        launched by

            powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HDT\Start-HDTResume.ps1

        which is the command Set-HDTAutoLogon writes into RunOnce.

        THE RECONCILE RUNS FIRST, BEFORE ANYTHING ELSE: "if the
        state document says the run is finished, failed, or missing, it clears
        autologon, the LSA secret, the RunOnce entry, and C:\HDT\state.json
        before doing anything else." A machine that boots with a finished or
        abandoned run must be disarmed on THAT boot, not on the next one, and
        certainly not only when AutoLogonCount finally runs out. So nothing here
        touches the sequence until the reconcile has answered.

        When it answers Teardown this script exits 0 and the machine is left
        disarmed. When it answers Resume, the log context is rebuilt from the
        state's runId and seq - so the JSONL numbering continues across the
        reboot - the sequence is re-imported from the workspace, and the loop is
        called with the state that was reconciled.

        IT IS TESTED BY PARSING AND INSPECTING IT rather than by running it.
        Running it for real means a module under C:\HDT\Modules, real service
        adapters and a machine to reboot, which belongs to phase 04's integration
        layer. tests/unit/StartHDTResumePayload.Tests.ps1 asserts what can be
        proven from a desk: that it parses under both engines, that the reconcile
        precedes the loop, and that the reconciled state is what the loop is
        given.

    .PARAMETER ModulePath
        The staged Hephaestus module. C:\HDT\Modules\Hephaestus on a deployed
        machine; a test points it elsewhere.

    .PARAMETER StatePath
        The run state document. It lives at C:\HDT\state.json in the
        full OS.

    .PARAMETER WorkspaceRoot
        Where the sequence lives when there is no share to reach. The deploy root
        from the bootstrap document wins over it: the sequence, the rules and the
        applications live where the deployment came from, and a leg rooted at
        C:\HDT would re-import a sequence that is not there.

    .PARAMETER BootstrapPath
        The staged bootstrap document - the deploy root, the provider and the
        account that opens the share. Copy-HDTResumeAgent puts the boot image's
        own copy beside this file. Absent, the leg runs against the local disk
        alone and says so.

    .PARAMETER SequencePath
        The sequence file, when it is not where WorkspaceRoot would put it.

    .PARAMETER LogPath
        The log directory for this leg. Defaults to Get-HDTLogPath for the full
        OS phase.

    .PARAMETER MaxAgeHour
        How stale a Running state may be before the run counts as abandoned.
        Passed through to the reconcile.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HDT\Start-HDTResume.ps1

        What RunOnce runs.

    .EXAMPLE
        .\Start-HDTResume.ps1 -ModulePath C:\src\Hephaestus -StatePath C:\HDT\state.json
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ModulePath = 'C:\HDT\Modules\Hephaestus',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $StatePath = 'C:\HDT\state.json',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WorkspaceRoot = 'C:\HDT',

    # THE SHARE, AND THE ACCOUNT THAT OPENS IT. Copy-HDTResumeAgent stages the
    # boot image's own bootstrap.json beside this file, for the reason the
    # description gives: the full-OS leg is the one that installs software, and
    # the software is on the share.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $BootstrapPath = 'C:\HDT\bootstrap.json',

    # THE SUMMARY SCREEN, BESIDE THE MODULE THAT DRAWS IT. The WinPE leg reads
    # its copy from X:\HDT\UI\; in the full OS the module is staged to
    # -ModulePath and ships its own UI\ folder, so the screen travels with the
    # engine rather than needing the share - which is exactly the resource a
    # failed deployment may not have.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $SummaryXamlPath,

    # THE STATUS BOARD, BESIDE THE SUMMARY SCREEN AND FOUND THE SAME WAY. This
    # leg used to draw NOTHING: applications appeared in appwiz.cpl and nobody
    # ever saw them install, because the longest part of a deployment reported to
    # a service catalog with no progress host in it while the technician looked
    # at the PowerShell console RunOnce had launched.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ProgressXamlPath,

    # WHERE THE LOGS LIVE ONCE THE AGENT IS GONE. MDT copies them to
    # %WINDIR%\TEMP\DeploymentLogs; HDT keeps them under %WINDIR%\Logs, because
    # Temp is a directory Windows itself cleans out and this is the only record
    # of how a machine was built. DESIGN 14 carries the divergence.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $FinalLogPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $SequencePath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $LogPath,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $MaxAgeHour = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# THE STAGED MODULE ROOT GOES ON PSModulePath FIRST, and this is not a
# convenience. ConvertFrom-HDTYaml imports powershell-yaml lazily BY NAME, so the
# copy Copy-HDTResumeAgent staged at <root>\powershell-yaml is invisible to it
# unless the folder holding it is a module path - and without that parser the
# engine cannot read one document: not a sequence, not a rule, not an image
# catalog. The WinPE entry point has always done this; this file never did, and
# nothing noticed because no full-OS leg had ever run.
#
# THE PARENT OF -ModulePath, so the two stay in step. A caller pointing
# -ModulePath at a source tree gets that tree's parent, which is where anything
# beside it would be.
$moduleRoot = [System.IO.Path]::GetDirectoryName($ModulePath.TrimEnd('\', '/'))

if (-not [string]::IsNullOrWhiteSpace($moduleRoot)) {
    $env:PSModulePath = '{0};{1}' -f $moduleRoot, $env:PSModulePath
}

Import-Module -Name $ModulePath -Force -ErrorAction Stop

# The real adapters. A fake never appears in this file: it runs on a machine
# mid-deployment, and the whole point of the injection is that THIS is the one
# place the real ones are built.
$fileSystem = New-HDTFileSystem
$clock = New-HDTClock
$registry = New-HDTRegistryService
$lsa = New-HDTLsaService
# FullOS, and it is not a guess either: this payload runs from RunOnce on a
# deployed Windows install, which has shutdown.exe and does not have wpeutil.
$power = New-HDTPowerService -Environment FullOS
$process = New-HDTProcessService
$scriptInvoker = New-HDTScriptInvoker -Root $WorkspaceRoot
$environment = New-HDTEnvironmentProvider
$cim = New-HDTCimProvider

$logRoot = $LogPath
if ([string]::IsNullOrWhiteSpace($logRoot)) {
    $logRoot = Get-HDTLogPath -Phase FullOS
}

$fileSystem.CreateDirectory($logRoot)

# The boot log's counter is seeded from the state document BEFORE the reconcile
# runs, because DESIGN 4.4.2's monotonic seq has to survive the reboot - and the
# reconcile's own reboot.resume record is written through this context, in the
# middle of the stream. A context left at zero restarts the numbering at 1 there,
# which is exactly the ambiguity the counter exists to prevent.
#
# READ-ONLY AND BEST-EFFORT, so it is not the reconcile happening early: nothing
# is decided or acted on here. A missing or corrupt document is the case the
# reconcile is about to disarm, and a restarted counter is the least of it.
#
# THE LEVEL COMES OUT OF THE SAME READ, AND IT IS NOT A CONVENIENCE. DESIGN
# 4.4.5 makes LogLevel a setting on the SHARE, and this leg has not opened the
# share yet - it is opened a hundred lines below, and may not open at all. So a
# level re-read from workspace.yaml here is a level that is not available.
# Measured on run-20260829-211758: the WinPE leg wrote 54 Debug records and this
# leg wrote none, because both contexts here took New-HDTLogContext's Info
# default. The full-OS leg is the one the applications install on.
#
# THE RUN'S LEVEL WINS OVER THE SHARE'S, DELIBERATELY. If workspace.yaml has
# been edited to Info since this run started at Debug, this leg still logs at
# Debug: one deployment's log is one document and must be readable end to end at
# a single verbosity, and an administrator who raised the level to diagnose a
# machine expects it raised for the reboot that machine is about to do. The
# share's value is what STARTS a run, not what a run in flight answers to.
$bootSeq = [long] 0
$bootLevel = 'Info'
try {
    if ($fileSystem.TestPath($StatePath)) {
        $onDisk = ConvertFrom-Json -InputObject $fileSystem.ReadAllText($StatePath)
        $bootSeq = [long] $onDisk.seq

        # Asked before it is read: a state document written before logLevel
        # existed has no such property, and under Set-StrictMode -Version Latest
        # reading one is a terminating error rather than a null.
        #
        # AND CHECKED AGAINST THE SET, because New-HDTLogContext validates -Level
        # and this read runs BEFORE the reconcile - the one thing that must
        # happen on this boot. A document with a nonsense level is the corrupt
        # case the reconcile is about to disarm, and it must not take the
        # reconcile down on its way there.
        if ($null -ne $onDisk.PSObject.Properties['logLevel'] -and
            @('Error', 'Warning', 'Info', 'Debug') -contains [string] $onDisk.logLevel) {

            $bootLevel = [string] $onDisk.logLevel
        }
    }
} catch {
    $bootSeq = [long] 0
    $bootLevel = 'Info'
}

# A bootstrap log context, so the reconcile's own decision is recorded even when
# it turns out there is no run to resume. Its run id is replaced below by the one
# from the state document when there is one.
$bootLog = New-HDTLogContext -RunId 'boot' -Phase FullOS -LogPath $logRoot `
    -FileSystem $fileSystem -Clock $clock -Seq $bootSeq -Level $bootLevel

# BEFORE ANYTHING ELSE (DESIGN 4.5.2).
$decision = Invoke-HDTBootReconciliation -StatePath $StatePath -FileSystem $fileSystem `
    -Registry $registry -Lsa $lsa -Clock $clock -LogContext $bootLog -MaxAgeHour $MaxAgeHour

if ($decision.Action -eq 'Teardown') {
    Write-HDTLog -Context $bootLog -Event 'reboot.teardown' `
        -Message ("Nothing to resume ({0}); the machine has been disarmed." -f $decision.Reason)

    exit 0
}

$state = $decision.State

# -- what this leg is, said before it can go wrong ------------------------
#
# NOTHING RECORDED WHERE THIS LEG WAS RUNNING FROM. When the leg below died on
# 2026-08-21 the only way to establish which module it had loaded, which
# bootstrap document it had read and where it had been writing its log was to
# power the machine off, mount its VHDX and look. All four are known right
# here, before the first thing that can fail, and cost one line.
Write-HDTLog -Context $bootLog -Component 'Resume' `
    -Message ("resuming '{0}': module '{1}', bootstrap '{2}', logs '{3}'." -f
        [string] $state.runId, $ModulePath, $BootstrapPath, $logRoot) `
    -Data ([ordered] @{
            runId         = [string] $state.runId
            modulePath    = [string] $ModulePath
            bootstrapPath = [string] $BootstrapPath
            logRoot       = [string] $logRoot
            statePath     = [string] $StatePath
        })

# -- everything from here to the loop is guarded --------------------------
#
# THE SUMMARY SCREEN SITS BELOW THE LOOP, SO ANYTHING THAT THREW ABOVE IT DREW
# NOTHING. Watched on 2026-08-21: the share could not be opened - the machine
# had been handed the deployment server's own address by DHCP and was dialling
# itself - which the block below correctly downgraded to a warning. That left
# the workspace root at C:\HDT, Import-HDTSequenceDocument looked for a
# sequence that is only on the share, and threw at SCRIPT SCOPE under
# ErrorActionPreference = 'Stop'. The script ended there: no window, and no log
# line either, because the RUN log context is built after that import.
#
# SO THE WHOLE SPAN IS ONE try, AND ITS catch IS THE SCREEN'S OTHER SOURCE.
# Get-HDTDeploymentFailure -Reason fills the window from the sentence alone,
# which is the only thing a leg that never reached step 1 has to give.
#
# DECLARED BEFORE THE try, ALL OF THEM. StrictMode makes an unassigned variable
# an error, and the summary and finish blocks below read $log, $variable and
# $run whichever way this goes - a catch that left them undefined would replace
# the failure with a different one.
$log = $null

# AND $failLog IS ONE OF THEM, which it was not. It was assigned only inside the
# catch below, so on the path where the sequence SUCCEEDS it was never set - and
# the summary, the finish action and every line of the cleanup write through it.
# A deployed Latitude clicked Finish, this threw, and the cleanup died on its
# first statement with C:\HDT and the share credential still on the disk.
$failLog = $bootLog

$run = $null
$variable = $null
$logDestination = ''
$setupFailure = ''
$workspaceRoot = $WorkspaceRoot
$sequenceFile = $SequencePath

# THE STATUS BOARD AND THE CONSOLE IT REPLACES, declared out here for the reason
# every other name in this list is: the summary block below runs after the catch
# and reads both, and a leg that threw before opening a window must not fail
# again on an unassigned variable.
$display = $null
$shellHidden = $false

# WHAT THE TECHNICIAN PRESSED ON THE SUMMARY, read by the finish block below
# whether or not a screen was ever drawn. HDTSkipFinalSummary skips the screen
# entirely, and an empty answer is what "nobody was asked" looks like.
$summaryAction = ''

try {

    # -- the share ------------------------------------------------------------
    #
    # THE FULL-OS LEG IS THE ONE THAT INSTALLS SOFTWARE, AND THE SOFTWARE IS ON THE
    # SHARE. This payload used to root itself at C:\HDT and build no content
    # provider, so InstallApplications - the step whose whole documented home is a
    # FullOS group - looked for Applications\ on the local disk and found nothing.
    # The sequence, the rules and the applications all live where the deployment
    # came from.
    #
    # THE ANSWER IS THE ONE THE WinPE ENTRY POINT ALREADY GAVE, through the same
    # commands: bootstrap.json names the deploy root, the provider and the account,
    # and Copy-HDTResumeAgent staged it beside this file.
    #
    # A SHARE THAT CANNOT BE REACHED IS NOT FATAL HERE. The machine is deployed and
    # somebody is logged into it; the steps that need content will fail and say
    # which, and the reconcile has already disarmed the autologon if it needed to.
    # Refusing to run at all would turn "one application did not install" into "the
    # machine never finished and nobody can tell why".
    $content = $null

    if ($fileSystem.TestPath($BootstrapPath)) {
        # DECLARED BEFORE THE try THAT FILLS IT, because the catch below names
        # the share in its warning and StrictMode makes an unassigned variable
        # an error - so a bootstrap document that would not parse would fail
        # inside the handler instead of being reported by it.
        $providerArgument = @{
            Provider   = ''
            Root       = ''
            FileSystem = $fileSystem
        }

        try {
            $bootstrap = Get-HDTBootstrapConfiguration -Path $BootstrapPath -FileSystem $fileSystem

            $providerArgument['Provider'] = [string] $bootstrap.Provider
            $providerArgument['Root'] = [string] $bootstrap.DeployRoot

            # THE DEPLOY ROOT THE RUN ACTUALLY USED, not the one the image was built
            # with. A bootstrap rule may have chosen another share, and the Welcome
            # screen may have corrected it by hand - both land in the state
            # document's variables, and both are what the WinPE leg connected to.
            if ($null -ne $state.variable -and $state.variable.Contains('HDTDeployRoot') -and
                -not [string]::IsNullOrWhiteSpace([string] $state.variable['HDTDeployRoot'])) {

                $providerArgument['Root'] = [string] $state.variable['HDTDeployRoot']
            }

            if ([string] $bootstrap.Provider -eq 'Smb' -and -not [bool] $bootstrap.PromptForCredential) {
                $providerArgument['Credential'] = $bootstrap.GetCredential()
            }

            # SAID BEFORE IT IS TRIED, NOT AFTER IT WORKS. The only line this
            # block used to write was the one on success, so a leg that could not
            # open the share left no record of WHICH share, over which provider,
            # as which account - the three things the failure is always about.
            $accountName = '(none - the share is opened as this machine)'
            if ($providerArgument.ContainsKey('Credential') -and $null -ne $providerArgument['Credential']) {
                $accountName = [string] $providerArgument['Credential'].UserName
            }

            Write-HDTLog -Context $bootLog -Component 'Resume' `
                -Message ("opening the deployment share '{0}' over {1} as {2}." -f
                    $providerArgument['Root'], $providerArgument['Provider'], $accountName) `
                -Data ([ordered] @{
                        deployRoot = [string] $providerArgument['Root']
                        provider   = [string] $providerArgument['Provider']
                        account    = [string] $accountName
                    })

            $content = New-HDTContentProvider @providerArgument
            [void] $content.Connect()

            $workspaceRoot = [string] $providerArgument['Root']

            # A setFrom rule and a PowerShell step both name paths relative to the
            # workspace, so the invoker follows the root rather than the parameter.
            $scriptInvoker = New-HDTScriptInvoker -Root $workspaceRoot

            Write-HDTLog -Context $bootLog -Component 'Resume' `
                -Message ("connected to '{0}' over {1}" -f $workspaceRoot, $bootstrap.Provider)

            # WHAT THE PROVIDER NOTICED ABOUT THE CONNECTION, INTO THE LOG. It
            # used to Write-Warning these, and a deployed machine showed the
            # cost: "the connection to '192.168.2.42' is not encrypted" was on a
            # PowerShell console sitting over the Deployment Summary, while the
            # log for that run said nothing about it at all. An unencrypted share
            # carrying a deployment credential is exactly the kind of finding
            # somebody reads a log to find. (The 192.168.2.* addresses in
            # this file are the incidents' own; that lab moved to
            # 192.168.1.0/24 on 2026-08-28.)
            if ($null -ne $content.PSObject.Properties['Warning']) {
                foreach ($noticed in @($content.Warning)) {
                    Write-HDTLog -Context $bootLog -Severity Warning -Component 'Content' `
                        -Message ([string] $noticed)
                }
            }
        } catch {
            $content = $null

            # NAME THE SHARE. This warning used to carry the exception and
            # nothing else - "The network path was not found" - so establishing
            # WHICH path had not been found meant powering the machine off and
            # mounting its disk to read bootstrap.json. Observed 2026-08-21.
            Write-HDTLog -Context $bootLog -Severity Warning -Component 'Resume' `
                -Message ("the deployment share '{0}' could not be reached over {1}, so any step needing content will fail: {2}" -f
                    $providerArgument['Root'], $providerArgument['Provider'], $_.Exception.Message) `
                -Data ([ordered] @{
                        deployRoot    = [string] $providerArgument['Root']
                        provider      = [string] $providerArgument['Provider']
                        exceptionType = [string] $_.Exception.GetType().FullName
                    })

            # AND NAME THE MACHINE'S OWN ADDRESS BESIDE IT. On 2026-08-21 the
            # share was \192.168.2.42\HDTShare and this machine's DHCP lease
            # WAS 192.168.2.42 - it was dialling itself, because the lab's DHCP
            # had handed the guest the deployment server's address. Those two
            # facts one line apart are the entire diagnosis; apart, they are a
            # VHDX mount and a registry hive.
            #
            # NEVER ALLOWED TO REPLACE THE WARNING ABOVE. A diagnostic that
            # throws would turn "the share is unreachable" into a stack trace
            # about network adapters.
            try {
                $network = Get-HDTNetworkConfiguration -CimProvider $cim

                Write-HDTLog -Context $bootLog -Severity Warning -Component 'Resume' `
                    -Message ("this machine is holding {0} via {1} on '{2}' - check it is not the share's own address." -f
                        $network.IPAddress, $network.Gateway, $network.AdapterDescription) `
                    -Data ([ordered] @{
                            hasLease  = [bool] $network.HasLease
                            ipAddress = [string] $network.IPAddress
                            gateway   = [string] $network.Gateway
                            adapter   = [string] $network.AdapterDescription
                        })
            } catch {
                Write-HDTLog -Context $bootLog -Severity Warning -Component 'Resume' `
                    -Message ("and this machine's own address could not be read either: {0}" -f $_.Exception.Message)
            }
        }
    } else {
        Write-HDTLog -Context $bootLog -Severity Warning -Component 'Resume' `
            -Message ("no bootstrap document at '{0}', so this leg runs against the local disk alone." -f $BootstrapPath)
    }

    if ([string]::IsNullOrWhiteSpace($sequenceFile)) {
        $sequenceFile = Get-HDTWorkspacePath -Root $workspaceRoot -Kind TaskSequences `
            -ChildPath ([string] $state.sequenceId), 'sequence.yaml'
    }

    # THE PATH, BEFORE THE STATEMENT THAT THROWS ON IT. This import is what
    # ended the leg on 2026-08-21, and it named nothing on its way in: the file
    # it had been given was worked out three lines above from a workspace root
    # that the unreachable share had left pointing at the local disk.
    Write-HDTLog -Context $bootLog -Component 'Resume' `
        -Message ("reading the sequence from '{0}' (workspace root '{1}')." -f $sequenceFile, $workspaceRoot) `
        -Data ([ordered] @{
                sequenceFile  = [string] $sequenceFile
                workspaceRoot = [string] $workspaceRoot
                sequenceId    = [string] $state.sequenceId
            })

    $sequence = Import-HDTSequenceDocument -Path $sequenceFile -FileSystem $fileSystem

    # The state's runId and the BOOT LOG'S seq are what make this leg continuous with
    # the last one. Not $state.seq: the boot context above has already consumed a
    # number for the reboot.resume record, and seeding from the state here would
    # reissue it.
    #
    # AND THE LEVEL COMES FROM THE STATE, NOT FROM THIS PROCESS. Import-HDTRunState
    # gives every document it returns a logLevel, so this reads it rather than
    # asking whether it is there - the reconcile above handed back an imported
    # document.
    $log = New-HDTLogContext -RunId ([string] $state.runId) -Phase FullOS -LogPath $logRoot `
        -FileSystem $fileSystem -Clock $clock -Seq ([long] $bootLog.Seq) `
        -Level ([string] $state.logLevel)

    # AND THE TAIL WRITES THROUGH THE RUN'S CONTEXT FROM HERE ON, so a summary
    # or a cleanup line lands in the run's log rather than the boot log.
    $failLog = $log

    # THE REGISTRY ADAPTER TOO, and this is the leg where it matters most: the
    # full OS is where arming autologon touches a live Winlogon key rather than
    # WinPE's throwaway copy. See the note beside the same line in
    # Start-HDTDeployment.
    $registry.LogContext = $log

    # THE BAG FIRST, BECAUSE THE BOARD IS DECIDED FROM IT. HDTSkipProgress
    # lives here, and Start-HDTProgressDisplay reads it to answer whether there
    # should be a window at all.
    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($state.variable.Keys)) {
        $variable[[string] $name] = $state.variable[$name]
    }

    # -- and the share sees this leg too, as it happens -----------------------
    #
    # MDT'S SLShareDynamicLogging COVERS THE WHOLE DEPLOYMENT. It was set here
    # for WinPE only, so \Logs\<ComputerName> on the share held the WinPE leg
    # and stopped at the restart - and everything this leg writes AFTER the
    # engine finishes (the summary, the finish action, the entire cleanup block)
    # went only to C:\HDT\Logs.
    #
    # WHICH IS THE FOLDER THE CLEANUP DELETES, so the sweep that removes the
    # share credential logged into the directory it was about to remove. When it
    # died on a real Latitude there was nothing on the share to say so and the
    # reason had to be read off the machine over WinRM.
    #
    # THE VALUE ARRIVES EXPANDED, exactly as it does in the WinPE payload:
    # Add-HDTResolvedVariable expands as it STORES, and this bag is rehydrated
    # from state.json, so it already holds '\\host\HDTShare\Logs\LT-7FJ45S2'
    # and never the '%HDTComputerName%' the rule was written with. Nothing here
    # may expand it again - Expand-HDTVariableToken is a PRIVATE helper and does
    # not exist in a payload's session (b08bb91 learned that the hard way).
    $dynamicLogPath = ''
    if ($variable.Contains('HDTSLShareDynamicLogging')) {
        $dynamicLogPath = [string] $variable['HDTSLShareDynamicLogging']
    }

    if (-not [string]::IsNullOrWhiteSpace($dynamicLogPath)) {
        try {
            # THE SAME TWO LINES THE WinPE LEG RUNS, IN THE SAME ORDER, AND
            # THAT IS THE POINT. SetDynamicPath puts a folder named for the RUN
            # under whatever the rule resolved, composed from the context's
            # RunId - and this leg's context was built above with
            # $state.runId, the id leg 1 minted and state.json carried across
            # the restart. So both legs compose the identical path and append to
            # ONE file, which is what a run that spans a reboot has to produce.
            # Two half-logs would be a worse answer than the unbounded file this
            # replaced.
            #
            # NEITHER LEG KNOWS THE SHAPE. If this file composed the folder
            # itself it would have to be kept in step with the WinPE payload by
            # somebody remembering to, which is the class of defect that put
            # 253 WinPE records and no full-OS ones on the share.
            $log.SetDynamicPath($dynamicLogPath)
            $fileSystem.CreateDirectory($log.DynamicPath)

            Write-HDTLog -Context $log -Component 'Resume' `
                -Message ("logging live to '{0}' as well as this machine" -f $log.DynamicPath)
        } catch {
            # Armed before the probe ran, so a share that cannot be reached
            # turns it back off - see the WinPE payload's note.
            $log.SetDynamicPath('')

            # NEVER FATAL, the same rule the WinPE leg runs under. A share that
            # cannot be written to is a reason to stop mirroring, not a reason to
            # stop a deployment that has already installed the operating system.
            Write-HDTLog -Context $log -Severity Warning -Component 'Resume' `
                -Message ("the live log destination '{0}' could not be prepared, so logs stay on this machine until the run ends: {1}" -f
                    $dynamicLogPath, [string] $_.Exception.Message)
        }
    }

    # -- the progress window, before the loop starts --------------------------
    #
    # THIS LEG DREW NOTHING UNTIL NOW, AND A DEPLOYED MACHINE IS HOW THAT WAS
    # FOUND: the applications were in appwiz.cpl and nobody had seen one
    # install. They install SILENTLY by design - a deployment must not stop on a
    # dialog nobody is there to click - so the board naming them was the only
    # thing that was ever going to show it happening, and there was no board.
    #
    # WinPE HAD ONE THE WHOLE TIME. The short half of a deployment had a status
    # card and the long half - applications, roles, the reboots between them -
    # had a PowerShell console.
    #
    # A hashtable, because Start-HDTProgressDisplay takes one and the bag above
    # is ordered and case-insensitive for the engine's sake.
    $progressVariable = @{}
    foreach ($name in @($variable.Keys)) { $progressVariable[[string] $name] = $variable[$name] }

    $progressXaml = $ProgressXamlPath

    if ([string]::IsNullOrWhiteSpace($progressXaml)) {
        # BESIDE THE AGENT, NOT INSIDE THE MODULE - the same correction the
        # summary screen's default already carries. Update-HDTBootImage keeps
        # UI\ OUT of the module tree, so a default that pointed into the staged
        # module would name a folder that is never there.
        $progressXaml = [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($StatePath), 'UI', 'HDTProgress.xaml')
    }

    $display = Start-HDTProgressDisplay -XamlPath $progressXaml -Variable $progressVariable

    # THROUGH $log, AND THE CONTEXT IS THE WHOLE POINT OF THE LINE. This wrote
    # through $bootLog, whose counter was handed to $log a hundred lines above
    # with -Seq $bootLog.Seq. NextSeq lives on the context, so from that moment
    # the two objects held the same number and each incremented its own copy -
    # and the next write through either one reissued it. run-20260829-223623
    # put "logging live to '\\...'" and this line both at seq 209, one second
    # apart, both in the full OS; run-20260829-190105 did it at 128. Nothing
    # after $log exists may write through $bootLog.
    Write-HDTLog -Context $log -Severity Info -Component 'Resume' `
        -Message ("progress display: {0} {1}" -f $display.Mode, $display.Reason)

    if ($display.Mode -ne 'Suppressed') {
        # NOT IN THE EVENT STREAM. Every other value on that screen is derived
        # from the log; the machine's own name is a variable, and this is the
        # only place that has it.
        $displayName = ''
        if ($variable.Contains('HDTComputerName')) { $displayName = [string] $variable['HDTComputerName'] }

        $display.DisplayHost.SetComputerName($displayName)
    }

    # AND THE CONSOLE GOES, BUT ONLY IF THERE IS A WINDOW INSTEAD. RunOnce
    # launches this leg through Set-HDTAutoLogon's command, which carries no
    # -WindowStyle Hidden, so what a technician sees is a PowerShell host. A
    # machine that could not draw the board keeps it, because a hidden console
    # with nothing over it is a blank screen. Step 13 puts it back.
    if ($display.Mode -eq 'Window') {
        $shellHidden = [bool] (Hide-HDTShellWindow)
    }

    # AN IMAGE SERVICE IN THE FULL OS, WHICH THIS LEG HAD NO REASON TO CARRY
    # UNTIL THE FullOS -> WinPE TRANSPORT EXISTED.
    #
    # Every other IImageService method writes an operating system to a disk from
    # WinPE, so a full-OS leg that offered one would have been offering a way to
    # overwrite the machine it is running on. BootToWinPE is the exception and it
    # is why this line is here: it runs bcdedit in the full OS, against the boot
    # store this machine booted through, because that is the only place the
    # capture boot can be armed. WinPE cannot do it - the store bcdedit finds
    # there is the RAM disk's.
    #
    # WITHOUT IT THE STEP FAILS AT GetRequired('Image'), and it fails on the
    # RIGHT side of the seal - before Sysprep, on a machine somebody can still
    # log into - which is the only reason this was a stopped sequence rather
    # than a stranded machine. It was still a defect: a green suite against
    # fakes proved nothing about which services this payload actually builds.
    $imageService = New-HDTImageService

    # AND A BitLocker SERVICE, WHICH THIS LEG HAS NEEDED SINCE THE WIZARD GREW A
    # BitLocker PAGE AND NOBODY NOTICED.
    #
    # client.yaml's Enable BitLocker step is in State Restore, runs in the full
    # OS, and is switched on by ticking a box on the wizard - so the FIRST person
    # to tick that box would have got GetRequired('BitLocker') failing at their
    # machine, on the step that encrypts the disk, at the end of a deployment.
    # Every unit test passed, because a step is tested against a catalog the test
    # itself builds.
    #
    # Found by the set test in tests/unit/StartHDTResumePayload.Tests.ps1, which
    # walks the shipped templates rather than naming services one at a time. It
    # was written for the Image service above and caught this on its first run.
    $bitLocker = New-HDTBitLockerService

    $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
        -Lsa $lsa -Process $process -Power $power -ScriptInvoker $scriptInvoker -Cim $cim `
        -Environment $environment -Image $imageService -BitLocker $bitLocker `
        -Content $content -Progress $display.DisplayHost

    $context = New-HDTExecutionContext -RunId ([string] $state.runId) -Phase FullOS `
        -WorkspaceRoot $workspaceRoot -Variable $variable -Service $catalog -Log $log -State $state

    # WHERE THIS LEG'S LOGS GO WHEN IT ENDS. The loop copies the tree only when it
    # is told where, and this payload never told it - so everything the full-OS leg
    # did stayed on a machine that had already been handed over, while the
    # technician looked at the share.
    #
    # THROUGH Get-HDTLogDestination, which is what the WinPE entry point uses, so
    # HDTSLShare sends these to a log server exactly as it sends the others. A
    # second answer to "where do logs go" is a second place for them to be missing
    # from.
    #
    # NOTHING TO COPY TO IS NOT AN ERROR. A leg that could not reach the share still
    # runs, and its log stays on the machine where somebody can read it.
    $logDestination = ''

    if (-not [string]::IsNullOrWhiteSpace($workspaceRoot) -and $null -ne $content) {
        try {
            $logDestination = [string] (Get-HDTLogDestination -WorkspaceRoot $workspaceRoot -Variable $variable).Path
        } catch {
            $logDestination = ''
        }
    }

    # AND THE STATE DOCUMENT THE SHARE GETS HAS TO BE THIS LEG'S.
    #
    # This leg keeps its state at C:\HDT\state.json, which is right: the boot
    # reconcile reads it there, and Remove-HDTResumeAgent clears it there. But
    # the copy-back above ships the LOG DIRECTORY, and the WinPE leg kept its
    # state inside that directory - so what reached the share was the copy
    # frozen at the moment of the restart, while every write this leg made went
    # somewhere the share never sees.
    #
    # A deployment that finished Succeeded therefore left a state.json on the
    # share reading status Running, leg 1, the last step Pending and autologon
    # still armed, stamped hours before the log beside it. Read on its own -
    # which is how a state document is read - it describes a machine somebody
    # has to go and rescue.
    #
    # MirrorPath writes the identical bytes to both, so the document in the log
    # directory stays this leg's and the copy-back ships something true.
    $loopArgument = @{
        Sequence        = $sequence
        Context         = $context
        State           = $state
        StatePath       = $StatePath
        MirrorStatePath = [System.IO.Path]::Combine($logRoot, 'state.json')
    }
    if (-not [string]::IsNullOrWhiteSpace($logDestination)) {
        $loopArgument['LogDestination'] = $logDestination
    }

    $run = Invoke-HDTTaskSequence @loopArgument
} catch {
    # THE SENTENCE THE SCREEN AND THE LOG BOTH GET. Not a summary of it: the
    # exception the engine was given is what names the fix, and shortening it
    # leaves a technician with a log to go and read on a share this machine has
    # just proved it cannot reach.
    $setupFailure = ("this leg could not be started: {0}" -f $_.Exception.Message)

    # THROUGH THE BOOT CONTEXT WHEN THERE IS NO RUN CONTEXT, which is the usual
    # case here: $log is built inside the try, after the import that is most
    # likely to have thrown. Reaching for it unconditionally would throw inside
    # the handler and lose the failure a second time.
    $failLog = $bootLog
    if ($null -ne $log) { $failLog = $log }

    # THE STACK GOES IN THE DATA, NOT THE MESSAGE. "The network path was not
    # found" is true of a dozen statements in this file; which one raised it is
    # the difference between reading the log and mounting the disk.
    Write-HDTLog -Context $failLog -Severity Error -Component 'Resume' `
        -Message $setupFailure `
        -Data ([ordered] @{
                exceptionType = [string] $_.Exception.GetType().FullName
                workspaceRoot = [string] $workspaceRoot
                sequencePath  = [string] $sequenceFile
                scriptStack   = [string] $_.ScriptStackTrace
                position      = [string] $_.InvocationInfo.PositionMessage
            })
}


# -- the board comes down ----------------------------------------------------
#
# BEFORE THE SUMMARY SCREEN, because that screen is the one a technician
# ANSWERS and a status board left up over it is a machine that looks hung. After
# the catch, because a leg that threw is exactly the leg whose screen must not
# be left on a machine that is about to restart.
#
# AND THE CONSOLE STAYS HIDDEN UNTIL THE SUMMARY HAS BEEN ANSWERED. The restore
# was here, one line below this, and a deployed machine showed what that meant:
# the PowerShell console came back and sat ON TOP of the Deployment Summary,
# which is the exact window it had been hidden for. It is restored at the very
# end instead - see below.
if ($null -ne $display -and $display.Mode -ne 'Suppressed') {
    $display.DisplayHost.Close()
}

# -- the deployment summary, MDT's Finished screen ---------------------------
#
# THIS LEG USED TO END ON exit 0 OR exit 1 AND DRAW NOTHING. A machine that had
# just deployed itself and one that had failed halfway through State Restore
# looked identical to the person standing in front of them, and the only
# difference between them was in a log on a share they would have to go and read.
#
# ONE SCREEN, BOTH OUTCOMES. Get-HDTDeploymentFailure reports the run whatever
# it did - the headline is a field on the window - so this is the same window
# the WinPE leg shows, with the same three buttons.
#
# HDTSkipFinalSummary IS THE ONLY REASON NOT TO SHOW IT, and it is MDT's
# SkipFinalSummary with MDT's meaning. Deliberately NOT gated on whether a
# progress window was opened: that is what the WinPE failure screen does, and it
# is why an unattended machine whose share had moved powered off with nothing on
# it. An image that genuinely wants no screen says so in a rule.
$skipSummary = $false
if ($null -ne $variable -and $variable.Contains('HDTSkipFinalSummary')) {
    $skipSummary = ('true' -eq ([string] $variable['HDTSkipFinalSummary']).Trim().ToLowerInvariant())
}

if (-not $skipSummary) {
    # THE SCREEN IS NOT ALLOWED TO BECOME THE OUTCOME. This machine has just
    # been deployed; a window that cannot be drawn must not change what this leg
    # reports, and must not stop it exiting.
    try {
        $summaryXaml = $SummaryXamlPath

        if ([string]::IsNullOrWhiteSpace($summaryXaml)) {
            # BESIDE THE AGENT, NOT INSIDE THE MODULE. Update-HDTBootImage keeps
            # UI\ OUT of the module tree - the wizard runs in WinPE from
            # X:\HDT\UI\ - so the staged module has no UI folder at all. This
            # defaulted into it, the file was never there, and a deployment that
            # succeeded end to end ended in silence.
            $summaryXaml = [System.IO.Path]::Combine(
                [System.IO.Path]::GetDirectoryName($StatePath), 'UI', 'HDTFailure.xaml')
        }

        # NO RUN LOG MEANS NO RECORDS, AND THE SCREEN STILL HAS TO SAY
        # SOMETHING. When the guard above caught a setup failure, $log is null
        # and the only account of what happened is $setupFailure - which is what
        # -Reason exists to carry.
        $record = @()
        if ($null -ne $log) { $record = @(Get-HDTRunLogRecord -Context $log) }

        $summary = Get-HDTDeploymentFailure -Record $record -LogPath $logDestination -Reason $setupFailure

        # AND THE ANSWER IS KEPT. It used to be discarded with [void], so the
        # three buttons on that screen did nothing at all: HDTFinishAction
        # decided the power state whatever the technician pressed, and Restart
        # on a finished machine could shut it down because a rule said so.
        $summaryAction = [string] (Show-HDTDeploymentFailure -Failure $summary -XamlPath $summaryXaml).Action

        Write-HDTLog -Context $failLog -Component 'Summary' `
            -Message ("the deployment summary was answered: {0}" -f $summaryAction)
    } catch {
        # INTO THE RUN LOG, NOT A STREAM NOBODY READS. This was
        # Write-Information, so when the screen could not be drawn the reason
        # went to a host that had already been hidden - which is how a missing
        # HDTFailure.xaml looked exactly like a deployment with nothing to say.
        $said = "the deployment summary could not be shown: {0}" -f $_.Exception.Message

        Write-Information $said

        if ($null -ne $log) {
            try {
                Write-HDTLog -Context $log -Severity Warning -Component 'Summary' -Message $said
            } catch {
                Write-Information 'and it could not be logged either.'
            }
        }
    }
}

# -- the console comes back before anything else does -------------------------
#
# AFTER THE SUMMARY, NEVER BEFORE. It was before, and the console landed over
# the Deployment Summary on a machine that had just deployed correctly.
#
# AND BEFORE THE CLEANUP, WHICH IS THE PART THAT NOW RESTARTS THE MACHINE. What
# follows may power the machine off; a console restored after that is a console
# nobody sees. A technician left at a prompt, or a machine whose finish action
# is NONE, gets their window back.
if ($shellHidden) { [void] (Hide-HDTShellWindow -Restore) }

# -- what the machine WILL do when it is finished -----------------------------
#
# MDT's FinishAction. THIS LEG USED TO END ON exit 0 AND LEAVE THE MACHINE WHERE
# IT WAS - sitting at a desktop, logged in as the local Administrator, until
# somebody walked over to it. That is the opposite of what a technician imaging
# a bench of twenty machines wants, and it is why MDT has the property.
#
# IT IS DECIDED HERE AND PERFORMED LATER, AND THE SPLIT IS NEW. C:\HDT is
# removed by a DETACHED process that has to kill this one first - this leg holds
# YamlDotNet.dll open out of the folder it is deleting - so a restart issued
# from here would power the machine down with C:\HDT still on it. The decision
# is therefore made now, handed to the deleter, and carried out here only if
# there is no deleter to carry it.
#
# THE PAYLOAD DECIDES NOTHING ABOUT WHAT THE VALUE MEANS. Get-HDTFinishAction is
# what knows that REBOOT is a restart, that RESTART means the same, that LOGOFF
# does nothing in WinPE and that a value nobody meant does nothing at all - it
# is pure and unit tested, and this file is neither.
$finishValue = ''
if ($null -ne $variable -and $variable.Contains('HDTFinishAction')) {
    $finishValue = [string] $variable['HDTFinishAction']
}

# EXCEPT WHEN A TECHNICIAN NAMED ONE, and that is the whole reason the summary's
# answer is now kept. HDTFinishAction is what a machine does when NOBODY SAID
# OTHERWISE - MDT's property, MDT's meaning - and a press is saying otherwise.
#
#   Restart / Shutdown   the button named a power state, so it produces it
#   Finish               MDT's own button: the screen has been read, and what
#                        happens next is the rule's answer, unchanged
#   CommandPrompt        the machine belongs to the technician now
#
# THE PROMPT CASE ENDS THE POWER STORY ENTIRELY, which is the lesson the WinPE
# leg already learned the hard way: a run that opened a prompt and then powered
# the machine off five seconds later gave the technician nothing at all.
if ($summaryAction -eq 'Restart' -or $summaryAction -eq 'Shutdown') {
    $finishValue = $summaryAction
}

if ($summaryAction -eq 'CommandPrompt') {
    $prompt = Start-HDTCommandPrompt

    Write-HDTLog -Context $failLog -Component 'Finish' `
        -Message ("command prompt: started {0} ({1})" -f $prompt.Started, $prompt.FilePath)

    $finishValue = 'NONE'
}

# THE FINISH ACTION IS NOT ALLOWED TO BECOME THE OUTCOME, the same rule the
# summary screen above runs under. A deployment that succeeded and then could
# not work out how to reboot still succeeded, and the exit code below is what
# the state file, the monitor and the technician all read.
$finishAction = 'None'
$finishDelay = 0

try {
    $finish = Get-HDTFinishAction -Value $finishValue -Environment FullOS

    if (-not $finish.IsRecognised) {
        Write-HDTLog -Context $log -Severity Warning -Component 'Finish' -Message ([string] $finish.Reason)
    }

    $finishAction = [string] $finish.Action
    $finishDelay = [int] $finish.DelaySecond

    if ($finishAction -ne 'None') {
        Write-HDTLog -Context $log -Component 'Finish' -Message ([string] $finish.Reason) `
            -Data ([ordered] @{ action = $finishAction; delaySecond = $finishDelay })
    }
} catch {
    Write-Information ("the finish action could not be worked out: {0}" -f $_.Exception.Message)
}

# -- MDT's LTICleanup, and only on a deployment that worked -------------------
#
# WHAT A FINISHED MACHINE WAS STILL CARRYING. Watched on a deployed VM: the
# Deployment Summary said the run succeeded, and the machine still held the
# deployment share on a mapped drive, still had C:\HDT with the engine and the
# share credential's bootstrap document in it, and its only account of how it had
# been built was inside that same folder.
#
# ON SUCCESS ONLY, WHICH IS MDT'S RULE AND THE ONE THAT MATTERS. A failed
# deployment is exactly the machine somebody walks up to with questions, and
# every one of those questions is answered by the things this removes.
#
# AND NOT WHEN A TECHNICIAN ASKED FOR A PROMPT. Open CMD means they are going to
# go and look; deleting the engine and the logs out from under them would be the
# same defect the WinPE leg already learned - a prompt granted and then made
# useless five seconds later.
#
# NOTHING HERE MAY BECOME THE OUTCOME. A share that will not unmap and a folder
# that will not delete are both smaller problems than a green run recorded as a
# failure, so each is caught and logged on its own.
$cleanupWanted = ($null -ne $run -and $run.Status -eq 'Succeeded' -and $summaryAction -ne 'CommandPrompt')

# WHETHER SOMETHING ELSE NOW OWNS THE POWER STATE. It is set only when the
# detached deleter actually started; every other path leaves it false and the
# machine is restarted from here, exactly as it always was.
$removalStarted = $false

if ($cleanupWanted) {

    # THE MAPPED DRIVE IS THE PROVIDER'S, AND THIS LEG NEVER DISCONNECTED. The
    # WinPE payload has always done it in its tail; this one simply exited, so a
    # deployed machine kept the share mapped for the life of the session.
    if ($null -ne $content) {
        try {
            $content.Disconnect()

            Write-HDTLog -Context $failLog -Component 'Cleanup' `
                -Message 'the deployment share was disconnected'
        } catch {
            Write-HDTLog -Context $failLog -Severity Warning -Component 'Cleanup' `
                -Message ("the deployment share could not be disconnected: {0}" -f $_.Exception.Message)
        }
    }

    # AND THE AGENT GOES, LOGS FIRST. Remove-HDTResumeAgent refuses a path that
    # does not carry Start-HDTResume.ps1, so a bug in the parameter above cannot
    # become a recursive delete of somewhere else.
    #
    # IT CANNOT DELETE THE FOLDER THIS SCRIPT IS RUNNING FROM, and that is why
    # the finish action is handed over with it. powershell-yaml has
    # YamlDotNet.dll loaded out of C:\HDT\Modules and 5.1 cannot unload an
    # assembly, so the tree goes to a detached process that kills this one first
    # - which means this process is not alive afterwards to restart the machine.
    $finalLogs = $FinalLogPath
    if ([string]::IsNullOrWhiteSpace($finalLogs)) {
        $finalLogs = '{0}\Logs\HDT' -f $env:SystemRoot
    }

    # THE DRIVER FOLDER GOES WITH IT. ApplyDrivers staged packages to
    # <os volume>\Drivers so the answer file's DriverPaths could inject them
    # offline; by the time this runs Windows has installed from them and the
    # folder is 4.2 GB of dead weight on a machine somebody is about to be
    # handed. PSD removes it beside MININT (PSDFinal.ps1:53-62).
    #
    # NAMED HERE, NOT WORKED OUT IN THE DELETER, which runs detached and
    # elevated with -Recurse -Force: a path that process guessed is the one
    # thing that could erase the machine it just built. It still checks the
    # name it is given.
    #
    # THE SYSTEM DRIVE, because this leg is the full OS - the W: the WinPE leg
    # staged into is C: from here.
    $driverFolder = [System.IO.Path]::Combine($env:SystemDrive + '\', 'Drivers')

    try {
        $swept = Remove-HDTResumeAgent -Path ([System.IO.Path]::GetDirectoryName($StatePath)) `
            -LogDestination $finalLogs -DriverPath $driverFolder `
            -FinishAction $finishAction -DelaySecond $finishDelay -Confirm:$false

        $removalStarted = [bool] $swept.RemovalStarted

        Write-HDTLog -Context $failLog -Component 'Cleanup' `
            -Message ("the resume agent was swept: {0} log file(s) kept at '{1}', {2} secret(s) destroyed, removal started {3}" -f
                $swept.LogFileCount, $swept.LogDestination, @($swept.SecretRemoved).Count, $swept.RemovalStarted) `
            -Data ([ordered] @{
                    path           = [string] $swept.Path
                    removalStarted = [bool] $swept.RemovalStarted
                    message        = [string] $swept.Message
                })
    } catch {
        Write-HDTLog -Context $failLog -Severity Warning -Component 'Cleanup' `
            -Message ("the resume agent could not be removed: {0}. The deployment is unaffected." -f $_.Exception.Message)
    }
}

# -- and what the machine does now it is finished -----------------------------
#
# ONLY WHEN NOBODY ELSE IS GOING TO. The detached deleter performs the finish
# action itself once C:\HDT is gone - and even if the delete failed - because it
# has to stop this process before it can delete anything. Two things issuing a
# restart is a machine that goes down while the tree is half removed.
#
# A MACHINE LEFT POWERED ON IS A SMALLER PROBLEM THAN A GREEN RUN RECORDED AS A
# FAILURE, which is why this is caught and the exit code below is untouched.
if (-not $removalStarted) {
    try {
        if ($finishAction -ne 'None') {
            switch ($finishAction) {
                'Restart' { $power.Restart($finishDelay) }
                'Stop' { $power.Stop($finishDelay) }
                'Logoff' { $power.Logoff($finishDelay) }
            }
        }
    } catch {
        Write-Information ("the finish action could not be performed: {0}" -f $_.Exception.Message)
    }
}

# A LEG THAT NEVER PRODUCED A RUN FAILED. $run is null when the guard above
# caught a setup failure, and StrictMode would make reading .Status off it a
# second error on top of the first - reported, of course, as something else.
if ($null -eq $run -or $run.Status -eq 'Failed') {
    exit 1
}

exit 0
