<#
    .SYNOPSIS
        Stops the leg that is running out of C:\HDT, removes the folder, and
        performs the finish action the technician asked for.

    .DESCRIPTION
        THE LAST THING A DEPLOYMENT DOES, AND IT CANNOT BE DONE BY THE
        DEPLOYMENT. Start-HDTResume.ps1 runs FROM C:\HDT: it prepends
        C:\HDT\Modules to PSModulePath so ConvertFrom-HDTYaml can find
        powershell-yaml there, and powershell-yaml LoadFile()s
        C:\HDT\Modules\powershell-yaml\lib\net47\YamlDotNet.dll. Windows
        PowerShell 5.1 cannot unload an assembly for the life of a process, so
        that one file is held open until the leg exits - and a recursive delete
        from inside throws part way through and leaves a HALF-DELETED tree,
        which is worse than the folder it was trying to remove.

        SO THE PARENT IS KILLED FIRST AND THE TREE GOES SECOND. This script is
        copied OUT of the doomed folder into %TEMP% and started detached, so
        nothing it needs lives in what it is about to delete.

        AND THE FINISH ACTION COMES WITH IT. The parent is dead by the time the
        tree goes, so the parent cannot be what restarts the machine: it would
        have to do that BEFORE the delete, and the machine would go down with
        C:\HDT still on it. A restart, a shutdown or nothing at all is therefore
        decided here, last, and it happens even when the delete failed - a
        deployment that succeeded must not end with a technician walking over to
        a machine that never powered down.

        IT REFUSES ANY TARGET THAT IS NOT THE STAGING ROOT. This runs detached
        and elevated with a path handed to it on a command line, which is the
        single most dangerous shape in this repository. CLAUDE.md's rule is that
        nothing passes a variable to a recursive delete without asserting first
        that it is the thing it meant, so the path must be rooted, must not be a
        drive or share root, and must CONTAIN Start-HDTResume.ps1 - the file
        Copy-HDTResumeAgent stages. A folder merely named HDT is somebody else's.

        THE THREE ACTIONS ARE INJECTED so all of the above is provable from a
        desk (tests/unit/RemoveHDTAgentTreePayload.Tests.ps1). Their defaults
        are the real Stop-Process, Remove-Item and shutdown.exe calls and are
        branch-free, exactly as an adapter must be; every decision - the
        refusal, the order, what happens when the delete throws - is in this
        file and is tested.

        DERIVED FROM PSD (MIT), AND FROM MDT BEFORE IT. PSDStart.ps1:1005 copies
        PSDFinal.ps1 out to $env:TEMP and :1033 starts it with -ParentPID;
        PSDFinal.ps1:30 stops that process before :53-62 removes the tree and
        :71-84 performs the finish action. MDT's LiteTouch.wsf:1257-1259 does
        the same in VBScript. See NOTICE.md.

    .PARAMETER Path
        The staged agent folder to remove. C:\HDT on a deployed machine.

    .PARAMETER DriverPath
            The staged driver folder to remove as well - <os volume>\Drivers.
            Empty means there is nothing to remove. Refused unless it is rooted,
            exists, and its last segment is exactly 'Drivers'.

    .PARAMETER ParentProcessId
        The process holding the tree open - the leg that started this one. Zero
        means there is none to stop.

    .PARAMETER FinishAction
        What the machine does once the folder is gone: Restart, Stop, Logoff or
        None. Get-HDTFinishAction has already resolved MDT's REBOOT / SHUTDOWN /
        LOGOFF spellings to these by the time they reach here.

    .PARAMETER DelaySecond
        How long shutdown.exe waits before acting.

    .PARAMETER StopParent
        How the parent is stopped. Defaults to Stop-Process; a test passes a
        recorder.

    .PARAMETER RemoveTree
        How the folder is removed. Defaults to Remove-Item -Recurse.

    .PARAMETER Finish
        How the power state is produced. Defaults to shutdown.exe.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
            -File "$env:TEMP\Remove-HDTAgentTree.ps1" -Path C:\HDT -ParentProcessId 4242 -FinishAction Restart

        What Remove-HDTResumeAgent starts once the logs are safe and the share
        credential has been destroyed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [AllowNull()]
    [string] $Path,

    [Parameter()]
    [AllowEmptyString()]
    [AllowNull()]
    [string] $DriverPath,

    [Parameter()]
    [int] $ParentProcessId = 0,

    [Parameter()]
    [AllowEmptyString()]
    [string] $FinishAction = 'None',

    [Parameter()]
    [int] $DelaySecond = 0,

    [Parameter()]
    [AllowNull()]
    [scriptblock] $StopParent,

    [Parameter()]
    [AllowNull()]
    [scriptblock] $RemoveTree,

    [Parameter()]
    [AllowNull()]
    [scriptblock] $Finish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- the adapters, and they are the only branch-free thing here ---------------

