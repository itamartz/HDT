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

# -- the modules, brought to a local disk before anything imports them --------
#
# .NET FRAMEWORK WILL NOT LOAD AN ASSEMBLY FROM A SHARE, and until 2026-09-10
# this file asked it to. powershell-yaml's Invoke-LoadFile calls
# [Reflection.Assembly]::LoadFile() on YamlDotNet.dll; handed a UNC path .NET
# refuses it - "an attempt was made to load an assembly from a network location
# which would have caused the assembly to be sandboxed in previous versions of
# the .NET Framework ... please enable the loadFromRemoteSources switch" - and
# that switch lives in a .config file on the machine being deployed, which is
# not something a deployment tool may edit on somebody else's computer.
#
# IT COST M9 ITS EXIT CRITERION, AND IT FAILED SILENTLY. On the first real
# machine ever to run this, the import died with 0x8000FFFF E_UNEXPECTED before
# the engine existed to write a log: no Refresh started, no run folder appeared
# on the share, and the machine sat in the installation it was meant to replace
# with nothing on any volume to say why. The only record was the launcher's own
# stderr in C:\HDT.
#
# SO IT DOES WHAT WinPE HAS ALWAYS DONE. X:\HDT\Modules is a local copy the boot
# image carries, and that is the only reason every other leg imports cleanly;
# this gives the full-OS entry point the same local copy rather than a second
# mechanism. THE WHOLE FOLDER GOES ACROSS, not just the one module that happens
# to carry a DLL today - a step module shipping an assembly tomorrow would hit
# exactly this wall, and would hit it on somebody's production machine.
#
# THE SYSTEM DRIVE COMES FROM .NET AND NOT FROM $env:, because the environment
# adapter lives in the module this copy exists to make importable. It is a PATH
# and not a DECISION: the decision this file must not make for itself is the
# phase, and that is still read through New-HDTEnvironmentProvider below.
# <volume>\HDT is also the one folder CleanVolume keeps, so the staged copy
# survives the leg that empties the disk.
#
# New-Item -Force ON A DIRECTORY is create-or-leave-alone, which is how this
# stays branch-free - every branch belongs in Get-HDTRefreshLaunchPlan where a
# fake can drive it.
$moduleStage = [System.IO.Path]::Combine(
    [System.IO.Path]::GetPathRoot([System.Environment]::SystemDirectory), 'HDT', 'Modules')

New-Item -Path $moduleStage -ItemType Directory -Force | Out-Null

# A LOCKED FILE HERE IS NOT A FAILURE, AND STOPPING ON ONE BREAKS THE RETRY.
#
# A full-OS run that FAILS does not end the process - the engine holds the
# machine so the failure can be read - so the PowerShell that ran it stays alive
# holding YamlDotNet.dll and PowerShellYamlSerializer.dll open. The
# administrator's next move is to run this launcher again, and a -Force copy
# onto a loaded assembly throws "the process cannot access the file ... because
# it is being used by another process". That turns a readable deployment failure
# into an unreadable one about file sharing.
#
# A FILE THAT IS LOCKED IS A FILE THAT ALREADY LOADED, which is the only
# property this copy exists to produce - so skipping it loses nothing. What
# would lose something is staging nothing at all, and that is not silent:
# Get-HDTRefreshLaunchPlan tests for the payload under this exact folder and
# refuses by name if it is not there.
# robocopy AND NOT Copy-Item, BECAUSE A FILE THAT IS ALREADY RIGHT MUST NOT BE
# REWRITTEN.
#
# The machine usually HAS this copy already - Copy-HDTResumeAgent stages the
# same Modules\ tree from the boot image - so a -Force copy overwrites a
# YamlDotNet.dll that is byte-for-byte what is wanted, and then imports it
# microseconds later. That race is real: on 2026-09-10 the launcher died with
# "Catastrophic failure (E_UNEXPECTED)" loading a LOCAL, correct, identical DLL,
# and the identical launcher run again a minute later loaded it without
# complaint. Nothing about the file was wrong; it had just been rewritten.
#
# robocopy SKIPS SAME SIZE AND SAME TIMESTAMP, so the common case copies
# nothing at all and there is no rewrite to race. /E takes the tree,
# /R:1 /W:1 stops it retrying a locked file for thirty seconds each, and the
# rest silence a log nobody reads.
#
# ITS EXIT CODES ARE NOT PROCESS EXIT CODES. Anything under 8 is success -
# 0 copied nothing, 1 copied something, 2 found extras, 3 both. 8 and above are
# real failures, and they are NOT thrown here for the reason the locked-file
# note above gives: Get-HDTRefreshLaunchPlan tests for the payload under this
# folder and refuses by name if the staging genuinely did not happen.
& "$env:SystemRoot\System32\robocopy.exe" `
    ([System.IO.Path]::Combine($shareRoot, 'Modules')) $moduleStage `
    '/E' '/R:1' '/W:1' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null

$env:PSModulePath = '{0};{1}' -f $moduleStage, $env:PSModulePath

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
# -ModuleRoot IS THE STAGED COPY THIS FILE ALREADY IMPORTED FROM, and handing it
# over is not optional. The plan's ModuleRoot is what the payload imports from,
# so a plan left to name the share would put the assembly-over-UNC failure one
# layer down - in Start-HDTDeployment.ps1, after this file had already printed
# that it was a REFRESH and looked like it was working.
$plan = Get-HDTRefreshLaunchPlan -ScriptRoot $PSScriptRoot -SystemDrive $systemDrive `
    -IsElevated $isElevated -SequenceId $SequenceId -ModuleRoot $moduleStage

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
