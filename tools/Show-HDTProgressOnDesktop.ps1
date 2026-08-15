<#
    .SYNOPSIS
        Runs DESIGN 11.1's progress window on THIS desktop against a replayed
        deployment, so it can be watched without building a boot image.

    .DESCRIPTION
        THE SAME PATH WinPE TAKES. Start-HDTProgressDisplay decides whether
        there is a window, New-HDTProgressHost runs it in its own runspace, and
        Get-HDTDeploymentProgress derives every value on screen from log records
        of exactly the shape the engine writes (DESIGN 4.4.2). Nothing here
        renders anything itself.

        THE RECORDS ARE REPLAYED, NOT INVENTED FOR THE SCREEN. This script
        appends the same events a real run appends - run.start, step.start,
        step.complete, phase.change, run.end - and hands the whole stream so far
        to the same command the engine would. If the window shows something
        wrong, the fault is in the derivation or the markup, not in a preview
        that took a shortcut.

        IT IS A TOOL, NOT PRODUCT CODE. It lives in tools\ and ships in no boot
        image.

    .PARAMETER StepSecond
        How long each step appears to take, in real seconds.

    .PARAMETER Fail
        Fail the third step, to see the status line in red.

    .EXAMPLE
        ./tools/Show-HDTProgressOnDesktop.ps1

    .EXAMPLE
        ./tools/Show-HDTProgressOnDesktop.ps1 -Fail
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $StepSecond = 2,

    [Parameter()]
    [switch] $Fail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force

$xamlPath = Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/UI/HDTProgress.xaml'

# A sequence with the shape a real one has: WinPE work, a reboot, full-OS work.
$step = @(
    @{ Index = 1; Name = 'Validate the machine'; Type = 'Validate'; Phase = 'WinPE' }
    @{ Index = 2; Name = 'Partition disk 0'; Type = 'DiskPartition'; Phase = 'WinPE' }
    @{ Index = 3; Name = 'Apply Windows 11 Enterprise LTSC 2024'; Type = 'ApplyImage'; Phase = 'WinPE' }
    @{ Index = 4; Name = 'Apply the unattend'; Type = 'ApplyUnattend'; Phase = 'WinPE' }
    @{ Index = 5; Name = 'Configure the boot volume'; Type = 'ConfigureBoot'; Phase = 'WinPE' }
    @{ Index = 6; Name = 'Restart into the full operating system'; Type = 'Restart'; Phase = 'WinPE' }
    @{ Index = 7; Name = 'Install applications'; Type = 'InstallApplications'; Phase = 'FullOS' }
    @{ Index = 8; Name = 'Join corp.contoso.com'; Type = 'JoinDomain'; Phase = 'FullOS' }
)

$record = New-Object -TypeName System.Collections.ArrayList
$second = 0
$seq = 0

function Add-HDTPreviewRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Appends to an in-memory list in a preview tool; it changes no state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Event,

        [Parameter()]
        [string] $Phase = 'WinPE',

        [Parameter()]
        [AllowNull()]
        [hashtable] $Data,

        [Parameter()]
        [int] $StepIndex = 0,

        [Parameter()]
        [AllowEmptyString()]
        [string] $StepName = '',

        [Parameter()]
        [AllowEmptyString()]
        [string] $StepType = ''
    )

    $script:seq++

    $row = [ordered] @{
        ts        = ([datetime]::UtcNow).AddSeconds(- ($script:total - $script:second)).ToString('o')
        runId     = 'preview'
        seq       = $script:seq
        level     = 'Info'
        phase     = $Phase
        component = 'Engine'
        event     = $Event
        message   = $Event
    }

    if ($StepIndex -gt 0) {
        $row['stepIndex'] = $StepIndex
        $row['stepName'] = $StepName
        $row['stepType'] = $StepType
    }

    if ($null -ne $Data) { $row['data'] = $Data }

    [void] $script:record.Add([pscustomobject] $row)
}

# Elapsed on screen is derived from the RECORDS, so the timestamps have to move
# as the replay does rather than all being 'now'.
$total = $step.Count * $StepSecond

$display = Start-HDTProgressDisplay -XamlPath $xamlPath

Write-Information ("progress display mode: {0} {1}" -f $display.Mode, $display.Reason) -InformationAction Continue

if ($display.Mode -ne 'Window') {
    Write-Information 'no window - nothing to look at. That is the console fallback working.' -InformationAction Continue
    return $display
}

$display.DisplayHost.SetComputerName('HDT-LAB-01')

Add-HDTPreviewRecord -Event 'run.start' -Data @{ sequenceId = 'STD-CLIENT'; stepIndex = 0; stepCount = $step.Count; leg = 1 }
$display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))

try {
    foreach ($current in $step) {

        if ($current.Phase -eq 'FullOS' -and $script:record[-1].phase -ne 'FullOS') {
            Add-HDTPreviewRecord -Event 'phase.change' -Phase $current.Phase -Data @{ from = 'WinPE'; to = 'FullOS' }
        }

        Add-HDTPreviewRecord -Event 'step.start' -Phase $current.Phase -StepIndex $current.Index `
            -StepName $current.Name -StepType $current.Type `
            -Data @{ index = $current.Index; name = $current.Name; type = $current.Type; attempt = 1 }

        $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))
        Start-Sleep -Seconds $StepSecond
        $second += $StepSecond

        if ($Fail -and $current.Index -eq 3) {
            Add-HDTPreviewRecord -Event 'step.fail' -Phase $current.Phase -StepIndex $current.Index `
                -StepName $current.Name -StepType $current.Type -Data @{ index = $current.Index; attempt = 1 }

            Add-HDTPreviewRecord -Event 'run.end' -Phase $current.Phase -Data @{ status = 'Failed' }
            $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))

            Write-Information 'the run failed at step 3 - leaving it on screen for 10 seconds' -InformationAction Continue
            Start-Sleep -Seconds 10
            return
        }

        Add-HDTPreviewRecord -Event 'step.complete' -Phase $current.Phase -StepIndex $current.Index `
            -StepName $current.Name -StepType $current.Type -Data @{ index = $current.Index; attempt = 1; exitCode = 0 }

        $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))
    }

    Add-HDTPreviewRecord -Event 'run.end' -Phase 'FullOS' -Data @{ status = 'Succeeded' }
    $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))

    Write-Information 'done - leaving it on screen for 10 seconds' -InformationAction Continue
    Start-Sleep -Seconds 10
} finally {
    # THE WINDOW IS FULL SCREEN AND HAS NO WAY OUT OF IT, so a preview that
    # threw without this would leave a technician - or a developer - looking at
    # a status board with no keyboard route off it.
    $display.DisplayHost.Close()
}
