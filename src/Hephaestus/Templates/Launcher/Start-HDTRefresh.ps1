<#
    .SYNOPSIS
        THE FULL-OS ENTRY POINT - what an administrator runs to start a Refresh
        on a machine that is already running Windows.

    .DESCRIPTION
        MDT's \\server\Share$\Scripts\LiteTouch.vbs, in HDT. It is the file an
        administrator opens the share and runs on the machine that is about to be
        replaced, and it is seeded onto every share by New-HDTWorkspace from
        src\Hephaestus\Templates\Launcher.

        RUN IT AS ADMINISTRATOR, from the share:

            \\server\HdtShare\Scripts\Start-HDTRefresh.cmd

        The Start-HDTRefresh.cmd beside this file is the double-clickable half,
        because Windows opens a PowerShell script in an editor rather than
        running it, and that wrapper is also what sets HDT_LAUNCHED_BY.

        IT CONTAINS NO DEPLOYMENT LOGIC AND MAKES NO DECISION, WHICH IS THE
        POINT. LiteTouch.vbs is thin for the same reason: it finds where it was
        launched from, checks the machine can do this, and hands everything to
        the heavy lifting. HDT's heavy lifting is Start-HDTDeployment.ps1 - the
        same file startnet.cmd runs in WinPE - which has derived its own phase
        since M9 and needs no second entry point. Every branch this file would
        otherwise take belongs to Get-HDTRefreshLaunchPlan, where a fake can
        drive it; tests/unit/WorkspaceLauncherTemplate.Tests.ps1 PARSES this file
        and asserts it names no disk cmdlet, no DISM, no bcdedit, calls the plan
        exactly once and hands over exactly once.

        THE RUN IS A REFRESH BECAUSE IT STARTED HERE, and nothing declares it.
        Get-HDTDeploymentPhase reads the system drive - not X:, so FullOS - and
        Get-HDTDeploymentType maps that to REFRESH (DESIGN 3.2). This file passes
        no phase, no type and no -Phase to anything: a run that could be told
        what it is could talk its way past the guard that only a REFRESH unlocks.

        THE SHARE IS THIS FILE'S OWN LOCATION. The administrator reached
        \\server\Share\Scripts\ to run it, so that path demonstrably works from
        this machine right now - which a deployRoot written into a document
        months ago may not.

    .PARAMETER SequenceId
        The task sequence to run. Omitted, the sequence comes from the wizard or
        from the share's rules, which is where "which task sequence does this
        machine get" is answered everywhere else in HDT.

    .EXAMPLE
        \\HDT-HOST\HdtShare\Scripts\Start-HDTRefresh.cmd

        What an administrator runs. Elevated, on the machine to be replaced.

    .EXAMPLE
        .\Start-HDTRefresh.ps1 -SequenceId REFRESH

        The same run with the sequence named, so nobody is asked for it.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [AllowEmptyString()]
    [string] $SequenceId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- the share, worked out before anything can be imported --------------------
#
# THE ONE THING THIS FILE HAS TO DO FOR ITSELF, and LiteTouch.vbs has the same
# line for the same reason (sScriptDir, from WScript.ScriptFullName): the engine
# lives on the share, so the share has to be located before the engine can be
# asked anything. Get-HDTRefreshLaunchPlan re-derives it from $PSScriptRoot and
# it is the plan's answer that is used from there on - this is only enough to
# find the module.
#
# [IO.Path]::GetDirectoryName RATHER THAN Split-Path, because this routinely runs
# from a UNC path and the provider-aware cmdlets resolve the drive.
$shareRoot = [System.IO.Path]::GetDirectoryName($PSScriptRoot.TrimEnd('\', '/'))
$env:PSModulePath = '{0};{1}' -f ([System.IO.Path]::Combine($shareRoot, 'Modules')), $env:PSModulePath

Import-Module -Name 'powershell-yaml' -Force -ErrorAction Stop
Import-Module -Name 'Hephaestus' -Force -ErrorAction Stop

# -- what this session is, read through the adapter ---------------------------
#
# CLAUDE.md RULE 5. The system drive is what makes this run a REFRESH, so it is
# read through the one thing in HDT that reads an environment variable rather
# than through $env: - which is what lets the decision be tested at a desk.
$environment = New-HDTEnvironmentProvider
$systemDrive = [string] $environment.GetVariable('SystemDrive')

# THE ELEVATION CHECK IS READ HERE AND DECIDED IN THE PLAN. MDT asks the same
# question in the same place, by writing a file into %SystemRoot%; this asks
# Windows directly, which is the same fact without the side effect.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = ([Security.Principal.WindowsPrincipal] $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# -- every decision, in one call ----------------------------------------------
$plan = Get-HDTRefreshLaunchPlan -ScriptRoot $PSScriptRoot -SystemDrive $systemDrive `
    -IsElevated $isElevated -SequenceId $SequenceId

Write-Information ("HDT Refresh: share '{0}' ({1}), phase {2}, deployment type {3}" -f
    $plan.Root, $plan.WorkspaceId, $plan.Phase, $plan.DeploymentType) -InformationAction Continue

# -- the bootstrap document, beside the run's own state and logs --------------
#
# THE SAME FILE THE BOOT IMAGE CARRIES. Update-HDTBootImage bakes one into
# X:\HDT\bootstrap.json because a booting machine has no other way to be told
# where it is; this run already knows, because it is standing in the share. Same
# reader, same shape - so nothing downstream has to learn that this run started
# differently.
New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($plan.BootstrapPath)) -Force | Out-Null
Set-Content -LiteralPath $plan.BootstrapPath -Value $plan.BootstrapText -Encoding UTF8

# -- the screens, which default to a drive this machine does not have ---------
#
# THE SAME FILE startnet.cmd RUNS DEFAULTS ITS WINDOWS TO X:\HDT\UI\, because in
# WinPE that is where Update-HDTBootImage staged them and X: is the RAM disk's
# fixed letter. This machine never booted a WIM, so X: is not a drive at all -
# and until this line existed a Refresh inherited every one of those defaults and
# drew nothing: no wizard, no progress board, no failure screen.
#
# THE PLAN ANSWERS THEM OUT OF THE ENGINE ON THE SHARE, from the UI\ folder
# beside the payload about to be run, and it works the SET out by reading that
# payload's own param block rather than from a list. So a screen added to the
# engine tomorrow arrives here without this file changing - which is the whole
# reason six of them were wrong at once.
$uiArgument = $plan.UiArgument

Write-Information ("HDT Refresh: {0} screen(s) from '{1}'" -f @($uiArgument.Keys).Count, $plan.UiRoot) -InformationAction Continue

# -- the handover, once -------------------------------------------------------
#
# THE FILE startnet.cmd RUNS, and deliberately the same one. It derives the
# phase, scans for a run already in progress with -Phase, opens the wizard,
# resolves the rules and calls Invoke-HDTTaskSequence exactly once. A second
# full-OS entry point would be a second answer to "which one is running".
& $plan.PayloadPath -BootstrapPath $plan.BootstrapPath -ModuleRoot $plan.ModuleRoot -SequenceId $plan.SequenceId @uiArgument
