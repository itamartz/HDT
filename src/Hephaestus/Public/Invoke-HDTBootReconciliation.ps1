function Invoke-HDTBootReconciliation {
    <#
        .SYNOPSIS
            Decides on every boot whether to resume the run or disarm the machine
            (DESIGN 4.5.2).

        .DESCRIPTION
            "Start-HDTResume.ps1 reconciles on every boot: if the state document
            says the run is finished, failed, or missing, it clears autologon,
            the LSA secret, the RunOnce entry, and C:\HDT\state.json BEFORE DOING
            ANYTHING ELSE."

            Four outcomes:

              the state file does not exist          Teardown  'no state document'
              it cannot be read or parsed            Teardown  'unreadable state document'
              Succeeded or Failed                    Teardown  'run finished'
              Running but stale past -MaxAgeHour     Teardown  'run abandoned'
              otherwise                              Resume    'resuming at step n'

            Teardown runs the full DESIGN 4.5.3 checklist through
            Clear-HDTAutoLogon and then removes the state file - in that order,
            so a crash between the two leaves a disarmed machine rather than an
            armed one with no state to reconcile against next time. It does not
            remove a state file that was not there.

            Resume increments the leg, logs one reboot.resume record, and returns
            the state. IT DOES NOT RUN THE SEQUENCE - the caller does, which is
            03-04's Start-HDTResume.ps1. Keeping the decision separate from the
            execution is what lets every branch above be proven against fakes.

            THE UNREADABLE CASE IS THE ONE PLACE Import-HDTRunState's throw IS
            CAUGHT, and it is deliberate: on a boot, a corrupt state document is
            not evidence that a run is alive. The safe reading is "disarm". It is
            also the only branch here that swallows an exception, so the parse
            message is logged at Warning rather than lost.

            WHY THIS MATTERS MORE THAN AutoLogonCount. SPIKES.md S8 measured the
            third backstop: Windows only disarms itself once the count is spent,
            so an abandoned run keeps autologging on for up to n more boots. This
            function is what turns that into one boot.

            Every time reading goes through -Clock. A test asserts that by
            reading this file's own text, which is why the cmdlet it forbids is
            not named here.

        .PARAMETER StatePath
            Where state.json lives. Normally C:\HDT\state.json.

        .PARAMETER FileSystem
            An IFileSystem.

        .PARAMETER Registry
            An IRegistryService.

        .PARAMETER Lsa
            An ILsaService.

        .PARAMETER Clock
            An IClock. The only source of the current time.

        .PARAMETER LogContext
            A log context. Without it the decision is still made and still acted
            on - a boot with no writable log is not a boot that gets to stay
            armed - but nothing is written.

        .PARAMETER UnattendPath
            Passed through to Clear-HDTAutoLogon.

        .PARAMETER MaxAgeHour
            How stale a Running state may be before the run counts as abandoned.
            Defaults to 12.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action
            ('Resume' or 'Teardown'), Reason and State.

        .EXAMPLE
            $decision = Invoke-HDTBootReconciliation -StatePath 'C:\HDT\state.json' `
                -FileSystem $fs -Registry $registry -Lsa $lsa -Clock $clock -LogContext $log

            if ($decision.Action -eq 'Resume') { ... }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $StatePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Registry,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Lsa,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [AllowNull()]
        [object] $LogContext,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $UnattendPath,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $MaxAgeHour = 12
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $teardownArgument = @{
        Registry   = $Registry
        Lsa        = $Lsa
        FileSystem = $FileSystem
        LogContext = $LogContext
    }
    if ($PSBoundParameters.ContainsKey('UnattendPath')) {
        $teardownArgument['UnattendPath'] = $UnattendPath
    }

    $state = $null
    $reason = $null
    $stateFileExists = $FileSystem.TestPath($StatePath)

    if (-not $stateFileExists) {
        $reason = 'no state document'
    } else {
        try {
            $state = Import-HDTRunState -Path $StatePath -FileSystem $FileSystem
        } catch {
            # The only swallowed exception in this function. A corrupt state
            # document is not evidence that a run is alive.
            $reason = 'unreadable state document'
            $state = $null

            if ($null -ne $LogContext) {
                Write-HDTLog -Context $LogContext -Event 'reboot.teardown' -Severity 'Warning' `
                    -Message ("State document '{0}' could not be read, disarming: {1}" -f $StatePath, $_.Exception.Message)
            }
        }
    }

    if ($null -eq $reason) {
        if (Test-HDTRunStateAbandoned -State $state -Clock $Clock -MaxAgeHour $MaxAgeHour) {
            $reason = 'run abandoned'
            if (@('Succeeded', 'Failed') -contains [string] $state.status) {
                $reason = 'run finished'
            }
        }
    }

    if ($null -ne $reason) {
        # Disarm FIRST, then drop the state file. A crash in between leaves a
        # machine that will not autologon, which is the safe half to be left in.
        Clear-HDTAutoLogon @teardownArgument -State $state | Out-Null

        if ($stateFileExists) {
            $FileSystem.RemoveItem($StatePath, $false)
        }

        return [pscustomobject] ([ordered] @{
                Action = 'Teardown'
                Reason = $reason
                State  = $null
            })
    }

    $state.leg = [int] $state.leg + 1
    $reason = 'resuming at step {0}' -f $state.stepIndex

    if ($null -ne $LogContext) {
        Write-HDTLog -Context $LogContext -Event 'reboot.resume' `
            -Message ("Resuming run {0} at step {1} on leg {2}" -f $state.runId, $state.stepIndex, $state.leg) `
            -Data ([ordered] @{
                runId     = $state.runId
                stepIndex = $state.stepIndex
                leg       = $state.leg
            })
    }

    return [pscustomobject] ([ordered] @{
            Action = 'Resume'
            Reason = $reason
            State  = $state
        })
}
