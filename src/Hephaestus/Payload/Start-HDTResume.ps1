<#
    .SYNOPSIS
        The RunOnce payload: reconcile the boot, then resume the task sequence.

    .DESCRIPTION
        DESIGN 4.5.1: "the engine is launched at logon by a RunOnce entry
        re-registered each leg, pointing at C:\HDT\Start-HDTResume.ps1, which
        loads state.json and continues at the next step."

        THIS IS NOT A MODULE FILE. The loader dot-sources Private\ and Public\
        only, so Payload\ ships as a script, is staged to C:\HDT\, and is
        launched by

            powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HDT\Start-HDTResume.ps1

        which is the command Set-HDTAutoLogon writes into RunOnce.

        THE RECONCILE RUNS FIRST, BEFORE ANYTHING ELSE (DESIGN 4.5.2): "if the
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
        The run state document. DESIGN 4.3 puts it at C:\HDT\state.json in the
        full OS.

    .PARAMETER WorkspaceRoot
        Where the sequence lives. The sequence is found at
        <WorkspaceRoot>\Sequences\<sequenceId>\sequence.yaml, with the id taken
        from the state document rather than guessed.

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

Import-Module -Name $ModulePath -Force -ErrorAction Stop

# The real adapters. A fake never appears in this file: it runs on a machine
# mid-deployment, and the whole point of the injection is that THIS is the one
# place the real ones are built.
$fileSystem = New-HDTFileSystem
$clock = New-HDTClock
$registry = New-HDTRegistryService
$lsa = New-HDTLsaService
$power = New-HDTPowerService
$process = New-HDTProcessService
$scriptInvoker = New-HDTScriptInvoker -Root $WorkspaceRoot
$environment = New-HDTEnvironmentProvider
$cim = New-HDTCimProvider

$logRoot = $LogPath
if ([string]::IsNullOrWhiteSpace($logRoot)) {
    $logRoot = Get-HDTLogPath -Phase FullOS
}

$fileSystem.CreateDirectory($logRoot)

# A bootstrap log context, so the reconcile's own decision is recorded even when
# it turns out there is no run to resume. Its run id is replaced below by the one
# from the state document when there is one.
$bootLog = New-HDTLogContext -RunId 'boot' -Phase FullOS -LogPath $logRoot `
    -FileSystem $fileSystem -Clock $clock

# BEFORE ANYTHING ELSE (DESIGN 4.5.2).
$decision = Invoke-HDTBootReconciliation -StatePath $StatePath -FileSystem $fileSystem `
    -Registry $registry -Lsa $lsa -Clock $clock -LogContext $bootLog -MaxAgeHour $MaxAgeHour

if ($decision.Action -eq 'Teardown') {
    Write-HDTLog -Context $bootLog -Event 'reboot.teardown' `
        -Message ("Nothing to resume ({0}); the machine has been disarmed." -f $decision.Reason)

    exit 0
}

$state = $decision.State

$sequenceFile = $SequencePath
if ([string]::IsNullOrWhiteSpace($sequenceFile)) {
    $sequenceFile = [System.IO.Path]::Combine($WorkspaceRoot, 'Sequences', [string] $state.sequenceId, 'sequence.yaml')
}

$sequence = Import-HDTSequenceDocument -Path $sequenceFile -FileSystem $fileSystem

# The state's runId and seq are what make this leg continuous with the last one.
$log = New-HDTLogContext -RunId ([string] $state.runId) -Phase FullOS -LogPath $logRoot `
    -FileSystem $fileSystem -Clock $clock -Seq ([long] $state.seq)

$catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
    -Lsa $lsa -Process $process -Power $power -ScriptInvoker $scriptInvoker -Cim $cim -Environment $environment

$variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @($state.variable.Keys)) {
    $variable[[string] $name] = $state.variable[$name]
}

$context = New-HDTExecutionContext -RunId ([string] $state.runId) -Phase FullOS `
    -WorkspaceRoot $WorkspaceRoot -Variable $variable -Service $catalog -Log $log -State $state

$run = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state -StatePath $StatePath

if ($run.Status -eq 'Failed') {
    exit 1
}

exit 0
