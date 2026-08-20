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
$bootSeq = [long] 0
try {
    if ($fileSystem.TestPath($StatePath)) {
        $bootSeq = [long] (ConvertFrom-Json -InputObject $fileSystem.ReadAllText($StatePath)).seq
    }
} catch {
    $bootSeq = [long] 0
}

# A bootstrap log context, so the reconcile's own decision is recorded even when
# it turns out there is no run to resume. Its run id is replaced below by the one
# from the state document when there is one.
$bootLog = New-HDTLogContext -RunId 'boot' -Phase FullOS -LogPath $logRoot `
    -FileSystem $fileSystem -Clock $clock -Seq $bootSeq

# BEFORE ANYTHING ELSE (DESIGN 4.5.2).
$decision = Invoke-HDTBootReconciliation -StatePath $StatePath -FileSystem $fileSystem `
    -Registry $registry -Lsa $lsa -Clock $clock -LogContext $bootLog -MaxAgeHour $MaxAgeHour

if ($decision.Action -eq 'Teardown') {
    Write-HDTLog -Context $bootLog -Event 'reboot.teardown' `
        -Message ("Nothing to resume ({0}); the machine has been disarmed." -f $decision.Reason)

    exit 0
}

$state = $decision.State

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
$workspaceRoot = $WorkspaceRoot
$content = $null

if ($fileSystem.TestPath($BootstrapPath)) {
    try {
        $bootstrap = Get-HDTBootstrapConfiguration -Path $BootstrapPath -FileSystem $fileSystem

        $providerArgument = @{
            Provider   = [string] $bootstrap.Provider
            Root       = [string] $bootstrap.DeployRoot
            FileSystem = $fileSystem
        }

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

        $content = New-HDTContentProvider @providerArgument
        [void] $content.Connect()

        $workspaceRoot = [string] $providerArgument['Root']

        # A setFrom rule and a PowerShell step both name paths relative to the
        # workspace, so the invoker follows the root rather than the parameter.
        $scriptInvoker = New-HDTScriptInvoker -Root $workspaceRoot

        Write-HDTLog -Context $bootLog -Component 'Resume' `
            -Message ("connected to '{0}' over {1}" -f $workspaceRoot, $bootstrap.Provider)
    } catch {
        $content = $null

        Write-HDTLog -Context $bootLog -Severity Warning -Component 'Resume' `
            -Message ("the deployment share could not be reached, so any step needing content will fail: {0}" -f
                $_.Exception.Message)
    }
} else {
    Write-HDTLog -Context $bootLog -Severity Warning -Component 'Resume' `
        -Message ("no bootstrap document at '{0}', so this leg runs against the local disk alone." -f $BootstrapPath)
}

$sequenceFile = $SequencePath
if ([string]::IsNullOrWhiteSpace($sequenceFile)) {
    $sequenceFile = Get-HDTWorkspacePath -Root $workspaceRoot -Kind TaskSequences `
        -ChildPath ([string] $state.sequenceId), 'sequence.yaml'
}

$sequence = Import-HDTSequenceDocument -Path $sequenceFile -FileSystem $fileSystem

# The state's runId and the BOOT LOG'S seq are what make this leg continuous with
# the last one. Not $state.seq: the boot context above has already consumed a
# number for the reboot.resume record, and seeding from the state here would
# reissue it.
$log = New-HDTLogContext -RunId ([string] $state.runId) -Phase FullOS -LogPath $logRoot `
    -FileSystem $fileSystem -Clock $clock -Seq ([long] $bootLog.Seq)

$catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
    -Lsa $lsa -Process $process -Power $power -ScriptInvoker $scriptInvoker -Cim $cim `
    -Environment $environment -Content $content

$variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @($state.variable.Keys)) {
    $variable[[string] $name] = $state.variable[$name]
}

$context = New-HDTExecutionContext -RunId ([string] $state.runId) -Phase FullOS `
    -WorkspaceRoot $workspaceRoot -Variable $variable -Service $catalog -Log $log -State $state

$run = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state -StatePath $StatePath

if ($run.Status -eq 'Failed') {
    exit 1
}

exit 0
