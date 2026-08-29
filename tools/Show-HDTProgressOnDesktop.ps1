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

    .PARAMETER XamlPath
        The window. Point it at a file that is not there to watch DESIGN 11.1's
        CONSOLE FALLBACK instead - the path a boot image built without
        WinPE-NetFx takes, and the one nobody exercises until the night it
        matters.

    .EXAMPLE
        ./tools/Show-HDTProgressOnDesktop.ps1

    .EXAMPLE
        ./tools/Show-HDTProgressOnDesktop.ps1 -Fail

    .EXAMPLE
        ./tools/Show-HDTProgressOnDesktop.ps1 -XamlPath 'X:\nothing-here.xaml'

        The same replay with no window: styled console lines, and a deployment
        that carries on.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 30)]
    [int] $StepSecond = 2,

    [Parameter()]
    [switch] $Fail,

    [Parameter()]
    [AllowEmptyString()]
    [string] $XamlPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force

if ([string]::IsNullOrWhiteSpace($XamlPath)) {
    $XamlPath = Join-Path -Path $repoRoot -ChildPath 'src/Hephaestus/UI/HDTProgress.xaml'
}

# A sequence with the shape a real one has: WinPE work, a reboot, full-OS work.
$step = @(
    @{ Index = 1; Name = 'Validate the machine'; Type = 'Validate'; Phase = 'WinPE'
        Activity = 'checking the disk, the firmware and the network' }
    @{ Index = 2; Name = 'Partition disk 0'; Type = 'DiskPartition'; Phase = 'WinPE'
        Activity = 'creating S: W: R: on disk 0' }
    @{ Index = 3; Name = 'Apply Windows 11 Enterprise LTSC 2024'; Type = 'ApplyImage'; Phase = 'WinPE'
        Activity = 'applying Z:\OperatingSystems\Win11-LTSC-2024\sources\install.wim (index 1) to W:\: 45%' }
    @{ Index = 4; Name = 'Apply the unattend'; Type = 'ApplyUnattend'; Phase = 'WinPE'
        Activity = 'writing W:\Windows\Panther\unattend.xml' }
    @{ Index = 5; Name = 'Configure the boot volume'; Type = 'ConfigureBoot'; Phase = 'WinPE'
        Activity = 'bcdboot W:\Windows /s S: /f UEFI' }
    @{ Index = 6; Name = 'Restart into the full operating system'; Type = 'Restart'; Phase = 'WinPE'
        Activity = 'checkpointing state.json before the reboot' }
    @{ Index = 7; Name = 'Install applications'; Type = 'InstallApplications'; Phase = 'FullOS'
        Activity = 'installing 1 of 2: Acrobat Acrobat Reader DC 2600121771' }
    @{ Index = 8; Name = 'Join corp.contoso.com'; Type = 'JoinDomain'; Phase = 'FullOS'
        Activity = 'joining corp.contoso.com as OSDTEST01' }
)

$record = New-Object -TypeName System.Collections.ArrayList
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
        [string] $StepType = '',

        # The card's activity line reads the record's own message.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Message
    )

    $script:seq++

    $row = [ordered] @{
        ts        = ([datetime]::UtcNow).ToString('o')
        runId     = 'preview'
        seq       = $script:seq
        level     = 'Info'
        phase     = $Phase
        component = 'Engine'
        event     = $Event
        message   = $Event
    }

    if ($PSBoundParameters.ContainsKey('Message')) { $row['message'] = $Message }

    if ($StepIndex -gt 0) {
        $row['stepIndex'] = $StepIndex
        $row['stepName'] = $StepName
        $row['stepType'] = $StepType
    }

    if ($null -ne $Data) { $row['data'] = $Data }

    [void] $script:record.Add([pscustomobject] $row)
}

# EVERY RECORD IS STAMPED AS IT IS WRITTEN, AND THAT IS NOW THE WHOLE OF IT.
# The replay used to backdate them, because elapsed on screen was summed from
# the records' own timestamps and a replay whose records were all 'now' showed
# nothing moving. The window runs the clock itself against the step's start
# time, so a replay that sleeps between steps in real seconds shows real
# seconds on the card - which is also the only way this preview can show that
# the clock keeps moving while nothing is being written.

$display = Start-HDTProgressDisplay -XamlPath $XamlPath

Write-Information ("progress display mode: {0} {1}" -f $display.Mode, $display.Reason) -InformationAction Continue

# THE REPLAY DOES NOT CARE WHICH MODE IT GOT, and neither does the engine: the
# fallback is a HOST with the same Update, so there is no branch here to be
# wrong on the machines that take it.
$display.DisplayHost.SetComputerName('HDT-LAB-01')

# A window is worth leaving up to look at; a console has already scrolled past.
$dwell = 10
if ($display.Mode -ne 'Window') { $dwell = 0 }

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

        # WHAT THE STEP IS DOING, which is the card's activity line. A looping
        # step writes one of these per item; the preview writes one per step so
        # the line is exercised at all.
        Add-HDTPreviewRecord -Event 'step.progress' -Phase $current.Phase -StepIndex $current.Index `
            -StepName $current.Name -StepType $current.Type `
            -Message ($current.Activity) -Data @{ index = $current.Index; percent = 45 }

        $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))
        Start-Sleep -Seconds $StepSecond

        if ($Fail -and $current.Index -eq 3) {
            Add-HDTPreviewRecord -Event 'step.fail' -Phase $current.Phase -StepIndex $current.Index `
                -StepName $current.Name -StepType $current.Type -Data @{ index = $current.Index; attempt = 1 }

            Add-HDTPreviewRecord -Event 'run.end' -Phase $current.Phase -Data @{ status = 'Failed' }
            $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))

            Write-Information 'the run failed at step 3' -InformationAction Continue
            Start-Sleep -Seconds $dwell
            return
        }

        Add-HDTPreviewRecord -Event 'step.complete' -Phase $current.Phase -StepIndex $current.Index `
            -StepName $current.Name -StepType $current.Type -Data @{ index = $current.Index; attempt = 1; exitCode = 0 }

        $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))
    }

    Add-HDTPreviewRecord -Event 'run.end' -Phase 'FullOS' -Data @{ status = 'Succeeded' }
    $display.DisplayHost.Update((Get-HDTDeploymentProgress -Record @($record)))

    Write-Information 'done' -InformationAction Continue
    Start-Sleep -Seconds $dwell
} finally {
    # THE WINDOW IS FULL SCREEN AND HAS NO WAY OUT OF IT, so a preview that
    # threw without this would leave a technician - or a developer - looking at
    # a status board with no keyboard route off it.
    $display.DisplayHost.Close()
}
