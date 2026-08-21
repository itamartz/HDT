function Get-HDTDeploymentFailure {
    <#
        .SYNOPSIS
            What to tell the technician about a deployment that failed, derived
            from the log the engine already wrote.

        .DESCRIPTION
            A MACHINE THAT FAILED USED TO SAY NOTHING TO THE PERSON STANDING IN
            FRONT OF IT. The reason went into the JSONL, a FATAL line went into
            a console the payload had hidden, and five seconds later wpeutil
            powered the machine off. Everything needed to fix it was on a share,
            in a folder named after a computer that never finished being built,
            and the technician had a black screen.

            MDT SHOWS A SUMMARY DIALOG NAMING THE STEP. This is the derivation
            behind HDT's, and it is the same shape as Get-HDTDeploymentProgress
            deliberately: DESIGN 11.1's one source of truth is the event stream,
            so the failure screen reads the same records the progress screen
            does rather than being handed a second version of the story.

            THE REASON IS NOT SUMMARISED. The most useful sentence a technician
            can be shown is the one the step wrote - "disk 0 carries existing
            data on volume C (NTFS), D (NTFS), and the step did not declare that
            it may be replaced" contains the fix. Shortening it to "disk error"
            would leave them with the log to go and read anyway.

            A RUN THAT DIED BEFORE ANY STEP IS STILL A FAILURE WITH A SENTENCE.
            A share that could not be reached or a sequence that would not parse
            has no step to name, and the technician needs the reason more in that
            case rather than less.

        .PARAMETER Record
            The log records, oldest first, as ConvertTo-HDTLogRecord writes them
            - the same input Get-HDTDeploymentProgress takes.

        .PARAMETER LogPath
            Where the log will still be after this machine is powered off. Shown
            on the screen, because the RAM disk goes with the power.

        .PARAMETER Reason
            The sentence for a leg that ended before the engine wrote anything
            worth deriving from - a share that could not be opened, a sequence
            that would not parse. It forces the failure and becomes the message,
            because it IS the error that ended the leg: any step.fail in the
            records is the older story.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with IsFailure, RunId,
            SequenceId, StepNumber, StepCount, StepName, StepType, Message,
            Status, LogPath and Field.

        .EXAMPLE
            $failure = Get-HDTDeploymentFailure -Record $record -LogPath $log.LogPath
            if ($failure.IsFailure) { Show-HDTDeploymentFailure -Failure $failure }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Record,

        [Parameter()]
        [AllowEmptyString()]
        [string] $LogPath = '',

        # A LEG CAN FAIL BEFORE IT HAS A LOG TO FAIL IN. The full-OS payload
        # builds its run log context AFTER it imports the sequence, so a
        # sequence that will not open leaves this command an empty record set
        # and a technician a window with no headline, no reason and a step line
        # reading 'before the first step' under a heading that is not shown at
        # all. Watched on 2026-08-21: the leg died on the import, drew nothing,
        # and logged nothing.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Reason = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE SAME READER Get-HDTDeploymentProgress USES, and for the same reason: a
    # record may arrive as a dictionary the engine built or as an object
    # ConvertFrom-Json made, and a hashtable's keys are not its properties.
    $valueOf = {
        param([object] $Row, [string] $Name)

        if ($null -eq $Row) { return $null }

        if ($Row -is [System.Collections.IDictionary]) {
            if (-not $Row.Contains($Name)) { return $null }
            return $Row[$Name]
        }

        if ($null -eq $Row.PSObject.Properties[$Name]) { return $null }

        return $Row.$Name
    }

    $result = [ordered] @{
        Pane       = @()
        IsFailure  = $false
        RunId      = ''
        SequenceId = ''
        StepNumber = 0
        StepCount  = 0
        StepName   = ''
        StepType   = ''
        Message    = ''
        Status     = ''
        LogPath    = $LogPath
    }

    foreach ($row in @($Record)) {

        $runId = [string] (& $valueOf $row 'runId')
        if (-not [string]::IsNullOrWhiteSpace($runId)) { $result['RunId'] = $runId }

        $eventName = [string] (& $valueOf $row 'event')
        if ([string]::IsNullOrWhiteSpace($eventName)) { continue }

        $data = & $valueOf $row 'data'

        switch ($eventName) {

            'run.start' {
                $sequenceId = [string] (& $valueOf $data 'sequenceId')
                if (-not [string]::IsNullOrWhiteSpace($sequenceId)) { $result['SequenceId'] = $sequenceId }

                $stepCount = & $valueOf $data 'stepCount'
                if ($null -ne $stepCount) { $result['StepCount'] = [int] $stepCount }
            }

            'step.fail' {
                # THE LAST FAILURE WINS. A step that was retried fails more than
                # once, and the attempt that ended the run is the one on screen.
                $result['IsFailure'] = $true
                $result['Status'] = 'Failed'

                $index = & $valueOf $data 'index'
                if ($null -eq $index) { $index = & $valueOf $row 'stepIndex' }
                if ($null -ne $index) { $result['StepNumber'] = [int] $index }

                $name = [string] (& $valueOf $data 'name')
                if ([string]::IsNullOrWhiteSpace($name)) { $name = [string] (& $valueOf $row 'stepName') }
                $result['StepName'] = $name

                $type = [string] (& $valueOf $data 'type')
                if ([string]::IsNullOrWhiteSpace($type)) { $type = [string] (& $valueOf $row 'stepType') }
                $result['StepType'] = $type

                $message = [string] (& $valueOf $row 'message')
                if (-not [string]::IsNullOrWhiteSpace($message)) { $result['Message'] = $message.Trim() }
            }

            'run.end' {
                $status = [string] (& $valueOf $data 'status')
                if (-not [string]::IsNullOrWhiteSpace($status)) { $result['Status'] = $status }
            }
        }
    }

    # run.end IS THE ENGINE'S OWN VERDICT, as it is for the progress screen: a
    # run that ended Failed with no step.fail - a teardown that failed after the
    # last step - is still a failure a technician must be shown.
    if ([string] $result['Status'] -eq 'Failed') { $result['IsFailure'] = $true }

    # AND A REASON GIVEN OUTRIGHT IS A FAILURE WHATEVER THE RECORDS SAY. The
    # caller passes one only when the leg was ended by something outside the
    # step loop, which no step.fail and no run.end will ever describe - so the
    # verdict is not up for derivation here.
    #
    # IT FILLS THE MESSAGE ONLY WHEN NOTHING ELSE DID. A step that failed was
    # recorded by the engine with the sentence the STEP wrote, which is more
    # specific than whatever the payload's catch was handed - and both payloads
    # pass a reason on every failing run, not just the ones that died early.
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $result['IsFailure'] = $true
        $result['Status'] = 'Failed'

        if ([string]::IsNullOrWhiteSpace([string] $result['Message'])) {
            $result['Message'] = $Reason.Trim()
        }
    }

    # -- what the window shows ----------------------------------------------

    # ONE WINDOW REPORTS BOTH OUTCOMES, and which headline it shows is a Pane
    # flag. MDT ends a deployment on a single Deployment Summary that states
    # which of the two happened; a second window for the good news would be a
    # second thing to keep in step with this one.
    #
    # NOT A FIELD. A Field sets text and cannot set a colour, and the failure
    # headline is #FFF48771 in the markup - so a success written into it comes
    # out in the colour that means "wrong" everywhere else in this product.
    # HDTFailure.xaml carries both headlines; this decides which is visible.
    $succeeded = ([string] $result['Status'] -eq 'Succeeded')

    $stepText = 'before the first step'

    # A RUN THAT WORKED HAS NO STEP TO NAME, so it names what it got through.
    # 'before the first step' under a green headline reads as a contradiction.
    if (-not $result['IsFailure'] -and [string]::IsNullOrWhiteSpace([string] $result['StepName'])) {
        $stepText = 'all steps completed'

        if ([int] $result['StepCount'] -gt 0) {
            $stepText = 'all {0} steps completed' -f [int] $result['StepCount']
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string] $result['StepName'])) {
        $stepText = [string] $result['StepName']

        if ([int] $result['StepCount'] -gt 0) {
            $stepText = '{0}  (step {1} of {2})' -f $stepText, [int] $result['StepNumber'], [int] $result['StepCount']
        }

        if (-not [string]::IsNullOrWhiteSpace([string] $result['StepType'])) {
            $stepText = '{0}  -  {1}' -f $stepText, [string] $result['StepType']
        }
    }

    $logText = [string] $result['LogPath']
    if ([string]::IsNullOrWhiteSpace($logText)) { $logText = '(no log destination was resolved)' }

    # AND THE REASON GOES WITH THE FAILURE. An empty 'Why' box under a green
    # headline is a question the window is asking itself.
    # THE BUTTONS ARE PART OF THE HEADLINE, and until now they were not.
    # A finished machine was offered Restart and Shut down - the failure
    # screen's pair - and Start-HDTResume.ps1 discarded the answer anyway, so a
    # technician could press Restart and watch the machine shut down because
    # HDTFinishAction said so.
    #
    # MDT'S DEPLOYMENT SUMMARY HAS ONE BUTTON: Finish. FinishAction decides what
    # the machine does next; the button says the person has read the screen. A
    # FAILED machine is a different question - Restart to try again, Shut down
    # to walk away - and keeps the pair it had.
    #
    # Open CMD IS ON BOTH AND IS NOT NAMED HERE. A pane entry for a control that
    # is always visible is a decision nobody asked for, and one more thing to
    # keep in step.
    $result['Pane'] = @(
        [pscustomobject] @{ Name = 'HDTFailureTitleText'; Visible = (-not $succeeded) }
        [pscustomobject] @{ Name = 'HDTFailureSuccessText'; Visible = $succeeded }
        [pscustomobject] @{ Name = 'HDTFailureReasonLabel'; Visible = (-not $succeeded) }
        [pscustomobject] @{ Name = 'HDTFailureReasonBox'; Visible = (-not $succeeded) }
        [pscustomobject] @{ Name = 'HDTFinishButton'; Visible = $succeeded }
        [pscustomobject] @{ Name = 'HDTNextButton'; Visible = (-not $succeeded) }
        [pscustomobject] @{ Name = 'HDTCancelButton'; Visible = (-not $succeeded) }
    )

    $result['Field'] = @(
        [pscustomobject] @{ Name = 'HDTFailureStepText'; Text = $stepText }
        [pscustomobject] @{ Name = 'HDTFailureMessageText'; Text = [string] $result['Message'] }
        [pscustomobject] @{ Name = 'HDTFailureLogText'; Text = $logText }
        [pscustomobject] @{ Name = 'HDTFailureSequenceText'; Text = [string] $result['SequenceId'] }
        [pscustomobject] @{ Name = 'HDTFailureRunText'; Text = [string] $result['RunId'] }
    )

    return [pscustomobject] $result
}
