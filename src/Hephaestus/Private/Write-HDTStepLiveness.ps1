function Write-HDTStepLiveness {
    <#
        .SYNOPSIS
            Writes the one kind of step.progress record that says "still alive"
            rather than "this far through", and tells the window to look. Never
            fails a deployment.

        .DESCRIPTION
            step.progress CARRIES TWO DIFFERENT THINGS ON PURPOSE. One is a
            measurement - dism's percentage, "installing 1 of 2", packages
            staged - and the other is a sign of life from a step that has
            nothing to count. Get-HDTDeploymentProgress reads `percent` off a
            step.progress record CONDITIONALLY, precisely so the second kind
            leaves the bar where the last real measurement put it instead of
            dragging it back to zero every fifteen seconds in the middle of an
            apply that was 70% done. New-HDTStepHeartbeat spells out why this
            reuses step.progress and adds no second event name.

            BUT THE ABSENCE OF A FIELD IS NOT SOMETHING A READER CAN FILTER ON.
            A record carrying no percent and no mark sits in the measurement
            stream looking exactly like a measurement, so `heartbeat = true` is
            what makes the second kind readable at all - and
            StepProgress.Contract.Tests.ps1 asserts that every record a
            reporting step writes says which of the two it is.

            THIS EXISTS BECAUSE THAT MARK HAD THREE AUTHORS. New-HDTStepHeartbeat
            wrote it; then Sysprep wrote one by hand before sysprep /generalize,
            and EnableBitLocker wrote one per poll of a volume that reports no
            completion figure. Both were right to write a liveness record - and
            both were spelling out a shape that has to mean the same thing to
            every reader of the log, which the third one would have spelt
            differently.

            WHAT THIS OWNS AND WHAT IT DOES NOT. It owns the record: the event
            name, the mark, and the nudge that makes the display re-read the log
            afterwards - the half that was missing from ApplyDrivers, where the
            record went to the JSONL and nothing read it back.
            New-HDTStepHeartbeat still owns the INTERVAL and the rationing, and
            calls this for each line it decides to write. A step therefore gets
            to say "still alive" at a moment it genuinely knows about - Sysprep
            knows exactly when it is about to hand the machine to a program that
            prints nothing for minutes - and gets no say in what that record
            looks like, nor any excuse to invent a cadence of its own.

            THE CALLER'S OWN FIELDS SURVIVE. Which volume, which executable, how
            many minutes: a liveness record still carries whatever the step
            actually knows, and a shared writer that flattened that away would
            trade one defect for a worse one. Only `heartbeat` is added.

            IT NEVER FAILS A DEPLOYMENT. Same contract as
            Update-HDTProgressDisplay and New-HDTStepHeartbeat, and for the same
            reason: this runs on a machine part-way through building itself. A
            log file that went with the RAM disk, a UI runspace that has died, a
            context that never had a log - none of them is a reason to stop
            building a computer, and a line about how it is getting on does not
            get to be the thing that stops it.

        .PARAMETER Context
            The execution context. Context.Log is written to and
            Context.Service.Progress is nudged; both may be absent, and a
            context that cannot carry a record writes nothing.

        .PARAMETER Component
            The component the record is written under, which is the step type:
            'Sysprep', 'EnableBitLocker', 'InstallApplications'.

        .PARAMETER Message
            The line a technician reads on the progress card. Something true and
            changing - what is being waited on, and how long it has been - never
            a spinner, and never a command line: DESIGN 4.4.5 keeps those at
            Debug because they routinely carry a licence key, and this record is
            written at Info.

        .PARAMETER Data
            The fields the step itself knows, in the order they should be read.
            The mark is appended to them.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None.

        .EXAMPLE
            Write-HDTStepLiveness -Context $Context -Component 'Sysprep' `
                -Message 'generalizing this machine; sysprep reports nothing until it is finished' `
                -Data ([ordered] @{ activity = 'sysprep /generalize'; file = $sysprepExe })

            The whole of what a step has to do to report a sign of life once, at
            a moment it knows about.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Data
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        # A CONTEXT WITH NO LOG WRITES NOTHING AND SAYS SO TO NOBODY. Checked
        # through PSObject.Properties rather than by reading the property,
        # because StrictMode makes the absence of one an exception.
        $log = $null
        if ($null -ne $Context -and $null -ne $Context.PSObject.Properties['Log']) {
            $log = $Context.Log
        }

        if ($null -eq $log) { return }

        # THE CALLER'S ORDER IS THE READER'S ORDER, and the mark goes last: what
        # the step knows is what a technician scanning the JSONL is looking for,
        # and `heartbeat` is a flag for a filter rather than a fact about the
        # machine.
        $payload = [ordered] @{}
        if ($null -ne $Data) {
            foreach ($key in $Data.Keys) { $payload[[string] $key] = $Data[$key] }
        }

        $payload['heartbeat'] = $true

        Write-HDTLog -Context $log -Event 'step.progress' -Component $Component `
            -Message $Message -Data $payload

        # AND THEN TELL THE WINDOW TO LOOK. A record written to a JSONL that
        # nothing reads back draws nothing, which is the state ApplyDrivers
        # shipped in; keeping the nudge here means no call site can forget it.
        Update-HDTProgressDisplay -Context $Context
    } catch {
        Write-Verbose ("the step liveness record could not be written: {0}" -f [string] $_.Exception.Message)
    }
}