if ($null -eq $StopParent) {
    $StopParent = {
        param([int] $ProcessId)

        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    }
}

if ($null -eq $RemoveTree) {
    $RemoveTree = {
        param([string] $Target)

        # -LiteralPath to the one directory the guard above has already proved
        # is a staged agent, which is what CLAUDE.md's delete rule requires.
        Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop
    }
}

if ($null -eq $Finish) {
    $Finish = {
        param([string] $Action, [int] $Second)

        switch ($Action) {
            'Restart' { & "$env:SystemRoot\System32\shutdown.exe" '/r' '/t' ([string] $Second) '/f' }
            'Stop' { & "$env:SystemRoot\System32\shutdown.exe" '/s' '/t' ([string] $Second) '/f' }
            'Logoff' { & "$env:SystemRoot\System32\shutdown.exe" '/l' }
        }
    }
}

# -- the refusal, before anything at all --------------------------------------
#
# BEFORE THE PARENT IS EVEN STOPPED. A path that arrived wrong must not first
# take the deployment's own process down with it: the leg is then dead, the
# folder is still there, and nothing is left to report either fact.

function Assert-HDTAgentTreeTarget {
    <#
        .SYNOPSIS
            Throws unless the path is a staged resume agent and nothing else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Target
    )

    $refused = "HDTCleanupRefused: '{0}' {1} This script deletes a directory tree recursively and only ever deletes the one Copy-HDTResumeAgent staged."

    if ([string]::IsNullOrWhiteSpace($Target)) {
        throw ($refused -f $Target, 'is empty, so there is nothing it could name.')
    }

    $trimmed = $Target.Trim()

    # ROOTED, OR IT IS A GUESS. A relative path resolves against whatever
    # directory this process happens to have started in, which on a detached
    # process is not a directory anybody chose.
    if (-not [System.IO.Path]::IsPathRooted($trimmed)) {
        throw ($refused -f $trimmed, 'is not a rooted path, so what it names depends on where this process started.')
    }

    # NOT VIA GetFullPath ON THE RAW VALUE. 'C:' is rooted and resolves to the
    # process's current directory ON C:, which is a different folder from the
    # one the caller typed - so the drive-shaped spellings are refused by shape
    # before any resolution happens.
    if ($trimmed -match '^[A-Za-z]:$') {
        throw ($refused -f $trimmed, 'names a drive rather than a folder on it.')
    }

    $full = [System.IO.Path]::GetFullPath($trimmed)
    $stripped = $full.TrimEnd('\', '/')

    if ([string]::IsNullOrWhiteSpace($stripped) -or $stripped -match '^[A-Za-z]:$') {
        throw ($refused -f $full, 'is a drive root.')
    }

    # A UNC SHARE ROOT HAS NO PARENT EITHER, and \\server\share is two segments
    # rather than one, so GetDirectoryName is what tells them apart.
    $parent = [System.IO.Path]::GetDirectoryName($stripped)

    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw ($refused -f $full, 'has no parent directory, so it is a volume or a share root.')
    }

    # AND THE ANSWER THAT ACTUALLY DECIDES IT. Every check above is about shape;
    # this one is about identity. A folder that does not carry the staged agent
    # is not the staged agent, whatever it is called and wherever it is.
    $agent = [System.IO.Path]::Combine($stripped, 'Start-HDTResume.ps1')

    if (-not (Test-Path -LiteralPath $agent -PathType Leaf)) {
        throw ($refused -f $full, ("does not hold a staged resume agent - there is no Start-HDTResume.ps1 in it."))
    }

    return $stripped
}

