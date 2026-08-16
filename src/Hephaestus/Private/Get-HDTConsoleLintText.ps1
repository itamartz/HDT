function Get-HDTConsoleLintText {
    <#
        .SYNOPSIS
            How a task sequence's lint findings read on its row and in its pane.

        .DESCRIPTION
            VALIDATION, SURFACED INLINE, turned into the two
            strings a row needs. Test-HDTTaskSequence decided what is wrong -
            this decides how much of it goes where, which is a different
            question and the one a screen full of sequences turns on.

            THE CAPTION IS FOR SCANNING, THE DETAIL IS FOR READING. A tree of
            thirty task sequences is scanned: the row has to say "this one"
            without being opened, so it carries a count and nothing else. The
            pane is for somebody who has already decided to look, so it carries
            every finding with its step and its severity.

            ERRORS BEFORE WARNINGS, ALWAYS. A step type no loaded module
            implements will not run at all; a %Var% nobody can supply might be
            supplied by a rules file this console was not opened on. When a
            sequence has both, the caption leads with the one that stops a
            deployment.

            A CLEAN SEQUENCE GETS NO CAPTION AND A SENTENCE. No caption, because
            a mark that appears on every row marks nothing; a sentence in the
            pane, because a blank box is indistinguishable from a check that did
            not run - and "nothing found" is a genuinely useful answer to somebody
            deciding whether to boot a machine.

            THE STATUS IS 'Warning', NEVER 'Error'. Red is for a document that
            cannot be READ, and a sequence with a lint finding imported fine. A
            console where four things are red is a console where red means
            nothing.

        .PARAMETER Finding
            Test-HDTTaskSequence's findings for one sequence.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Caption  what goes in brackets on the row, empty when clean
              Detail   every finding, or a sentence saying there were none
              Status   'Warning' when there is anything to say, else 'Ok'

        .EXAMPLE
            Get-HDTConsoleLintText -Finding (Test-HDTTaskSequence -Sequence $sequence)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Finding
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $all = @($Finding | Where-Object { $null -ne $_ })

    if (@($all).Count -eq 0) {
        return [pscustomobject] @{
            Caption = ''
            Detail  = 'Test-HDTTaskSequence found no problems in this sequence.'
            Status  = 'Ok'
        }
    }

    $errorCount = @($all | Where-Object { $_.Severity -eq 'Error' }).Count
    $warningCount = @($all | Where-Object { $_.Severity -eq 'Warning' }).Count

    $part = New-Object -TypeName System.Collections.ArrayList

    # Errors first: one stops a deployment, the other might be nothing.
    if ($errorCount -gt 0) {
        [void] $part.Add(('{0} error{1}' -f $errorCount, $(if ($errorCount -eq 1) { '' } else { 's' })))
    }

    if ($warningCount -gt 0) {
        [void] $part.Add(('{0} warning{1}' -f $warningCount, $(if ($warningCount -eq 1) { '' } else { 's' })))
    }

    # A finding names the step it is about, because "somewhere in this sequence"
    # is not something an administrator can act on.
    $line = foreach ($current in $all) {
        $step = [string] $current.Step

        if ([string]::IsNullOrWhiteSpace($step)) {
            '{0}: {1}' -f $current.Severity, $current.Message
        } else {
            '{0} - step {1} ({2}): {3}' -f $current.Severity, $current.Index, $step, $current.Message
        }
    }

    return [pscustomobject] @{
        Caption = ($part -join ', ')
        Detail  = (@($line) -join [System.Environment]::NewLine)
        Status  = 'Warning'
    }
}
