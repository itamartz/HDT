function Get-HDTConsoleBuildProgress {
    <#
        .SYNOPSIS
            What the boot image build window shows for one progress report.

        .DESCRIPTION
            THIS IS THE SCREEN SOMEBODY WATCHES FOR TWO AND A HALF MINUTES, and
            the whole job of it is to say that something is happening and what.
            All of it used to be composed inside a DispatcherTimer, where nothing
            could reach it - and every rule below was learned by watching a real
            build rather than by reasoning about one.

            THE DETAIL GOES ON THE LOG LINE, NOT ONLY IN THE LABEL. Step 8
            reports once per cab, and a line carrying the title alone printed
            "Applying the optional components" nineteen times - which says the
            build is moving and refuses to say what it is moving through. The
            cab's name is the entire value of reporting per component, and it is
            what says WHICH one was being applied if the build dies inside that
            step.

            THE PER-STEP CLOCK RESTARTS ON A NEW STEP TITLE, NOT ON EVERY REPORT.
            Step 8 reports nineteen times; a clock reset by each of those would
            never show that the step as a whole has been running for a minute -
            and that is the one number separating "working" from "hung".

            BOTH CLOCKS, because they answer different questions. The total says
            how long there is left to wait; the per-step says whether anything is
            happening at all. A window with only the total is one somebody kills
            at ninety seconds because it looks stuck.

            A FINISHED BUILD FILLS THE BAR. A bar left at eleven of twelve on a
            build that succeeded reads as one that stopped short, which is the
            opposite of what happened.

            IT DRAWS NOTHING. The caller assigns these strings to its controls,
            picks the failure brush when IsFailure says so, and restarts its own
            clock when RestartStepClock does.

        .PARAMETER Report
            One progress report from the build: Title, Detail, Step, Total,
            IsComplete and Succeeded.

        .PARAMETER Elapsed
            How long the whole build has been running.

        .PARAMETER OnStep
            How long the current step has been running.

        .PARAMETER StepText
            The title currently on screen, to notice a new step by.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Finished          the build reported completion
              IsFailure         it completed and did not succeed
              StepText          the step label
              DetailText        the detail label
              CountText         'step N of M', '' when finished
              ElapsedText       the clock line
              BarValue          where the bar sits
              BarMaximum        what it sits out of
              LogLine           the row to append to the log
              RestartStepClock  this report begins a new step
              CloseEnabled      whether Close is live yet

        .EXAMPLE
            Get-HDTConsoleBuildProgress -Report $report -Elapsed $elapsed -OnStep $onStep -StepText $book.StepText

        .EXAMPLE
            $show = Get-HDTConsoleBuildProgress -Report $report -Elapsed $elapsed -OnStep $onStep -StepText $book.StepText
            $stepText.Text = $show.StepText
            [void] $line.Add($show.LogLine)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Report,

        [Parameter(Mandatory = $true)]
        [timespan] $Elapsed,

        [Parameter()]
        [timespan] $OnStep = [timespan]::Zero,

        [Parameter()]
        [AllowEmptyString()]
        [string] $StepText = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $title = [string] $Report.Title
    $detail = [string] $Report.Detail

    if ([bool] $Report.IsComplete) {
        $succeeded = [bool] $Report.Succeeded

        # A FINISHED BUILD FILLS THE BAR. See the note above.
        $total = [double] $Report.Total
        if ($total -le 0) { $total = 1 }

        $label = 'Finished'
        $row = '{0:mm\:ss}  done - {1}' -f $Elapsed, $detail

        if (-not $succeeded) {
            $label = 'Failed'
            $row = '{0:mm\:ss}  FAILED - {1}' -f $Elapsed, $detail
        }

        return [pscustomobject] @{
            Finished         = $true
            IsFailure        = (-not $succeeded)
            StepText         = $label
            DetailText       = $detail
            CountText        = ''
            ElapsedText      = 'took {0:mm\:ss}' -f $Elapsed
            BarValue         = $total
            BarMaximum       = $total
            LogLine          = $row
            RestartStepClock = $false
            CloseEnabled     = $true
        }
    }

    # THE DETAIL GOES ON THE LOG LINE. See the note above.
    #
    # THE PARENTHESES AROUND EVERY -f ARE LOAD-BEARING WHERE THIS IS CONSUMED:
    # inside a .NET method call a comma separates ARGUMENTS, so $line.Add('{0}
    # {1}' -f $a, $b) parses as Add(('{0} {1}' -f $a), $b) and throws at run time
    # only. Composing the row here is what takes that trap out of the handler.
    $row = '{0:mm\:ss}  {1,2}/{2}  {3}' -f $Elapsed, $Report.Step, $Report.Total, $title

    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $row = '{0}  -  {1}' -f $row, $detail
    }

    return [pscustomobject] @{
        Finished         = $false
        IsFailure        = $false
        StepText         = $title
        DetailText       = $detail
        CountText        = 'step {0} of {1}' -f $Report.Step, $Report.Total
        ElapsedText      = 'elapsed {0:mm\:ss}   -   {1:N0}s on "{2}"' -f $Elapsed, $OnStep.TotalSeconds, $title
        BarValue         = [double] $Report.Step
        BarMaximum       = [double] $Report.Total
        LogLine          = $row

        # NOT ON EVERY REPORT. See the per-step clock note above.
        RestartStepClock = ($StepText -ne $title)
        CloseEnabled     = $false
    }
}