function Assert-HDTAgentDriverTarget {
    <#
        .SYNOPSIS
            Answers whether a path is a staged driver folder this may remove.

        .DESCRIPTION
            THE SAME JOB Assert-HDTAgentTreeTarget DOES, FOR THE OTHER FOLDER.
            This script runs detached and elevated, with -Recurse -Force and
            nobody reading its output, so the one thing it must never do is take
            a path a caller got wrong. A DriverPath that arrived as the OS volume
            or C:\Windows would erase the machine it just built.

            THREE QUESTIONS, ALL OF THEM CHEAP. It has to be rooted, it has to
            exist, and its last segment has to be exactly 'Drivers' - which is
            the folder ApplyDrivers stages into and the one PSDFinal.ps1 removes.
            An empty path is not an error: it means the caller had nothing to
            remove, which is every deployment that staged no drivers.

        .PARAMETER Target
            The candidate path.

        .OUTPUTS
            System.String. The path when it may be removed, '' when it may not.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Target
    )

    if ([string]::IsNullOrWhiteSpace($Target)) { return '' }

    $trimmed = $Target.Trim().TrimEnd('\', '/')

    if (-not [System.IO.Path]::IsPathRooted($trimmed)) { return '' }
    if ([System.IO.Path]::GetFileName($trimmed) -ne 'Drivers') { return '' }
    if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) { return '' }

    return $trimmed
}

$target = Assert-HDTAgentTreeTarget -Target $Path
$driverTarget = Assert-HDTAgentDriverTarget -Target $DriverPath

if (-not $PSCmdlet.ShouldProcess($target, 'Stop the deployment leg and remove the staged resume agent')) {
    return
}

# -- the parent, which is what holds the tree open ----------------------------
#
# A PARENT THAT HAS ALREADY GONE IS NOT AN ERROR. The leg may have exited on its
# own between handing this job over and this process starting, and a
# Stop-Process that finds nothing must not become the reason C:\HDT survives.
if ($ParentProcessId -gt 0) {
    try {
        & $StopParent $ParentProcessId
    } catch {
        Write-Information ("the deployment leg (process {0}) could not be stopped: {1}" -f
            $ParentProcessId, $_.Exception.Message)
    }
}

# -- and now the folder -------------------------------------------------------
#
# THE FAILURE IS NOT ALLOWED TO REACH THE FINISH ACTION. Nobody is reading this
# process's output - it was started detached, with no window - so a throw here
# would silently cost the machine its restart as well as its cleanup.
try {
    & $RemoveTree $target
} catch {
    Write-Information ("'{0}' could not be removed: {1}" -f $target, $_.Exception.Message)
}

# -- and the staged drivers, which the machine is finished with ---------------
#
# 4.2 GB ON A REAL LATITUDE, 1,452 files, still there after the deployment
# finished. ApplyDrivers stages packages to <os volume>\Drivers so the answer
# file's DriverPaths can inject them offline; once Windows has installed from
# them the folder is dead weight on a machine somebody is about to be handed.
#
# PSD REMOVES IT BESIDE MININT (PSDFinal.ps1:53-62). HDT's MININT is the folder
# removed just above, so this is the same pass.
#
# SEPARATELY GUARDED AND SEPARATELY CAUGHT. A driver folder that will not go is
# a smaller problem than a machine that never restarts, and it must not cost the
# finish action any more than the agent tree may.
if (-not [string]::IsNullOrWhiteSpace($driverTarget)) {
    try {
        & $RemoveTree $driverTarget
    } catch {
        Write-Information ("'{0}' could not be removed: {1}" -f $driverTarget, $_.Exception.Message)
    }
}

# -- what the machine does now -----------------------------------------------
#
# LAST, AND WHATEVER HAPPENED ABOVE. MDT's FinishAction, moved here because the
# process that used to own it is the one this script has just killed.
& $Finish $FinishAction $DelaySecond
