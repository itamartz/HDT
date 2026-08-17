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
        [string] $LogPath = ''
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

    # -- what the window shows ----------------------------------------------

    $stepText = 'before the first step'
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

    $result['Field'] = @(
        [pscustomobject] @{ Name = 'HDTFailureStepText'; Text = $stepText }
        [pscustomobject] @{ Name = 'HDTFailureMessageText'; Text = [string] $result['Message'] }
        [pscustomobject] @{ Name = 'HDTFailureLogText'; Text = $logText }
        [pscustomobject] @{ Name = 'HDTFailureSequenceText'; Text = [string] $result['SequenceId'] }
        [pscustomobject] @{ Name = 'HDTFailureRunText'; Text = [string] $result['RunId'] }
    )

    return [pscustomobject] $result
}
